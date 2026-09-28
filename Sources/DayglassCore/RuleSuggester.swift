import Foundation

/// Deterministic `projects.toml` candidates for terms that keep showing up
/// on unassigned and ambiguous-category time. The report skill presents this
/// output and does not edit the file.
public struct RuleSuggester: Sendable {
    public let input: ReportInput
    public let result: ReportResult
    public let configuration: ReportConfiguration
    public let notes: [NoteRecord]

    public init(
        input: ReportInput,
        result: ReportResult,
        configuration: ReportConfiguration,
        notes: [NoteRecord] = []
    ) {
        self.input = input
        self.result = result
        self.configuration = configuration
        self.notes = notes
    }

    public func suggestions() -> [RuleSuggestion] {
        let focus = input.spans.filter { $0.name == "focus" && $0.end > $0.start }
        var buckets: [TermKey: Bucket] = [:]

        for block in result.blocks where block.projectBasis == "none" {
            let seconds = elapsed(block.start, block.end)
            guard seconds > 0 else { continue }
            let day = dayString(block.start)
            for word in titleWords(block.title ?? "") {
                record(
                    term: word,
                    kind: .projectTitle,
                    day: day,
                    seconds: seconds,
                    start: block.start,
                    end: block.end,
                    into: &buckets
                )
            }
            var seenDomains: Set<String> = []
            for span in focus where overlaps(span.start, span.end, block.start, block.end) {
                guard let domain = span.attributes["url.domain"], !domain.isEmpty else { continue }
                let folded = fold(domain)
                guard seenDomains.insert(folded).inserted else { continue }
                record(
                    term: domain,
                    kind: .projectURL,
                    day: day,
                    seconds: seconds,
                    start: block.start,
                    end: block.end,
                    into: &buckets
                )
            }
        }

        for question in result.questions where question.kind == "ambiguous_category" {
            for span in focus where overlaps(span.start, span.end, question.start, question.end) {
                let start = max(span.start, question.start)
                let end = min(span.end, question.end)
                let seconds = elapsed(start, end)
                guard seconds > 0 else { continue }
                let day = dayString(start)
                if let domain = span.attributes["url.domain"], !domain.isEmpty {
                    record(
                        term: domain,
                        kind: .categoryDomain,
                        day: day,
                        seconds: seconds,
                        start: start,
                        end: end,
                        into: &buckets
                    )
                }
                if let bundle = span.attributes["app.bundle_id"], !bundle.isEmpty {
                    record(
                        term: bundle,
                        kind: .categoryBundle,
                        day: day,
                        seconds: seconds,
                        start: start,
                        end: end,
                        into: &buckets
                    )
                }
            }
        }

        let minimumOccurrences = configuration.thresholds.suggestOccurrences
        let minimumDays = configuration.thresholds.suggestDays
        return buckets.values
            .filter { bucket in
                bucket.occurrences >= minimumOccurrences
                    && bucket.days.count >= minimumDays
                    && !covered(bucket.term)
            }
            .sorted { lhs, rhs in
                if lhs.days.count != rhs.days.count { return lhs.days.count > rhs.days.count }
                if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
                let left = fold(lhs.term)
                let right = fold(rhs.term)
                if left != right { return left < right }
                return lhs.kind < rhs.kind
            }
            .map { bucket in
                let value = suggestedValue(kind: bucket.kind, term: bucket.term, intervals: bucket.intervals)
                return RuleSuggestion(
                    term: bucket.term,
                    days: bucket.days.count,
                    seconds: bucket.seconds,
                    toml: fragment(kind: bucket.kind, term: bucket.term, value: value)
                )
            }
    }

    public func jsonLines() -> String {
        let lines = suggestions()
        guard !lines.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return lines.compactMap { suggestion -> String? in
            guard let data = try? encoder.encode(suggestion) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
    }

    private func record(
        term: String,
        kind: SuggestionKind,
        day: String,
        seconds: Int,
        start: Date,
        end: Date,
        into buckets: inout [TermKey: Bucket]
    ) {
        let key = TermKey(term: fold(term), kind: kind)
        if buckets[key] == nil {
            buckets[key] = Bucket(term: term, kind: kind)
        }
        if term < buckets[key]!.term {
            buckets[key]!.term = term
        }
        buckets[key]!.days.insert(day)
        buckets[key]!.occurrences += 1
        buckets[key]!.seconds += seconds
        buckets[key]!.intervals.append(TermInterval(start: start, end: end))
    }

    /// A note that already confirmed this term supplies the project code or category.
    /// Notes are append-only, so the latest overlapping answer wins.
    private func suggestedValue(kind: SuggestionKind, term: String, intervals: [TermInterval]) -> String? {
        func answer(_ note: NoteRecord) -> String? {
            guard !note.skip else { return nil }
            let value = kind.isProject ? note.project : note.category
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let focus = input.spans.filter { $0.name == "focus" && $0.end > $0.start }
        let matched = notes.last { note in
            guard answer(note) != nil, let start = note.start, let end = note.end else { return false }
            if intervals.contains(where: { end > $0.start && start < $0.end }) { return true }
            return focus.contains { span in
                overlaps(span.start, span.end, start, end) && spanHasTerm(span, term)
            }
        }
        return matched.flatMap(answer)
    }

    private func spanHasTerm(_ span: ObservedSpan, _ term: String) -> Bool {
        let folded = fold(term)
        if titleWords(span.attributes["window.title"] ?? "").contains(where: { fold($0) == folded }) { return true }
        if let domain = span.attributes["url.domain"], fold(domain) == folded { return true }
        if let bundle = span.attributes["app.bundle_id"], fold(bundle) == folded { return true }
        return false
    }

    private func covered(_ term: String) -> Bool {
        var patterns: [String] = []
        for project in configuration.projects {
            patterns.append(contentsOf: project.git)
            patterns.append(contentsOf: project.title)
            patterns.append(contentsOf: project.url)
        }
        for category in configuration.categories {
            patterns.append(contentsOf: category.bundles)
            patterns.append(contentsOf: category.domains)
            patterns.append(contentsOf: category.paths)
        }
        return patterns.contains { wildcard($0, matches: term) }
    }

    private func fragment(kind: SuggestionKind, term: String, value: String?) -> String {
        switch kind {
        case .projectTitle:
            return projectFragment(key: "title", term: term, code: value)
        case .projectURL:
            return projectFragment(key: "url", term: term, code: value)
        case .categoryDomain:
            return categoryFragment(key: "domains", term: term, category: value)
        case .categoryBundle:
            return categoryFragment(key: "bundles", term: term, category: value)
        }
    }

    private func projectFragment(key: String, term: String, code: String?) -> String {
        var lines = ["[[project]]"]
        if let code, !code.isEmpty { lines.append("code = \(tomlString(code))") }
        lines.append("\(key) = [\(tomlString(term))]")
        return lines.joined(separator: "\n")
    }

    private func categoryFragment(key: String, term: String, category: String?) -> String {
        var lines = ["[[category]]"]
        if let category, !category.isEmpty { lines.append("category = \(tomlString(category))") }
        lines.append("\(key) = [\(tomlString(term))]")
        return lines.joined(separator: "\n")
    }

    private func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func dayString(_ date: Date) -> String {
        let parts = configuration.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func elapsed(_ start: Date, _ end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start).rounded()))
    }

    private func overlaps(_ start: Date, _ end: Date, _ otherStart: Date, _ otherEnd: Date) -> Bool {
        end > otherStart && start < otherEnd
    }

    private func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func titleWords(_ title: String) -> [String] {
        var words: [String] = []
        var token = ""
        var seen: Set<String> = []
        func flush() {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
            token = ""
            guard trimmed.count >= 2, trimmed.contains(where: \.isLetter) else { return }
            guard seen.insert(fold(trimmed)).inserted else { return }
            words.append(trimmed)
        }
        for character in title {
            if character.isLetter || character.isNumber || character == "." || character == "_" || character == "-" {
                token.append(character)
            } else {
                flush()
            }
        }
        flush()
        return words
    }
}

public struct RuleSuggestion: Codable, Equatable, Sendable {
    public let term: String
    public let days: Int
    public let seconds: Int
    public let toml: String

    public init(term: String, days: Int, seconds: Int, toml: String) {
        self.term = term
        self.days = days
        self.seconds = seconds
        self.toml = toml
    }
}

private struct TermKey: Hashable {
    let term: String
    let kind: SuggestionKind
}

private enum SuggestionKind: Int, Comparable {
    case projectTitle
    case projectURL
    case categoryDomain
    case categoryBundle

    var isProject: Bool { self == .projectTitle || self == .projectURL }

    static func < (lhs: SuggestionKind, rhs: SuggestionKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private struct TermInterval {
    let start: Date
    let end: Date
}

private struct Bucket {
    var term: String
    var kind: SuggestionKind
    var days: Set<String> = []
    var occurrences: Int = 0
    var seconds: Int = 0
    var intervals: [TermInterval] = []
}

/// Same matching rules the report uses when a `[[project]]` or `[[category]]` pattern is applied.
private func wildcard(_ pattern: String, matches value: String) -> Bool {
    guard !pattern.isEmpty else { return false }
    if pattern == "*" { return true }
    let pieces = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
    guard pieces.count > 1 else { return value.localizedCaseInsensitiveContains(pattern) }
    var cursor = value.startIndex
    for (index, piece) in pieces.enumerated() where !piece.isEmpty {
        guard let found = value.range(of: piece, options: .caseInsensitive, range: cursor..<value.endIndex) else { return false }
        if index == 0 && found.lowerBound != value.startIndex { return false }
        cursor = found.upperBound
    }
    if !pattern.hasSuffix("*"), let last = pieces.last, !last.isEmpty {
        return value.localizedCaseInsensitiveCompare(last) == .orderedSame || value.hasSuffix(last)
    }
    return true
}
