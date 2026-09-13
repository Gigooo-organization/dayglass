import Foundation
import Testing
@testable import DayglassCore

@Suite struct EvidenceTests {
    @Test func mergesSourcesRedactsCredentialsAndDropsSyntheticPrompts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codex = root.appendingPathComponent(".codex/sessions/one.jsonl")
        let claude = root.appendingPathComponent(".claude/projects/one.jsonl")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = "sk-" + String(repeating: "a", count: 28)
        try writeJSONL([
            ["type": "session_meta", "timestamp": "2026-09-02T00:00:00Z", "payload": ["id": "codex-session", "cwd": "/home/wagomu/dev/github.com/acme/repo"]],
            ["type": "event_msg", "timestamp": "2026-09-02T01:00:00Z", "payload": ["type": "user_message", "message": "Deploy the service \(secret)"]],
            ["type": "event_msg", "timestamp": "2026-09-02T01:01:00Z", "payload": ["type": "agent_message", "message": "Deployment verified"]],
            ["type": "event_msg", "timestamp": "2026-09-02T02:00:00Z", "payload": ["type": "user_message", "message": "<command-name>ignored</command-name>"]],
        ], to: codex)
        try writeJSONL([
            ["type": "user", "timestamp": "2026-09-02T01:00:30Z", "cwd": "/home/wagomu/dev/github.com/acme/repo", "sessionId": "claude-session", "isMeta": false, "isSidechain": false, "message": ["role": "user", "content": "Deploy the service \(secret)"]],
            ["type": "assistant", "timestamp": "2026-09-02T01:02:00Z", "sessionId": "claude-session", "isSidechain": false, "message": ["role": "assistant", "content": [["type": "text", "text": "Deployment verified in production"]]]],
        ], to: claude)

        let result = EvidenceBuilder.build(day: try day("2026-09-02"), codexRoot: root.appendingPathComponent(".codex"), claudeRoot: root.appendingPathComponent(".claude"))
        #expect(result.rawTurns == 2)
        #expect(result.mergedTurns == 1)
        #expect(result.text.contains("[Claude+Codex]"))
        #expect(result.text.contains("[credential]"))
        #expect(!result.text.contains(secret))
        #expect(!result.text.contains("ignored"))
        #expect(result.text.contains("~/acme/repo"))
        #expect(result.text.contains("Deployment verified in production"))
    }

    @Test func boundsOutputWhilePreservingLateTurns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codex = root.appendingPathComponent("sessions/busy.jsonl")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var values: [[String: Any]] = []
        let formatter = ISO8601DateFormatter()
        let start = try #require(formatter.date(from: "2026-09-01T15:00:00Z"))
        for hour in 0..<24 {
            let user = formatter.string(from: start.addingTimeInterval(Double(hour) * 3_600))
            let result = formatter.string(from: start.addingTimeInterval(Double(hour) * 3_600 + 60))
            values.append(["type": "event_msg", "timestamp": user, "payload": ["type": "user_message", "message": "request-\(String(format: "%02d", hour)) \(String(repeating: "x", count: 500))"]])
            values.append(["type": "event_msg", "timestamp": result, "payload": ["type": "agent_message", "message": "result-\(String(format: "%02d", hour)) \(String(repeating: "y", count: 500))"]])
        }
        try writeJSONL(values, to: codex)

        let output = EvidenceBuilder.build(day: try day("2026-09-02"), codexRoot: root, claudeRoot: root.appendingPathComponent("missing"), maxChars: 4_000).text
        #expect(output.count <= 4_000)
        #expect(output.contains("request-00"))
        #expect(output.contains("request-23"))
    }

    private func day(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = DayglassCalendar.local
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return try #require(formatter.date(from: value))
    }

    private func writeJSONL(_ values: [[String: Any]], to url: URL) throws {
        let lines = try values.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try lines.write(to: url, atomically: true, encoding: .utf8)
    }
}
