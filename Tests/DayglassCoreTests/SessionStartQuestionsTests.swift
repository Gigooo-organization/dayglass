import Foundation
import Testing
@testable import DayglassCore

@Suite struct SessionStartQuestionsTests {
    private let calendar = DayglassCalendar.gregorian(in: .gmt)

    @Test func formatsOneDayOfUnansweredQuestions() {
        let questions = [
            question(start: "2026-09-24T01:00:00Z", seconds: 1200),
            question(start: "2026-09-24T03:00:00Z", seconds: 1200),
        ]

        let line = SessionStartQuestions.additionalContext(for: questions, calendar: calendar)

        #expect(line == "dayglass: 2026-09-24 に未確定の時間帯が 2 件（40 分）あります。「dayglass」と言えば確認できます")
    }

    @Test func namesTheFirstAndLastDayWhenTheWindowSpansDays() {
        let questions = [
            question(start: "2026-09-22T01:00:00Z", seconds: 900),
            question(start: "2026-09-24T01:00:00Z", seconds: 1500),
        ]

        let line = SessionStartQuestions.additionalContext(for: questions, calendar: calendar)

        #expect(line == "dayglass: 2026-09-22 から 2026-09-24 に未確定の時間帯が 2 件（40 分）あります。「dayglass」と言えば確認できます")
    }

    @Test func printsNothingWhenTheTrailingWeekHasNoQuestions() {
        let older = question(start: "2026-09-01T01:00:00Z", seconds: 1800)
        let now = date("2026-09-28T12:00:00Z")

        #expect(SessionStartQuestions.additionalContext(for: [], calendar: calendar) == nil)
        #expect(SessionStartQuestions.stdout(questions: [older], now: now, calendar: calendar) == nil)
        #expect(SessionStartQuestions.stdout(questions: [], now: now, calendar: calendar) == nil)
    }

    @Test func limitsThePayloadToTheTrailingSevenDays() throws {
        let included = question(start: "2026-09-22T00:00:00Z", seconds: 1200)
        let excluded = question(start: "2026-09-21T23:00:00Z", seconds: 3600)
        let now = date("2026-09-28T15:00:00Z")

        let payload = try #require(SessionStartQuestions.stdout(
            questions: [excluded, included],
            now: now,
            calendar: calendar
        ))
        let context = try additionalContext(in: payload)

        #expect(!payload.contains("\n"))
        #expect(context == "dayglass: 2026-09-22 に未確定の時間帯が 1 件（20 分）あります。「dayglass」と言えば確認できます")
        #expect(SessionStartQuestions.dayFolderNames(days: 7, endingAt: now, calendar: calendar) == [
            "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28",
        ])
    }

    @Test func dayFoldersCrossTheMonthBoundary() {
        let names = SessionStartQuestions.dayFolderNames(
            days: SessionStartQuestions.defaultDays,
            endingAt: date("2026-10-02T08:00:00Z"),
            calendar: calendar
        )

        #expect(names.first == "2026-09-26")
        #expect(names.last == "2026-10-02")
        #expect(names.count == 7)
    }

    @Test func stdoutIsTheClaudeSessionStartObject() throws {
        let questions = [question(start: "2026-09-24T01:00:00Z", seconds: 2400)]
        let payload = try #require(SessionStartQuestions.stdout(
            questions: questions,
            now: date("2026-09-24T12:00:00Z"),
            calendar: calendar
        ))
        let object = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])

        #expect(object.count == 1)
        #expect(specific["hookEventName"] as? String == "SessionStart")
        #expect(specific["additionalContext"] as? String == SessionStartQuestions.additionalContext(for: questions, calendar: calendar))
    }

    @Test func anAnsweredNoteLeavesTheSessionStartLineEmpty() {
        let start = date("2026-09-24T09:00:00Z")
        let end = date("2026-09-24T09:40:00Z")
        let focus = ObservedSpan(
            name: "focus",
            start: start,
            end: end,
            attributes: ["app.name": "Google Chrome", "app.bundle_id": "com.google.Chrome", "url.domain": "example.com"]
        )
        let run = ObservedSpan(name: "dayglass.run", start: start, end: end)
        let note = NoteRecord(start: start, end: end, project: "PJ", category: "research")
        let open = ReportEngine(
            input: ReportInput(spans: [focus, run]),
            configuration: ReportConfiguration(timeZone: .gmt)
        ).build()
        let answered = ReportEngine(
            input: ReportInput(spans: [focus, run]),
            configuration: ReportConfiguration(timeZone: .gmt),
            notes: [note]
        ).build()

        #expect(SessionStartQuestions.stdout(questions: open.questions, now: end, calendar: calendar)?.contains("1 件（40 分）") == true)
        #expect(SessionStartQuestions.stdout(questions: answered.questions, now: end, calendar: calendar) == nil)
    }

    private func question(start: String, seconds: Int) -> ReportQuestion {
        let startDate = date(start)
        return ReportQuestion(
            id: start,
            kind: "unassigned",
            start: startDate,
            end: startDate.addingTimeInterval(TimeInterval(seconds)),
            seconds: seconds,
            options: []
        )
    }

    private func additionalContext(in payload: String) throws -> String {
        let object = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        return try #require(specific["additionalContext"] as? String)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
