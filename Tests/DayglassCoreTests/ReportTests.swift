import Foundation
import Testing
@testable import DayglassCore

@Suite struct ReportTests {
    @Test func subtractsAfkAndKeepsAiOverlapSeparate() throws {
        let focus = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T09:00:00Z"),
            end: date("2026-09-14T10:00:00Z"),
            attributes: [
                "app.name": "Google Chrome",
                "app.bundle_id": "com.google.Chrome",
                "window.title": "repo-a - Pull requests",
                "url.domain": "github.com",
                "url.path": "/acme/repo-a/pull/12",
            ]
        )
        let afk = ObservedSpan(
            name: "afk",
            start: date("2026-09-14T09:15:00Z"),
            end: date("2026-09-14T09:30:00Z"),
            attributes: ["dayglass.afk.reason": "idle"]
        )
        let aiTurn = ObservedSpan(
            name: "gen_ai.turn",
            start: date("2026-09-14T09:05:00Z"),
            end: date("2026-09-14T09:35:00Z"),
            attributes: ["gen_ai.agent.name": "codex"]
        )
        let result = ReportEngine(
            input: ReportInput(spans: [focus, afk, aiTurn]),
            configuration: ReportConfiguration(projects: [
                ProjectRule(code: "PJ-A", name: "A", title: ["repo-a"])
            ])
        ).build()

        let row = try #require(result.time.first)
        #expect(row.project == "PJ-A")
        #expect(row.category == "review")
        #expect(row.seconds == 2700)
        #expect(row.aiSeconds == 900)
        #expect(row.projectBasis == "title")
        #expect(row.categoryBasis == "url")
        #expect(row.confidence == "inferred")
    }

    @Test func browserDoesNotInheritACompetingBackgroundSession() throws {
        let focus = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T11:00:00Z"),
            end: date("2026-09-14T11:20:00Z"),
            attributes: [
                "app.name": "Google Chrome",
                "app.bundle_id": "com.google.Chrome",
                "url.domain": "example.com",
            ]
        )
        let session = ObservedSpan(
            name: "gen_ai.session",
            start: date("2026-09-14T10:50:00Z"),
            end: date("2026-09-14T11:30:00Z"),
            attributes: [
                "dayglass.project": "PJ-B",
                "vcs.repository.url.full": "https://github.com/acme/repo-b",
            ]
        )
        let result = ReportEngine(
            input: ReportInput(spans: [focus, session]),
            configuration: ReportConfiguration(projects: [
                ProjectRule(code: "PJ-B", name: "B", git: ["github.com/acme/repo-b"])
            ])
        ).build()

        let row = try #require(result.time.first)
        #expect(row.project == nil)
        #expect(row.projectBasis == "none")
    }

    @Test func splitsFocusAtLocalMidnight() {
        let focus = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T23:50:00Z"),
            end: date("2026-09-15T00:10:00Z"),
            attributes: ["app.name": "Terminal", "app.bundle_id": "com.apple.Terminal"]
        )
        let result = ReportEngine(
            input: ReportInput(spans: [focus]),
            configuration: ReportConfiguration(timeZone: .gmt)
        ).build()

        #expect(result.time.map(\.day) == ["2026-09-14", "2026-09-15"])
        #expect(result.time.map(\.seconds) == [900, 900])
    }

    @Test func allocatesRoundedDailyMinutesByLargestRemainder() throws {
        let first = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T09:00:00Z"),
            end: date("2026-09-14T09:10:00Z"),
            attributes: ["app.name": "Terminal", "window.title": "alpha"]
        )
        let second = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T09:10:00Z"),
            end: date("2026-09-14T09:40:00Z"),
            attributes: ["app.name": "Terminal", "window.title": "beta"]
        )
        let result = ReportEngine(
            input: ReportInput(spans: [first, second]),
            configuration: ReportConfiguration(projects: [
                ProjectRule(code: "A", title: ["alpha"]),
                ProjectRule(code: "B", title: ["beta"]),
            ])
        ).build()

        #expect(result.time.map(\.seconds) == [900, 1800])
        #expect(result.time.reduce(0) { $0 + $1.seconds } == 2700)
    }

    @Test func emitsDeterministicQuestionsForUnassignedAndLockedGaps() throws {
        let focus = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T10:00:00Z"),
            end: date("2026-09-14T11:00:00Z"),
            attributes: [
                "app.name": "Google Chrome",
                "app.bundle_id": "com.google.Chrome",
                "url.domain": "example.com",
            ]
        )
        let afk = ObservedSpan(
            name: "afk",
            start: date("2026-09-14T10:20:00Z"),
            end: date("2026-09-14T10:45:00Z"),
            attributes: ["dayglass.afk.reason": "locked"]
        )
        let run = ObservedSpan(
            name: "dayglass.run",
            start: date("2026-09-14T10:00:00Z"),
            end: date("2026-09-14T11:00:00Z")
        )
        let engine = ReportEngine(input: ReportInput(spans: [focus, afk, run]))
        let first = engine.build()
        let second = engine.build()

        #expect(first.questions == second.questions)
        #expect(first.questions.contains { $0.kind == "unassigned" && $0.seconds == 1200 })
        #expect(first.questions.contains { $0.kind == "gap" && $0.options == ["skip", "meeting", "research"] })
        #expect(first.questions.allSatisfy { !$0.id.isEmpty })
    }

    @Test func attachesDistinctOnScreenEvidenceToQuestions() throws {
        let first = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T13:00:00Z"),
            end: date("2026-09-14T13:15:00Z"),
            attributes: ["app.name": "Ghostty", "window.title": "dayglass"]
        )
        let second = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T13:15:00Z"),
            end: date("2026-09-14T13:30:00Z"),
            attributes: ["app.name": "Ghostty", "window.title": "dayglass"]
        )
        let run = ObservedSpan(name: "dayglass.run", start: first.start, end: second.end)
        let result = ReportEngine(input: ReportInput(spans: [first, second, run])).build()

        let question = try #require(result.questions.first { $0.kind == "unassigned" })
        #expect(question.evidence == ["dayglass"])
    }

    @Test func fallsBackToTheUrlFragmentWhenNoWindowTitleWasCaptured() throws {
        let focus = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T14:00:00Z"),
            end: date("2026-09-14T14:30:00Z"),
            attributes: [
                "app.name": "Google Chrome",
                "app.bundle_id": "com.google.Chrome",
                "url.domain": "example.com",
                "url.path": "/acme/repo-a/pull/12",
            ]
        )
        let run = ObservedSpan(name: "dayglass.run", start: focus.start, end: focus.end)
        let result = ReportEngine(input: ReportInput(spans: [focus, run])).build()

        let question = try #require(result.questions.first { $0.kind == "unassigned" })
        #expect(question.evidence == ["example.com/acme/repo-a/pull/12"])
    }

    @Test func redactingAQuestionDropsItsOnScreenEvidence() {
        let question = ReportQuestion(
            id: "abc",
            kind: "unassigned",
            start: date("2026-09-14T13:00:00Z"),
            end: date("2026-09-14T13:30:00Z"),
            seconds: 1800,
            options: ["PJ-A"],
            evidence: ["dayglass", "example.com/acme"]
        )

        let redacted = question.withoutTitles()

        #expect(redacted.evidence.isEmpty)
        #expect(redacted == ReportQuestion(id: "abc", kind: "unassigned", start: question.start, end: question.end, seconds: 1800, options: ["PJ-A"]))
    }

    @Test func aNoteOverridesInferenceAndSuppressesItsQuestion() throws {
        let focus = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T12:00:00Z"),
            end: date("2026-09-14T12:30:00Z"),
            attributes: ["app.name": "Google Chrome", "url.domain": "example.com"]
        )
        let note = NoteRecord(
            start: date("2026-09-14T12:00:00Z"),
            end: date("2026-09-14T12:30:00Z"),
            project: "PJ-MEETING",
            category: "meeting"
        )
        let run = ObservedSpan(
            name: "dayglass.run",
            start: focus.start,
            end: focus.end
        )
        let result = ReportEngine(input: ReportInput(spans: [focus, run]), notes: [note]).build()
        let row = try #require(result.time.first)

        #expect(row.project == "PJ-MEETING")
        #expect(row.category == "meeting")
        #expect(row.confidence == "confirmed")
        #expect(result.questions.isEmpty)
    }
}

private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: value)!
}
