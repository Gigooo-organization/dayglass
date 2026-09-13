import Foundation
import Testing
@testable import DayglassCore

@Suite struct OTLPAllowlistTests {
    @Test func dropsPromptToolBodiesAndIdentityAttributesBeforeStorage() throws {
        let payload: [String: Any] = [
            "resourceLogs": [[
                "resource": ["attributes": [
                    ["key": "service.name", "value": ["stringValue": "claude-code"]],
                    ["key": "user.email", "value": ["stringValue": "person@example.test"]],
                ]],
                "scopeLogs": [["logRecords": [
                    ["eventName": "api_request", "attributes": [
                        ["key": "input_tokens", "value": ["intValue": "10"]],
                        ["key": "prompt.body", "value": ["stringValue": "private prompt"]],
                    ]],
                    ["eventName": "hook_registered", "attributes": []],
                ]]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let filtered = try OTLPAllowlist.filter(data: data, signal: .logs)
        let output = String(decoding: try #require(filtered.data), as: UTF8.self)

        #expect(filtered.keptRecords == 1)
        #expect(filtered.droppedRecords == 1)
        #expect(output.contains("input_tokens"))
        #expect(!output.contains("private prompt"))
        #expect(!output.contains("user.email"))
        #expect(filtered.sourceService == "claude-code")
    }
}
