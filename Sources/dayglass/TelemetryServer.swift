import DayglassCore
import Darwin
import Foundation

final class TelemetryServer {
    private static let maximumBodyBytes = 4 * 1024 * 1024
    private static let maximumHeaderBytes = 16 * 1024

    private let dataRoot: URL
    private let port: UInt16

    init(dataRoot: URL, port: UInt16 = 4318) {
        self.dataRoot = dataRoot
        self.port = port
    }

    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        let server = socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else { throw posixError() }
        defer { close(server) }

        var reuse: Int32 = 1
        guard setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else {
            throw posixError()
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw posixError() }
        guard listen(server, 8) == 0 else { throw posixError() }

        print("dayglass serve listening on 127.0.0.1:\(port)")
        while true {
            let client = accept(server, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                throw posixError()
            }
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        do {
            let request = try readRequest(from: client)
            guard request.method == "POST" else {
                try respond(status: 405, body: "method not allowed", to: client)
                return
            }
            guard request.contentType == "application/json" else {
                try respond(status: 415, body: "content type must be application/json", to: client)
                return
            }
            guard let signal = OTLPFileSignal(rawValue: request.path.replacingOccurrences(of: "/v1/", with: "")) else {
                try respond(status: 404, body: "unknown OTLP path", to: client)
                return
            }

            let filtered = try OTLPAllowlist.filter(data: request.body, signal: signal)
            let now = Date()
            let dayFile = DayFile(root: dataRoot.appendingPathComponent("otlp", isDirectory: true))
            if let data = filtered.data {
                try dayFile.append(String(decoding: data, as: UTF8.self), signal: signal, at: now)
            }
            var attributes = [
                OTLPAttribute(key: "otlp.signal", value: .string(signal.rawValue)),
                OTLPAttribute(key: "otlp.bytes", value: .int(Int64(request.body.count))),
                OTLPAttribute(key: "otlp.records.kept", value: .int(Int64(filtered.keptRecords))),
                OTLPAttribute(key: "otlp.records.dropped", value: .int(Int64(filtered.droppedRecords))),
            ]
            if let sourceService = filtered.sourceService {
                attributes.append(OTLPAttribute(key: "otlp.source.service", value: .string(sourceService)))
            }
            let receipt = try OTLPJSONL.logLine(eventName: "otlp.received", at: now, attributes: attributes)
            try dayFile.append(receipt, signal: .logs, at: now)
            try respond(
                status: 202,
                body: "{\"accepted\":true,\"kept_records\":\(filtered.keptRecords),\"dropped_records\":\(filtered.droppedRecords)}",
                to: client
            )
        } catch let error as TelemetryHTTPError {
            try? respond(status: error.status, body: error.message, to: client)
        } catch {
            try? respond(status: 500, body: "internal server error", to: client)
        }
    }

    private func readRequest(from client: Int32) throws -> TelemetryHTTPRequest {
        var data = Data()
        let separator = Data([13, 10, 13, 10])
        var headerRange: Range<Data.Index>?
        while headerRange == nil {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { throw TelemetryHTTPError(status: 400, message: "invalid request") }
            data.append(buffer, count: count)
            if data.count > Self.maximumHeaderBytes { throw TelemetryHTTPError(status: 431, message: "request headers too large") }
            headerRange = data.range(of: separator)
        }

        guard let headerRange else { throw TelemetryHTTPError(status: 400, message: "invalid request") }
        let headerData = data[..<headerRange.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw TelemetryHTTPError(status: 400, message: "headers must be UTF-8")
        }
        let lines = header.components(separatedBy: "\n").filter { !$0.isEmpty }.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let requestLine = lines.first else { throw TelemetryHTTPError(status: 400, message: "missing request line") }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count == 3 else { throw TelemetryHTTPError(status: 400, message: "invalid request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw TelemetryHTTPError(status: 400, message: "invalid header") }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let lengthValue = headers["content-length"], let length = Int(lengthValue), length >= 0 else {
            throw TelemetryHTTPError(status: 411, message: "content length required")
        }
        guard length <= Self.maximumBodyBytes else {
            throw TelemetryHTTPError(status: 413, message: "request body too large")
        }

        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart else { throw TelemetryHTTPError(status: 400, message: "invalid body") }
        var body = Data(data[bodyStart...])
        guard body.count <= length else { throw TelemetryHTTPError(status: 400, message: "extra request bytes") }
        while body.count < length {
            var buffer = [UInt8](repeating: 0, count: min(64 * 1024, length - body.count))
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { throw TelemetryHTTPError(status: 400, message: "incomplete body") }
            body.append(buffer, count: count)
        }
        return TelemetryHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            contentType: headers["content-type"]?.split(separator: ";", maxSplits: 1).first.map(String.init),
            body: body
        )
    }

    private func respond(status: Int, body: String, to client: Int32) throws {
        let bodyData: Data
        if status >= 400 {
            bodyData = try JSONSerialization.data(withJSONObject: ["error": body], options: [.sortedKeys])
        } else {
            bodyData = Data(body.utf8)
        }
        let reason: String
        switch status {
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 411: reason = "Length Required"
        case 413: reason = "Payload Too Large"
        case 415: reason = "Unsupported Media Type"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "Internal Server Error"
        }
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        try response.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = write(client, baseAddress.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
    }
}

private struct TelemetryHTTPRequest {
    let method: String
    let path: String
    let contentType: String?
    let body: Data
}

private struct TelemetryHTTPError: Error {
    let status: Int
    let message: String
}

private func posixError() -> POSIXError {
    POSIXError(.init(rawValue: errno) ?? .EIO)
}
