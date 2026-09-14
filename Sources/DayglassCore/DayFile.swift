import Darwin
import Foundation

public enum OTLPFileSignal: String, CaseIterable, Codable, Sendable {
    case traces
    case logs
    case metrics
}

public final class DayFile: @unchecked Sendable {
    private let root: URL
    private var calendar: Calendar
    private let fileManager = FileManager.default

    public init(root: URL, timeZone: TimeZone = .current) {
        self.root = root
        self.calendar = DayglassCalendar.gregorian(in: timeZone)
    }

    public func fileURL(signal: OTLPFileSignal, at date: Date) -> URL {
        folderURL(for: date).appendingPathComponent("\(signal.rawValue).jsonl")
    }

    public func append(
        _ line: String,
        signal: OTLPFileSignal,
        at date: Date,
        newline: Bool = true
    ) throws {
        let url = try prepareFile(signal: signal, at: date)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let suffix = newline && !line.hasSuffix("\n") ? "\n" : ""
        try handle.write(contentsOf: Data((line + suffix).utf8))
    }

    fileprivate func prepareFile(signal: OTLPFileSignal, at date: Date) throws -> URL {
        let folder = folderURL(for: date)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = fileURL(signal: signal, at: date)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    /// Drops one incomplete trailing record. Complete lines are left byte-for-byte unchanged.
    @discardableResult
    public func repair(signal: OTLPFileSignal, day: Date) throws -> Int {
        let url = fileURL(signal: signal, at: day)
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let data = try Data(contentsOf: url)
        guard let lastNewline = data.lastIndex(of: 0x0A), lastNewline + 1 < data.endIndex else {
            return data.isEmpty ? 0 : 1
        }
        let complete = data[..<(lastNewline + 1)]
        try Data(complete).write(to: url, options: .atomic)
        return 1
    }

    private func folderURL(for date: Date) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let folder = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        return root.appendingPathComponent(folder, isDirectory: true)
    }
}

public final class Sink: @unchecked Sendable {
    private let dayFile: DayFile
    private let socketPath: URL?

    public init(dayFile: DayFile, socketPath: URL? = nil) {
        self.dayFile = dayFile
        self.socketPath = socketPath
    }

    public func append(_ line: String, signal: OTLPFileSignal, at date: Date) throws {
        if let socketPath, FileManager.default.fileExists(atPath: socketPath.path),
           sendToSocket(line: line, signal: signal, date: date, path: socketPath.path) {
            return
        }

        let file = try dayFile.prepareFile(signal: signal, at: date)
        let lockURL = file.appendingPathExtension("lock")
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
        defer { flock(lockFD, LOCK_UN) }

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let suffix = line.hasSuffix("\n") ? "" : "\n"
        try handle.write(contentsOf: Data((line + suffix).utf8))
    }

    private func sendToSocket(line: String, signal: OTLPFileSignal, date: Date, path: String) -> Bool {
        let envelope: [String: Any] = [
            "signal": signal.rawValue,
            "date": date.timeIntervalSince1970,
            "line": line,
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else { return false }
        let bytes = Array(encoded) + [0x0A]
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: bytes)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { return false }
        return bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, baseAddress.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
