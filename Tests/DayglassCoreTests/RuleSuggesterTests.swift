import Foundation
import Testing
@testable import DayglassCore

@Suite struct RuleSuggesterTests {
    @Test func repositoryNameUnassignedOnMultipleDaysBecomesAProjectTitleRule() throws {
        let spans = [
            focus(on: "2026-09-14", minutes: 60, title: "customer-a — src/main.swift"),
            focus(on: "2026-09-16", minutes: 60, title: "Fix customer-a login"),
        ]

        let suggestions = suggest(spans: spans)
        let match = try #require(suggestions.first { $0.term == "customer-a" })

        #expect(match.days == 2)
        #expect(match.seconds == 7200)
        #expect(match.toml == """
        [[project]]
        title = ["customer-a"]
        """)
    }

    @Test func suggestionOrderIsStableForTheSameInput() throws {
        let forward = [
            focus(on: "2026-09-14", minutes: 60, title: "beta-repo"),
            focus(on: "2026-09-15", minutes: 60, title: "beta-repo"),
            focus(on: "2026-09-14", hour: 12, minutes: 120, title: "alpha-repo"),
            focus(on: "2026-09-15", hour: 12, minutes: 120, title: "alpha-repo"),
            focus(on: "2026-09-13", minutes: 10, title: "gamma-repo"),
            focus(on: "2026-09-14", hour: 18, minutes: 10, title: "gamma-repo"),
            focus(on: "2026-09-16", minutes: 10, title: "gamma-repo"),
        ]
        let backward = Array(forward.reversed())

        let first = suggest(spans: forward)
        let second = suggest(spans: forward)
        let reversed = suggest(spans: backward)

        #expect(first.map(\.term) == ["gamma-repo", "alpha-repo", "beta-repo"])
        #expect(first == second)
        #expect(reversed == first)
        #expect(json(spans: forward) == json(spans: backward))
        #expect(json(spans: forward) == json(spans: forward))
    }

    @Test func aTermOnASingleDayIsNotSuggested() throws {
        let spans = [
            focus(on: "2026-09-14", minutes: 60, title: "customer-a"),
            focus(on: "2026-09-14", hour: 12, minutes: 60, title: "customer-a"),
        ]

        #expect(suggest(spans: spans).isEmpty)
        #expect(json(spans: spans).isEmpty)
    }

    @Test func anExistingProjectPatternSuppressesTheTerm() throws {
        let spans = [
            focus(on: "2026-09-14", minutes: 60, title: "customer-a"),
            focus(on: "2026-09-15", minutes: 60, title: "customer-a"),
        ]
        let configuration = ReportConfiguration(
            projects: [ProjectRule(code: "PJ-A", title: ["customer-a"])],
            timeZone: .gmt
        )

        #expect(suggest(spans: spans, configuration: configuration).isEmpty)
    }

    @Test func aConfirmedNoteSuppliesTheProjectCode() throws {
        let confirmed = focus(on: "2026-09-13", minutes: 60, title: "customer-a — Ghostty")
        let spans = [
            confirmed,
            focus(on: "2026-09-14", minutes: 60, title: "customer-a — Ghostty"),
            focus(on: "2026-09-15", minutes: 30, title: "customer-a — Ghostty"),
        ]
        let notes = [
            NoteRecord(start: confirmed.start, end: confirmed.end, project: "PJ-A", category: "coding"),
        ]

        let match = try #require(suggest(spans: spans, notes: notes).first { $0.term == "customer-a" })

        #expect(match.days == 2)
        #expect(match.seconds == 5400)
        #expect(match.toml == """
        [[project]]
        code = "PJ-A"
        title = ["customer-a"]
        """)
    }

    @Test func repeatedDomainsBecomeProjectURLRules() throws {
        let spans = [
            focus(on: "2026-09-14", minutes: 45, title: "Inbox", domain: "tickets.example.com", bundle: "com.google.Chrome", app: "Google Chrome"),
            focus(on: "2026-09-18", minutes: 15, title: "Inbox", domain: "tickets.example.com", bundle: "com.google.Chrome", app: "Google Chrome"),
        ]

        let match = try #require(suggest(spans: spans).first { $0.term == "tickets.example.com" })

        #expect(match.days == 2)
        #expect(match.seconds == 3600)
        #expect(match.toml == """
        [[project]]
        url = ["tickets.example.com"]
        """)
    }

    @Test func ambiguousCategoryBundlesBecomeCategoryRules() throws {
        let confirmed = focus(
            on: "2026-09-13",
            minutes: 40,
            title: "zsh",
            bundle: "com.apple.Terminal",
            app: "Terminal"
        )
        let spans = [
            confirmed,
            focus(on: "2026-09-14", minutes: 30, title: "zsh", bundle: "com.apple.Terminal", app: "Terminal"),
            focus(on: "2026-09-15", minutes: 35, title: "zsh", bundle: "com.apple.Terminal", app: "Terminal"),
        ]
        let notes = [
            NoteRecord(start: confirmed.start, end: confirmed.end, project: "PJ-TERM", category: "review"),
        ]

        let match = try #require(suggest(spans: spans, notes: notes).first { $0.term == "com.apple.Terminal" })

        #expect(match.days == 2)
        #expect(match.toml == """
        [[category]]
        category = "review"
        bundles = ["com.apple.Terminal"]
        """)
    }

    @Test func configuredDayThresholdDropsShorterRuns() throws {
        let spans = [
            focus(on: "2026-09-14", minutes: 60, title: "customer-a"),
            focus(on: "2026-09-15", minutes: 60, title: "customer-a"),
        ]
        var thresholds = ReportThresholds()
        thresholds.suggestDays = 3
        let configuration = ReportConfiguration(thresholds: thresholds, timeZone: .gmt)

        #expect(suggest(spans: spans, configuration: configuration).isEmpty)
    }
}

private func suggest(
    spans: [ObservedSpan],
    configuration: ReportConfiguration = ReportConfiguration(timeZone: .gmt),
    notes: [NoteRecord] = []
) -> [RuleSuggestion] {
    let input = ReportInput(spans: spans)
    let result = ReportEngine(input: input, configuration: configuration, notes: notes).build()
    return RuleSuggester(input: input, result: result, configuration: configuration, notes: notes).suggestions()
}

private func json(
    spans: [ObservedSpan],
    configuration: ReportConfiguration = ReportConfiguration(timeZone: .gmt)
) -> String {
    let input = ReportInput(spans: spans)
    let result = ReportEngine(input: input, configuration: configuration).build()
    return RuleSuggester(input: input, result: result, configuration: configuration).jsonLines()
}

private func focus(
    on day: String,
    hour: Int = 9,
    minutes: Int,
    title: String,
    domain: String? = nil,
    bundle: String = "com.mitchellh.ghostty",
    app: String = "Ghostty"
) -> ObservedSpan {
    let start = date(String(format: "%@T%02d:00:00Z", day, hour))
    var attributes = [
        "app.name": app,
        "app.bundle_id": bundle,
        "window.title": title,
    ]
    if let domain { attributes["url.domain"] = domain }
    return ObservedSpan(
        name: "focus",
        start: start,
        end: start.addingTimeInterval(TimeInterval(minutes * 60)),
        attributes: attributes
    )
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
