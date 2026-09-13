import Foundation
import Testing
@testable import DayglassCore

@Suite struct TranscriptTests {
    @Test func extractsClaudeUsageAndCountsEditTools() throws {
        let file = try fixture("claude.jsonl", contents: """
        {"type":"user","timestamp":"2026-09-14T09:00:00Z","sessionId":"c-1","cwd":"/tmp/repo","message":{"content":"Fix it"}}
        {"type":"assistant","timestamp":"2026-09-14T09:01:00Z","message":{"usage":{"input_tokens":100,"cache_read_tokens":20,"cache_creation_tokens":3,"output_tokens":40},"content":[{"type":"tool_use","name":"Edit"}]}}
        """)
        let result = try TranscriptReader.claude(file: file)

        let turn = try #require(result.turns.first)
        #expect(turn.promptChars == 6)
        #expect(turn.toolCalls == 1)
        #expect(turn.editCalls == 1)
        #expect(turn.inputUncached == 100)
        #expect(turn.cacheRead == 20)
        #expect(turn.cacheWrite == 3)
        #expect(turn.output == 40)
        #expect(result.malformedLines == 0)
    }

    @Test func extractsCodexNormalizedInputAndSkipsMalformedLines() throws {
        let file = try fixture("codex.jsonl", contents: """
        {"type":"session_meta","timestamp":"2026-09-14T09:00:00Z","payload":{"id":"x-1","cwd":"/tmp/repo"}}
        {"type":"event_msg","timestamp":"2026-09-14T09:01:00Z","payload":{"type":"user_message","message":"Inspect"}}
        broken
        {"type":"event_msg","timestamp":"2026-09-14T09:02:00Z","payload":{"type":"token_usage_record","input_token_count":100,"cached_token_count":25,"cache_write_token_count":4,"output_token_count":12}}
        {"type":"event_msg","timestamp":"2026-09-14T09:03:00Z","payload":{"type":"item_completed","item":{"type":"file_edit"}}}
        """)
        let result = try TranscriptReader.codex(file: file)

        let turn = try #require(result.turns.first)
        #expect(turn.inputUncached == 75)
        #expect(turn.cacheRead == 25)
        #expect(turn.cacheWrite == 4)
        #expect(turn.output == 12)
        #expect(turn.toolCalls == 1)
        #expect(turn.editCalls == 1)
        #expect(result.malformedLines == 1)
    }
}

private func fixture(_ name: String, contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}
