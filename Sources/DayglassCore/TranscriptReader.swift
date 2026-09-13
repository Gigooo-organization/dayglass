import Foundation

public struct TranscriptTurn: Equatable, Sendable {
    public let sessionID: String
    public let start: Date
    public let end: Date
    public let cwd: String?
    public let gitBranch: String?
    public let model: String?
    public let promptChars: Int
    public let toolCalls: Int
    public let editCalls: Int
    public let inputUncached: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let output: Int

    public init(
        sessionID: String,
        start: Date,
        end: Date,
        cwd: String? = nil,
        gitBranch: String? = nil,
        model: String? = nil,
        promptChars: Int = 0,
        toolCalls: Int = 0,
        editCalls: Int = 0,
        inputUncached: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        output: Int = 0
    ) {
        self.sessionID = sessionID
        self.start = start
        self.end = end
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.model = model
        self.promptChars = promptChars
        self.toolCalls = toolCalls
        self.editCalls = editCalls
        self.inputUncached = inputUncached
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
    }
}

public struct TranscriptReadResult: Equatable, Sendable {
    public let turns: [TranscriptTurn]
    public let malformedLines: Int
    public let unreadableFiles: Int

    public init(turns: [TranscriptTurn], malformedLines: Int = 0, unreadableFiles: Int = 0) {
        self.turns = turns
        self.malformedLines = malformedLines
        self.unreadableFiles = unreadableFiles
    }
}

public enum TranscriptReader {
    public static func claude(file: URL) throws -> TranscriptReadResult {
        try parse(file: file, tool: .claude)
    }

    public static func codex(file: URL) throws -> TranscriptReadResult {
        try parse(file: file, tool: .codex)
    }

    public static func read(files: [URL], tool: HookTool) -> TranscriptReadResult {
        var turns: [TranscriptTurn] = []
        var malformed = 0
        var unreadable = 0
        for file in files {
            do {
                let result = try parse(file: file, tool: tool)
                turns.append(contentsOf: result.turns)
                malformed += result.malformedLines
                unreadable += result.unreadableFiles
            } catch {
                unreadable += 1
            }
        }
        return TranscriptReadResult(turns: turns.sorted { $0.start < $1.start }, malformedLines: malformed, unreadableFiles: unreadable)
    }

    private static func parse(file: URL, tool: HookTool) throws -> TranscriptReadResult {
        let data = try fileData(file)
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        var malformed = 0
        var turns: [TranscriptTurn] = []
        var current: MutableTurn?
        var lastTimestamp = Date()
        var sessionID = file.deletingPathExtension().lastPathComponent
        var cwd: String?
        var branch: String?
        var model: String?

        func close(_ value: MutableTurn?, at end: Date) -> TranscriptTurn? {
            guard let value else { return nil }
            return value.result(end: max(value.start, end))
        }

        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                malformed += 1
                continue
            }
            let timestamp = parseDate(object["timestamp"] ?? object["time"]) ?? lastTimestamp
            lastTimestamp = timestamp
            if tool == .claude {
                sessionID = string(object["sessionId"] ?? object["session_id"]) ?? sessionID
                cwd = string(object["cwd"]) ?? cwd
                branch = string(object["gitBranch"]) ?? branch
                guard let type = string(object["type"]) else { continue }
                if type == "user" {
                    if let previous = close(current, at: timestamp) { turns.append(previous) }
                    let message = object["message"] as? [String: Any]
                    let content = message?["content"]
                    guard isHumanPrompt(content, meta: object["isMeta"] as? Bool ?? false, sidechain: object["isSidechain"] as? Bool ?? false) else {
                        current = nil
                        continue
                    }
                    current = MutableTurn(sessionID: sessionID, start: timestamp, cwd: cwd, branch: branch, model: model, promptChars: textLength(content))
                } else if type == "assistant", var turn = current {
                    if let message = object["message"] as? [String: Any] {
                        if let usage = message["usage"] as? [String: Any] {
                            turn.inputUncached += integer(usage["input_tokens"])
                            turn.cacheRead += integer(usage["cache_read_tokens"] ?? usage["cache_read_input_tokens"])
                            turn.cacheWrite += integer(usage["cache_creation_tokens"] ?? usage["cache_creation_input_tokens"])
                            turn.output += integer(usage["output_tokens"])
                        }
                        let blocks = message["content"] as? [[String: Any]] ?? []
                        turn.toolCalls += blocks.filter { $0["type"] as? String == "tool_use" }.count
                        turn.editCalls += blocks.filter {
                            guard $0["type"] as? String == "tool_use" else { return false }
                            let name = (($0["name"] as? String) ?? "").lowercased()
                            return name.contains("edit") || name.contains("write") || name.contains("patch")
                        }.count
                    }
                    current = turn
                }
            } else {
                let payload = object["payload"] as? [String: Any] ?? object
                if string(object["type"]) == "session_meta" {
                    sessionID = string(payload["id"]) ?? sessionID
                    cwd = string(payload["cwd"]) ?? cwd
                    branch = string(payload["git_branch"] ?? payload["branch"]) ?? branch
                }
                let payloadType = string(payload["type"])
                if payloadType == "user_message" {
                    if let previous = close(current, at: timestamp) { turns.append(previous) }
                    let message = payload["message"]
                    guard isHumanPrompt(message, meta: false, sidechain: false) else {
                        current = nil
                        continue
                    }
                    current = MutableTurn(sessionID: sessionID, start: timestamp, cwd: cwd, branch: branch, model: model, promptChars: textLength(message))
                } else if payloadType == "token_usage_record", var turn = current {
                    let usage = payload["usage"] as? [String: Any] ?? payload
                    let input = integer(usage["input_token_count"] ?? usage["input_tokens"])
                    let cached = integer(usage["cached_token_count"] ?? usage["cache_read_tokens"])
                    turn.inputUncached += max(0, input - cached)
                    turn.cacheRead += cached
                    turn.cacheWrite += integer(usage["cache_write_token_count"] ?? usage["cache_creation_tokens"])
                    turn.output += integer(usage["output_token_count"] ?? usage["output_tokens"])
                    current = turn
                } else if payloadType == "item_completed", var turn = current {
                    turn.toolCalls += 1
                    let item = payload["item"] as? [String: Any]
                    let kind = ((item?["type"] as? String) ?? "").lowercased()
                    if kind.contains("edit") || kind.contains("write") || kind.contains("patch") { turn.editCalls += 1 }
                    current = turn
                }
                model = string(payload["model"]) ?? model
            }
            current?.end = timestamp
        }
        if let previous = close(current, at: lastTimestamp) { turns.append(previous) }
        return TranscriptReadResult(turns: turns, malformedLines: malformed)
    }
}

private struct MutableTurn {
    let sessionID: String
    let start: Date
    let cwd: String?
    let branch: String?
    let model: String?
    let promptChars: Int
    var end: Date
    var toolCalls = 0
    var editCalls = 0
    var inputUncached = 0
    var cacheRead = 0
    var cacheWrite = 0
    var output = 0

    init(sessionID: String, start: Date, cwd: String?, branch: String?, model: String?, promptChars: Int) {
        self.sessionID = sessionID
        self.start = start
        self.end = start
        self.cwd = cwd
        self.branch = branch
        self.model = model
        self.promptChars = promptChars
    }

    func result(end: Date) -> TranscriptTurn {
        TranscriptTurn(
            sessionID: sessionID,
            start: start,
            end: end,
            cwd: cwd,
            gitBranch: branch,
            model: model,
            promptChars: promptChars,
            toolCalls: toolCalls,
            editCalls: editCalls,
            inputUncached: inputUncached,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            output: output
        )
    }
}

private func fileData(_ file: URL) throws -> Data {
    if file.pathExtension == "zst" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zstd", "-dc", file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return output.fileHandleForReading.readDataToEndOfFile()
    }
    return try Data(contentsOf: file)
}

private func string(_ value: Any?) -> String? { value as? String }

private func integer(_ value: Any?) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) ?? 0 }
    return 0
}

private func parseDate(_ value: Any?) -> Date? {
    guard let value = value as? String else { return nil }
    return ISO8601DateFormatter().date(from: value)
}

private func textLength(_ value: Any?) -> Int {
    if let text = value as? String { return text.count }
    if let blocks = value as? [[String: Any]] {
        return blocks.compactMap { $0["text"] as? String }.reduce(0) { $0 + $1.count }
    }
    return 0
}

private func isHumanPrompt(_ value: Any?, meta: Bool, sidechain: Bool) -> Bool {
    guard !meta, !sidechain else { return false }
    let text: String
    if let value = value as? String { text = value }
    else { text = (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n") }
    let prefixes = ["<system-reminder>", "<command-name>", "<local-command", "<task-notification>", "<codex_internal_context"]
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return !normalized.isEmpty && !prefixes.contains(where: { normalized.hasPrefix($0) })
}
