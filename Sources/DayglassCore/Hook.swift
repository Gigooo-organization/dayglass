import Foundation

public enum HookTool: String, Codable, Sendable {
    case claude
    case codex
}

public enum HookEventKind: String, Codable, Sendable {
    case sessionStart
    case promptSubmit
    case turnEnd
    case sessionEnd
}

public struct HookEvent: Equatable, Sendable {
    public let tool: HookTool
    public let kind: HookEventKind
    public let rawName: String
    public let timestamp: Date
    public let sessionID: String
    public let cwd: String?
    public let transcriptPath: String?
    public let model: String?
    public let turnID: String?

    public init(
        tool: HookTool,
        kind: HookEventKind,
        rawName: String,
        timestamp: Date = Date(),
        sessionID: String,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        model: String? = nil,
        turnID: String? = nil
    ) {
        self.tool = tool
        self.kind = kind
        self.rawName = rawName
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.model = model
        self.turnID = turnID
    }
}

public enum HookDecoder {
    public static func decode(tool: HookTool, data: Data, now: Date = Date()) throws -> HookEvent {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "DayglassCore.Hook", code: 1, userInfo: [NSLocalizedDescriptionKey: "hook payload is not an object"])
        }
        let rawName = string(in: object, keys: ["hook_event_name", "event", "event_name", "type"]) ?? ""
        guard let kind = eventKind(rawName) else {
            throw NSError(domain: "DayglassCore.Hook", code: 2, userInfo: [NSLocalizedDescriptionKey: "unsupported hook event: \(rawName)"])
        }
        guard let sessionID = string(in: object, keys: ["session_id", "sessionId", "conversation_id", "conversationId"]) else {
            throw NSError(domain: "DayglassCore.Hook", code: 3, userInfo: [NSLocalizedDescriptionKey: "hook payload has no session id"])
        }
        return HookEvent(
            tool: tool,
            kind: kind,
            rawName: rawName,
            timestamp: date(in: object) ?? now,
            sessionID: sessionID,
            cwd: string(in: object, keys: ["cwd", "working_directory"]),
            transcriptPath: string(in: object, keys: ["transcript_path", "transcriptPath"]),
            model: string(in: object, keys: ["model", "model_name"]),
            turnID: string(in: object, keys: ["turn_id", "turnId"])
        )
    }

    private static func eventKind(_ raw: String) -> HookEventKind? {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "sessionstart", "start": return .sessionStart
        case "userpromptsubmit", "promptsubmit", "prompt": return .promptSubmit
        case "stop", "turnend", "responsecompleted": return .turnEnd
        case "sessionend", "end": return .sessionEnd
        default: return nil
        }
    }
}

private func string(in object: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = object[key] as? String, !value.isEmpty { return value }
    }
    return nil
}

private func date(in object: [String: Any]) -> Date? {
    guard let value = string(in: object, keys: ["timestamp", "time", "created_at"]) else { return nil }
    return ISO8601DateFormatter().date(from: value)
}

public final class HookRecorder: @unchecked Sendable {
    private let dataRoot: URL
    private let sink: Sink
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
        let dayFile = DayFile(root: dataRoot.appendingPathComponent("otlp", isDirectory: true))
        self.sink = Sink(dayFile: dayFile, socketPath: dataRoot.appendingPathComponent("run/dayglass.sock"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func record(_ event: HookEvent) throws {
        let stateURL = stateURL(for: event)
        var state = try loadState(from: stateURL) ?? HookState(tool: event.tool, sessionID: event.sessionID)
        state.cwd = event.cwd ?? state.cwd
        state.transcriptPath = event.transcriptPath ?? state.transcriptPath
        state.model = event.model ?? state.model

        switch event.kind {
        case .sessionStart:
            state.sessionStart = state.sessionStart ?? event.timestamp
        case .promptSubmit:
            if state.sessionStart == nil { state.sessionStart = event.timestamp }
            state.turnStart = event.timestamp
            state.turnID = event.turnID
        case .turnEnd:
            if let start = state.turnStart, event.timestamp > start {
                try writeSpan(name: "gen_ai.turn", start: start, end: event.timestamp, state: state)
            }
            state.turnStart = nil
            state.turnID = nil
        case .sessionEnd:
            if let start = state.turnStart, event.timestamp > start {
                try writeSpan(name: "gen_ai.turn", start: start, end: event.timestamp, state: state)
            }
            if let start = state.sessionStart, event.timestamp > start {
                try writeSpan(name: "gen_ai.session", start: start, end: event.timestamp, state: state)
            }
            try? fileManager.removeItem(at: stateURL)
        }
        if event.kind != .sessionEnd {
            try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        }
        let log = try OTLPJSONL.logLine(
            eventName: "hook.\(event.tool.rawValue).\(event.rawName)",
            at: event.timestamp,
            attributes: [
                OTLPAttribute(key: "hook.tool", value: .string(event.tool.rawValue)),
                OTLPAttribute(key: "hook.event", value: .string(event.rawName)),
                OTLPAttribute(key: "session.id", value: .string(event.sessionID)),
            ]
        )
        try sink.append(log, signal: .logs, at: event.timestamp)
    }

    private func writeSpan(name: String, start: Date, end: Date, state: HookState) throws {
        let attributes = [
            OTLPAttribute(key: "gen_ai.agent.name", value: .string(state.tool == .claude ? "claude-code" : "codex")),
            OTLPAttribute(key: "gen_ai.conversation.id", value: .string(state.sessionID)),
        ] + (state.cwd.map { [OTLPAttribute(key: "dayglass.cwd", value: .string($0))] } ?? [])
            + (state.model.map { [OTLPAttribute(key: "gen_ai.request.model", value: .string($0))] } ?? [])
            + (state.turnID.map { [OTLPAttribute(key: "gen_ai.turn.id", value: .string($0))] } ?? [])
        let span = OTLPSpan(
            name: name,
            startTimeUnixNano: String(Int64(start.timeIntervalSince1970 * 1_000_000_000)),
            endTimeUnixNano: String(Int64(end.timeIntervalSince1970 * 1_000_000_000)),
            attributes: attributes
        )
        try sink.append(try OTLPJSONL.traceLine(span: span), signal: .traces, at: start)
    }

    private func stateURL(for event: HookEvent) -> URL {
        let safe = event.sessionID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return dataRoot.appendingPathComponent("state/hooks/\(event.tool.rawValue)-\(String(safe)).json")
    }

    private func loadState(from url: URL) throws -> HookState? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(HookState.self, from: Data(contentsOf: url))
    }
}

private struct HookState: Codable, Sendable {
    let tool: HookTool
    let sessionID: String
    var sessionStart: Date?
    var turnStart: Date?
    var turnID: String?
    var cwd: String?
    var transcriptPath: String?
    var model: String?

    init(tool: HookTool, sessionID: String) {
        self.tool = tool
        self.sessionID = sessionID
    }
}
