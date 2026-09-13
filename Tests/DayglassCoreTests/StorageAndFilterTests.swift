import Foundation
import Testing
@testable import DayglassCore

@Suite struct StorageAndFilterTests {
    @Test func encodesTypedAttributesInsideAnOTLPSpan() throws {
        let span = OTLPSpan(
            name: "focus",
            startTimeUnixNano: "100",
            endTimeUnixNano: "200",
            attributes: [
                OTLPAttribute(key: "app.name", value: .string("Terminal")),
                OTLPAttribute(key: "edit_calls", value: .int(2)),
                OTLPAttribute(key: "ai", value: .bool(true)),
            ]
        )

        let line = try OTLPJSONL.traceLine(span: span)
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let resourceSpans = try #require(object["resourceSpans"] as? [[String: Any]])
        let scopeSpans = try #require(resourceSpans[0]["scopeSpans"] as? [[String: Any]])
        let spans = try #require(scopeSpans[0]["spans"] as? [[String: Any]])
        let attributes = try #require(spans[0]["attributes"] as? [[String: Any]])

        #expect(line.hasSuffix("\n") == false)
        #expect(attributes[0]["value"] as? [String: String] == ["stringValue": "Terminal"])
        #expect(attributes[1]["value"] as? [String: String] == ["intValue": "2"])
        #expect(attributes[2]["value"] as? [String: Bool] == ["boolValue": true])
    }

    @Test func appendsDailyLinesAndRepairsAnIncompleteTail() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dayFile = DayFile(root: root, calendar: Calendar(identifier: .gregorian))
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-14T01:02:03Z"))

        try dayFile.append("{\"ok\":true}", signal: .traces, at: date)
        try dayFile.append("{\"tail\":", signal: .traces, at: date, newline: false)
        let repaired = try dayFile.repair(signal: .traces, day: date)

        #expect(repaired == 1)
        let data = try Data(contentsOf: dayFile.fileURL(signal: .traces, at: date))
        #expect(String(decoding: data, as: UTF8.self) == "{\"ok\":true}\n")
    }

    @Test func filtersSpinnerOnlyTitleChangesButKeepsNumbers() {
        var repeats = RepeatFilter()
        var churn = ChurnFilter()

        #expect(repeats.admits("a") == true)
        #expect(repeats.admits("a") == false)
        #expect(repeats.admits("b") == true)
        #expect(churn.decide(scope: "terminal", title: "⠋ Tests 12/40").isRecord)
        #expect(churn.decide(scope: "terminal", title: "⠙ Tests 12/40").isAnimating)
        #expect(ChurnPolicy.default.stem(of: "⠙ Tests 12/40") == "Tests 12/40")
    }
}

private extension ChurnFilter.Decision {
    var isRecord: Bool {
        if case .record = self { return true }
        return false
    }

    var isAnimating: Bool {
        if case .animating = self { return true }
        return false
    }
}
