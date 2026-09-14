import Foundation
import Testing
@testable import DayglassCore

@Suite struct InputReaderTests {
    @Test func readsAnOTLPTraceLineIntoAnObservedSpan() throws {
        let span = OTLPSpan(
            name: "focus",
            startTimeUnixNano: "1726304400000000000",
            endTimeUnixNano: "1726304460000000000",
            attributes: [
                OTLPAttribute(key: "app.name", value: .string("Terminal")),
                OTLPAttribute(key: "edit_calls", value: .int(2)),
            ]
        )
        let line = try OTLPJSONL.traceLine(span: span)

        let spans = try OTLPJSONL.observedSpans(from: Data(line.utf8))

        #expect(spans.count == 1)
        #expect(spans[0].name == "focus")
        #expect(spans[0].attributes["app.name"] == "Terminal")
        #expect(spans[0].attributes["edit_calls"] == "2")
    }

    @Test func loadsProjectAndCategoryRulesFromTheSmallSupportedTOMLShape() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayglass-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        [[project]]
        code = "PJ-A"
        name = "Alpha"
        git = ["github.com/acme/alpha-*”]
        title = ["alpha", "Alpha app"]

        [[category]]
        category = "review"
        domains = ["reviews.example.com"]
        paths = ["/diff/"]
        """.replacingOccurrences(of: "”", with: "\"").write(to: url, atomically: true, encoding: .utf8)

        let configuration = try ReportConfiguration.loadTOML(from: url)

        #expect(configuration.projects == [ProjectRule(code: "PJ-A", name: "Alpha", git: ["github.com/acme/alpha-*"] , title: ["alpha", "Alpha app"])])
        #expect(configuration.categories.first?.category == .review)
        #expect(configuration.categories.first?.domains == ["reviews.example.com"])
    }

    // A Mac set to the Japanese calendar makes Calendar.current count Reiwa
    // years, which stamps every report row for 2026-09-14 as 0008-09-14 and
    // breaks month matching against the requested YYYY-MM.
    @Test func loadsTheGregorianCalendarRatherThanTheSystemOne() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayglass-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try "".write(to: url, atomically: true, encoding: .utf8)

        let configuration = try ReportConfiguration.loadTOML(from: url)

        #expect(configuration.calendar.identifier == .gregorian)
    }
}
