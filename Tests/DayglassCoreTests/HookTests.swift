import Foundation
import Testing
@testable import DayglassCore

@Suite struct HookTests {
    @Test(arguments: [HookTool.claude, HookTool.codex])
    func normalizesBothToolPayloads(_ tool: HookTool) throws {
        let payload = tool == .claude
            ? #"{"hook_event_name":"SessionStart","session_id":"s-1","cwd":"/tmp/dayglass","transcript_path":"/tmp/c.jsonl"}"#
            : #"{"event":"session_start","session_id":"s-1","cwd":"/tmp/dayglass","model":"gpt"}"#
        let event = try HookDecoder.decode(tool: tool, data: Data(payload.utf8), now: date("2026-09-14T09:00:00Z"))

        #expect(event.kind == .sessionStart)
        #expect(event.sessionID == "s-1")
        #expect(event.cwd == "/tmp/dayglass")
    }

    @Test func recorderClosesSessionAndTurnSpansWithoutPromptBodies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder(dataRoot: root)
        let start = date("2026-09-14T09:00:00Z")
        try recorder.record(HookEvent(tool: .claude, kind: .sessionStart, rawName: "SessionStart", timestamp: start, sessionID: "s-1", cwd: "/tmp/dayglass"))
        try recorder.record(HookEvent(tool: .claude, kind: .promptSubmit, rawName: "UserPromptSubmit", timestamp: start.addingTimeInterval(60), sessionID: "s-1"))
        try recorder.record(HookEvent(tool: .claude, kind: .turnEnd, rawName: "Stop", timestamp: start.addingTimeInterval(120), sessionID: "s-1"))
        try recorder.record(HookEvent(tool: .claude, kind: .sessionEnd, rawName: "SessionEnd", timestamp: start.addingTimeInterval(180), sessionID: "s-1"))

        let input = try ObservationStore(root: root.appendingPathComponent("otlp"), calendar: utcCalendar()).load(month: "2026-09")
        #expect(input.spans.map(\.name).sorted() == ["gen_ai.session", "gen_ai.turn"])
        #expect(input.logs.count == 4)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("state/hooks/claude-s-1.json").path))
    }
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}
