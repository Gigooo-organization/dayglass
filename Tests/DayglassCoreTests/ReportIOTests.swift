import Foundation
import Testing
@testable import DayglassCore

@Suite struct ReportIOTests {
    @Test func loadsTheMonthFromDailyOTLPFilesAndRendersCSV() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dayFile = DayFile(root: root, calendar: utcCalendar())
        let date = date("2026-09-14T09:00:00Z")
        let span = OTLPSpan(
            name: "focus",
            startTimeUnixNano: "1789376400000000000",
            endTimeUnixNano: "1789378200000000000",
            attributes: [OTLPAttribute(key: "app.name", value: .string("Terminal"))]
        )
        try dayFile.append(try OTLPJSONL.traceLine(span: span), signal: .traces, at: date)

        let input = try ObservationStore(root: root, calendar: utcCalendar()).load(month: "2026-09")
        let result = ReportEngine(input: input, configuration: ReportConfiguration(calendar: utcCalendar())).build()
        let csv = try ReportRenderer.render(result, format: .csv)

        #expect(input.spans.count == 1)
        #expect(csv.hasPrefix("day,project,category,seconds"))
        #expect(csv.contains("2026-09-14"))
    }

    @Test func rendersJSONWithoutLocalTitlesWhenRequested() throws {
        let block = ReportBlock(
            start: date("2026-09-14T09:00:00Z"),
            end: date("2026-09-14T09:15:00Z"),
            project: "PJ-A",
            category: "coding",
            projectBasis: "title",
            categoryBasis: "bundle",
            confidence: "inferred",
            aiSeconds: 0,
            title: "private window title"
        )
        let result = ReportResult(time: [], blocks: [block], questions: [])

        let json = try ReportRenderer.render(result, format: .json, noTitles: true)

        #expect(!json.contains("private window title"))
        #expect(json.contains("PJ-A"))
    }

    @Test func localDatesUseTheGregorianYearEvenWhenTheSystemCalendarDiffers() {
        let components = DayglassCalendar.local.dateComponents(
            [.year, .month, .day],
            from: date("2026-09-14T00:00:00Z")
        )

        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 14)
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
