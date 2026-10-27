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

    @Test func afkCoveredByAudioIsAMeetingAndNotAGap() throws {
        let focus = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T09:00:00Z"),
            end: date("2026-09-14T10:00:00Z"),
            attributes: ["app.name": "Terminal", "app.bundle_id": "com.apple.Terminal"]
        )
        let afk = ObservedSpan(
            name: "afk",
            start: date("2026-09-14T09:20:00Z"),
            end: date("2026-09-14T09:50:00Z"),
            attributes: ["dayglass.afk.reason": "idle"]
        )
        let audio = ObservedSpan(
            name: "audio",
            start: date("2026-09-14T09:00:00Z"),
            end: date("2026-09-14T10:00:00Z")
        )
        let result = ReportEngine(input: ReportInput(spans: [focus, afk, audio])).build()

        #expect(result.blocks.map(\.category) == ["coding", "meeting", "coding"])
        #expect(result.blocks.map(\.categoryBasis) == ["bundle", "audio", "bundle"])
        #expect(result.blocks.map(\.confidence) == ["unassigned", "inferred", "unassigned"])
        let meeting = try #require(result.blocks.first { $0.category == "meeting" })
        #expect(meeting.start == afk.start)
        #expect(meeting.end == afk.end)
        #expect(meeting.projectBasis == "none")
        #expect(!result.questions.contains { $0.kind == "gap" })
    }

    @Test func pausedAfkOverlappingAudioStaysOutOfMeetingsAndGaps() {
        let focus = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T09:00:00Z"),
            end: date("2026-09-14T10:00:00Z"),
            attributes: ["app.name": "Terminal", "app.bundle_id": "com.apple.Terminal"]
        )
        let afk = ObservedSpan(
            name: "afk",
            start: date("2026-09-14T09:20:00Z"),
            end: date("2026-09-14T09:50:00Z"),
            attributes: ["dayglass.afk.reason": "paused"]
        )
        let audio = ObservedSpan(
            name: "audio",
            start: focus.start,
            end: focus.end
        )
        let result = ReportEngine(input: ReportInput(spans: [focus, afk, audio])).build()

        #expect(result.blocks.map(\.category) == ["coding", "coding"])
        #expect(!result.blocks.contains { $0.categoryBasis == "audio" })
        #expect(!result.questions.contains { $0.kind == "gap" })
    }

    @Test func afkOutsideAudioStillAsksAGap() throws {
        let focus = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T09:00:00Z"),
            end: date("2026-09-14T11:00:00Z"),
            attributes: [
                "app.name": "Google Chrome",
                "app.bundle_id": "com.google.Chrome",
                "url.domain": "example.com",
            ]
        )
        let afk = ObservedSpan(
            name: "afk",
            start: date("2026-09-14T09:10:00Z"),
            end: date("2026-09-14T10:10:00Z"),
            attributes: ["dayglass.afk.reason": "idle"]
        )
        let audio = ObservedSpan(
            name: "audio",
            start: date("2026-09-14T09:10:00Z"),
            end: date("2026-09-14T09:30:00Z")
        )
        let result = ReportEngine(input: ReportInput(spans: [focus, afk, audio])).build()

        let gap = try #require(result.questions.first { $0.kind == "gap" })
        #expect(result.questions.filter { $0.kind == "gap" }.count == 1)
        #expect(gap.start == audio.end)
        #expect(gap.end == afk.end)
        #expect(gap.seconds == 40 * 60)
        let meeting = try #require(result.blocks.first { $0.category == "meeting" })
        #expect(meeting.start == audio.start)
        #expect(meeting.end == audio.end)
        #expect(meeting.categoryBasis == "audio")
        #expect(meeting.confidence == "inferred")
    }

    @Test func docsOverlappingAudioPreferMeetingAndKeepAudioBasis() throws {
        let focus = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T09:00:00Z"),
            end: date("2026-09-14T09:30:00Z"),
            attributes: ["app.name": "Notion", "window.title": "spec"]
        )
        let audio = ObservedSpan(name: "audio", start: focus.start, end: focus.end)
        let result = ReportEngine(
            input: ReportInput(spans: [focus, audio]),
            configuration: ReportConfiguration(projects: [ProjectRule(code: "PJ-A", title: ["spec"])])
        ).build()

        let block = try #require(result.blocks.first)
        #expect(result.blocks.count == 1)
        #expect(block.category == "meeting")
        #expect(block.categoryBasis == "audio")
        #expect(block.confidence == "inferred")
        #expect(block.project == "PJ-A")
        let row = try #require(result.time.first { $0.category == "meeting" })
        #expect(row.categoryBasis == "audio")
        #expect(row.confidence == "inferred")
        #expect(row.seconds == 1800)
    }

    @Test func docsOverlapWithAudioSplitsTheBlock() {
        let focus = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T09:00:00Z"),
            end: date("2026-09-14T10:00:00Z"),
            attributes: ["app.name": "Notion", "window.title": "spec"]
        )
        let audio = ObservedSpan(
            name: "audio",
            start: date("2026-09-14T09:15:00Z"),
            end: date("2026-09-14T09:45:00Z")
        )
        let result = ReportEngine(
            input: ReportInput(spans: [focus, audio]),
            configuration: ReportConfiguration(projects: [ProjectRule(code: "PJ-A", title: ["spec"])])
        ).build()

        #expect(result.blocks.map(\.category) == ["docs", "meeting", "docs"])
        #expect(result.blocks.map(\.categoryBasis) == ["bundle", "audio", "bundle"])
        #expect(result.blocks.allSatisfy { $0.confidence == "inferred" && $0.project == "PJ-A" })
        #expect(result.blocks.map { Int($0.end.timeIntervalSince($0.start)) } == [900, 1800, 900])
    }

    @Test func audioDoesNotReclassifyCodingOrAnAppMeeting() {
        let coding = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T11:00:00Z"),
            end: date("2026-09-14T11:30:00Z"),
            attributes: ["app.name": "Terminal", "app.bundle_id": "com.apple.Terminal"]
        )
        let zoom = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T12:00:00Z"),
            end: date("2026-09-14T12:30:00Z"),
            attributes: ["app.name": "Zoom", "app.bundle_id": "us.zoom.xos"]
        )
        let audio = [
            ObservedSpan(name: "audio", start: coding.start, end: coding.end),
            ObservedSpan(name: "audio", start: zoom.start, end: zoom.end),
        ]
        let result = ReportEngine(input: ReportInput(spans: [coding, zoom] + audio)).build()

        #expect(result.blocks.map(\.category) == ["coding", "meeting"])
        #expect(result.blocks.map(\.categoryBasis) == ["bundle", "bundle"])
    }

    @Test func aNoteStillOverridesAnAudioMeeting() throws {
        let focus = ObservedSpan(
            name: "focus",
            start: date("2026-09-14T09:00:00Z"),
            end: date("2026-09-14T09:30:00Z"),
            attributes: ["app.name": "Notion", "window.title": "spec"]
        )
        let audio = ObservedSpan(name: "audio", start: focus.start, end: focus.end)
        let note = NoteRecord(start: focus.start, end: focus.end, project: "PJ-NOTE", category: "research")
        let result = ReportEngine(input: ReportInput(spans: [focus, audio]), notes: [note]).build()
        let block = try #require(result.blocks.first)

        #expect(block.category == "research")
        #expect(block.categoryBasis == "note")
        #expect(block.confidence == "confirmed")
        #expect(block.project == "PJ-NOTE")
    }

    @Test func splitsAnAudioMeetingAtLocalMidnight() {
        let afk = ObservedSpan(
            name: "afk",
            start: date("2026-09-14T23:40:00Z"),
            end: date("2026-09-15T00:20:00Z"),
            attributes: ["dayglass.afk.reason": "idle"]
        )
        let audio = ObservedSpan(name: "audio", start: afk.start, end: afk.end)
        let result = ReportEngine(
            input: ReportInput(spans: [afk, audio]),
            configuration: ReportConfiguration(timeZone: .gmt)
        ).build()

        #expect(result.blocks.map(\.category) == ["meeting", "meeting"])
        #expect(result.blocks.allSatisfy { $0.categoryBasis == "audio" && $0.confidence == "inferred" })
        #expect(result.time.map(\.day) == ["2026-09-14", "2026-09-15"])
    }
}

private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: value)!
}

@Suite struct LockScreenTests {
    private func focus(_ app: String, _ bundle: String, _ start: String, _ end: String) -> ObservedSpan {
        ObservedSpan(name: "focus", start: lockDate(start), end: lockDate(end), attributes: [
            "app.name": app, "app.bundle_id": bundle, "url.domain": "example.com",
        ])
    }

    private func run(_ start: String, _ end: String) -> ObservedSpan {
        ObservedSpan(name: "dayglass.run", start: lockDate(start), end: lockDate(end))
    }

    @Test func lockScreenTimeIsNotWorkAndAShortLockAsksAGapWithSkipFirst() throws {
        let spans = [
            focus("Google Chrome", "com.google.Chrome", "2026-10-01T10:00:00Z", "2026-10-01T11:00:00Z"),
            focus("loginwindow", "com.apple.loginwindow", "2026-10-01T11:00:00Z", "2026-10-01T11:40:00Z"),
            focus("Google Chrome", "com.google.Chrome", "2026-10-01T11:40:00Z", "2026-10-01T12:10:00Z"),
            run("2026-10-01T10:00:00Z", "2026-10-01T12:10:00Z"),
        ]
        let result = ReportEngine(input: ReportInput(spans: spans)).build()

        #expect(result.time.reduce(0) { $0 + $1.seconds } == 90 * 60)
        let gap = try #require(result.questions.first { $0.kind == "gap" })
        #expect(gap.seconds == 40 * 60)
        #expect(gap.options.first == "skip")
    }

    @Test func anOvernightLockIsNeitherWorkNorAQuestion() {
        let spans = [
            focus("Google Chrome", "com.google.Chrome", "2026-10-01T09:00:00Z", "2026-10-01T10:00:00Z"),
            focus("loginwindow", "com.apple.loginwindow", "2026-10-01T10:00:00Z", "2026-10-01T19:00:00Z"),
            focus("Google Chrome", "com.google.Chrome", "2026-10-01T19:00:00Z", "2026-10-01T20:00:00Z"),
            run("2026-10-01T09:00:00Z", "2026-10-01T20:00:00Z"),
        ]
        let result = ReportEngine(input: ReportInput(spans: spans)).build()

        #expect(result.time.reduce(0) { $0 + $1.seconds } == 2 * 3600)
        #expect(!result.questions.contains { $0.kind == "gap" })
    }
}

private func lockDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

@Suite struct CategoryDefaultsTests {
    private func category(app: String, bundle: String, domain: String? = nil) -> (String, String)? {
        var attributes = ["app.name": app, "app.bundle_id": bundle]
        if let domain { attributes["url.domain"] = domain }
        let span = ObservedSpan(name: "focus", start: lockDate("2026-10-01T10:00:00Z"), end: lockDate("2026-10-01T11:00:00Z"), attributes: attributes)
        return ReportEngine(input: ReportInput(spans: [span])).build().time.first.map { ($0.category, $0.categoryBasis) }
    }

    @Test func chatAppsAreCommunication() {
        #expect(category(app: "Slack", bundle: "com.tinyspeck.slackmacgap")! == ("communication", "bundle"))
        #expect(category(app: "LINE WORKS", bundle: "com.naver.lineworks")! == ("communication", "bundle"))
        #expect(category(app: "Microsoft Edge", bundle: "com.microsoft.edgemac", domain: "app.slack.com")! == ("communication", "url"))
    }

    @Test func modernTerminalsAreCoding() {
        #expect(category(app: "WezTerm", bundle: "com.github.wez.wezterm")?.0 == "coding")
        #expect(category(app: "Ghostty", bundle: "com.mitchellh.ghostty")?.0 == "coding")
        #expect(category(app: "T3 Code (Beta)", bundle: "com.t3tools.t3code")?.0 == "coding")
    }

    @Test func asideIsABrowser() {
        #expect(category(app: "Aside", bundle: "at.studio.AsideBrowser", domain: "developer.apple.com")! == ("research", "url"))
    }
}
