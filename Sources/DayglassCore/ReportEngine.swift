import Foundation

public struct ReportEngine: Sendable {
    private let input: ReportInput
    private let configuration: ReportConfiguration
    private let notes: [NoteRecord]

    public init(
        input: ReportInput,
        configuration: ReportConfiguration = ReportConfiguration(),
        notes: [NoteRecord] = []
    ) {
        self.input = input
        self.configuration = configuration
        self.notes = notes
    }

    public func build() -> ReportResult {
        let observedFocus = input.spans.filter { $0.name == "focus" && $0.end > $0.start }
        // The daemon reports the lock screen as an ordinary foreground app, so it becomes `afk` here.
        let focus = observedFocus.filter { !isLockScreen($0) }
        let afk = input.spans.filter { $0.name == "afk" && $0.end > $0.start } + observedFocus.filter(isLockScreen).map {
            ObservedSpan(name: "afk", start: $0.start, end: $0.end, attributes: ["dayglass.afk.reason": "locked"])
        }
        let audio = input.spans.filter { $0.name == "audio" && $0.end > $0.start }
        let signals = meetingSignals(audio: audio)
        let turns = input.spans.filter { $0.name == "gen_ai.turn" && $0.end > $0.start }
        let sessions = input.spans.filter { $0.name == "gen_ai.session" && $0.end > $0.start }
        let activeWindow = focus.reduce(into: Optional<TimeRange>.none) { result, span in
            let range = TimeRange(start: span.start, end: span.end)
            if let current = result {
                result = TimeRange(start: min(current.start, range.start), end: max(current.end, range.end))
            } else {
                result = range
            }
        }

        var candidates: [Candidate] = []
        for span in focus {
            for dayRange in splitByDay(TimeRange(start: span.start, end: span.end), calendar: configuration.calendar) {
                let cuts = afk.filter { $0.end > dayRange.start && $0.start < dayRange.end }
                for range in subtract(TimeRange(start: dayRange.start, end: dayRange.end), by: cuts.map { TimeRange(start: $0.start, end: $0.end) }) {
                    for piece in classifiedPieces(focus: span, range: range, turns: turns, sessions: sessions, signals: signals) {
                        if let candidate = apply(latestNote(overlapping: piece.range), to: piece) {
                            candidates.append(candidate)
                        }
                    }
                }
            }
        }
        candidates.append(contentsOf: afkMeetings(afk: afk, signals: signals, turns: turns))

        let blocks = candidates.map { candidate in
            ReportBlock(
                start: candidate.range.start,
                end: candidate.range.end,
                project: candidate.project,
                category: candidate.category,
                projectBasis: candidate.projectBasis,
                categoryBasis: candidate.categoryBasis,
                confidence: candidate.confidence,
                aiSeconds: overlapSeconds(candidate.range, with: turns),
                title: candidate.title
            )
        }.sorted { $0.start < $1.start }

        let rows = roundedRows(candidates: candidates)
        let questions = makeQuestions(
            candidates: candidates,
            afk: afk,
            signals: signals,
            activeWindow: activeWindow,
            focus: focus
        )
        return ReportResult(
            time: rows,
            ai: makeAIRows(turns: turns, sessions: sessions),
            output: makeOutputRows(logs: input.logs),
            blocks: blocks,
            questions: questions
        )
    }

    private func makeCandidate(
        focus: ObservedSpan,
        range: TimeRange,
        turns: [ObservedSpan],
        sessions: [ObservedSpan]
    ) -> Candidate {
        let project = project(for: focus, sessions: sessions, turns: turns)
        let category = category(for: focus)
        let confidence = project.code == nil ? "unassigned" : "inferred"
        return Candidate(
            range: range,
            project: project.code,
            category: category.category.rawValue,
            projectBasis: project.basis,
            categoryBasis: category.basis,
            confidence: confidence,
            projectAmbiguous: project.ambiguous,
            categoryAmbiguous: category.ambiguous,
            title: focus.attributes["window.title"],
            aiSeconds: overlapSeconds(range, with: turns)
        )
    }

    /// Calendar events first, then input-device `audio`. A calendar event carries a project when a
    /// `title` rule matches its title. Each event keeps only its most recently synced record, and a
    /// record marked deleted removes the event; the input is ordered by start, not by sync time.
    private func meetingSignals(audio: [ObservedSpan]) -> [MeetingSignal] {
        let records = input.spans.filter { $0.name == "calendar.event" && $0.end > $0.start }
        let latest = Dictionary(grouping: records) { $0.attributes["calendar.event.id"] ?? "\($0.start.timeIntervalSince1970)" }
            .compactMap { _, versions in versions.max { syncedAt($0) < syncedAt($1) } }
            .filter { $0.attributes["calendar.event.status"] != "deleted" }
            .sorted { $0.start < $1.start }
        let events = latest.map { event in
            let title = event.attributes["event.title"] ?? ""
            let project = configuration.projects.first { $0.title.contains { wildcard($0, matches: title) } }?.code
            return MeetingSignal(range: TimeRange(start: event.start, end: event.end), basis: "calendar", project: project)
        }
        return events + audio.map { MeetingSignal(range: TimeRange(start: $0.start, end: $0.end), basis: "audio", project: nil) }
    }

    /// `docs` during a meeting signal becomes `meeting` for the overlap only. Other categories stay
    /// put: a mic also runs for voice notes, and a calendar block may be heads-down time. An online
    /// meeting with no project takes the project of the calendar event it falls in.
    private func classifiedPieces(
        focus: ObservedSpan,
        range: TimeRange,
        turns: [ObservedSpan],
        sessions: [ObservedSpan],
        signals: [MeetingSignal]
    ) -> [Candidate] {
        let inferred = makeCandidate(focus: focus, range: range, turns: turns, sessions: sessions)
        let becomesMeeting = inferred.category == WorkCategory.docs.rawValue
        let needsProject = inferred.category == WorkCategory.meeting.rawValue && inferred.project == nil
        guard becomesMeeting || needsProject else { return [inferred] }
        let slices = meetingSlices(range, signals: becomesMeeting ? signals : signals.filter { $0.project != nil })
        guard !slices.isEmpty else { return [inferred] }
        let rest = subtract(range, by: slices.map(\.range)).map { slice in
            inferred.replacing(range: slice, aiSeconds: overlapSeconds(slice, with: turns))
        }
        let meetings = slices.map { slice in
            let project = inferred.project ?? slice.signal.project
            return inferred.replacing(
                range: slice.range,
                project: project,
                projectBasis: inferred.project == nil && project != nil ? slice.signal.basis : nil,
                category: WorkCategory.meeting.rawValue,
                categoryBasis: becomesMeeting ? slice.signal.basis : nil,
                confidence: "inferred",
                categoryAmbiguous: false,
                aiSeconds: overlapSeconds(slice.range, with: turns)
            )
        }
        return rest + meetings
    }

    /// Non-paused `afk` during a meeting signal is estimated as that meeting instead of
    /// disappearing into a gap question. `confidence` stays `inferred`.
    private func afkMeetings(afk: [ObservedSpan], signals: [MeetingSignal], turns: [ObservedSpan]) -> [Candidate] {
        let away = merge(afk.filter { $0.attributes["dayglass.afk.reason"] != "paused" }.map { TimeRange(start: $0.start, end: $0.end) })
        var candidates: [Candidate] = []
        for slice in away.flatMap({ meetingSlices($0, signals: signals) }) {
            for dayRange in splitByDay(slice.range, calendar: configuration.calendar) {
                let inferred = Candidate(
                    range: dayRange,
                    project: slice.signal.project,
                    category: WorkCategory.meeting.rawValue,
                    projectBasis: slice.signal.project == nil ? "none" : slice.signal.basis,
                    categoryBasis: slice.signal.basis,
                    confidence: "inferred",
                    projectAmbiguous: false,
                    categoryAmbiguous: false,
                    title: nil,
                    aiSeconds: overlapSeconds(dayRange, with: turns)
                )
                if let candidate = apply(latestNote(overlapping: dayRange), to: inferred) {
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }

    /// Parts of `range` covered by signals, each part credited to the first signal that covers it.
    private func meetingSlices(_ range: TimeRange, signals: [MeetingSignal]) -> [(range: TimeRange, signal: MeetingSignal)] {
        var slices: [(range: TimeRange, signal: MeetingSignal)] = []
        for signal in signals where signal.range.end > range.start && signal.range.start < range.end {
            let overlap = TimeRange(start: max(range.start, signal.range.start), end: min(range.end, signal.range.end))
            slices += subtract(overlap, by: slices.map(\.range)).map { ($0, signal) }
        }
        return slices
    }

    private func apply(_ note: NoteRecord?, to inferred: Candidate) -> Candidate? {
        guard let note else { return inferred }
        if note.skip { return nil }
        return inferred.with(
            project: note.project ?? inferred.project,
            category: note.category.flatMap(WorkCategory.init(rawValue:))?.rawValue ?? inferred.category,
            projectBasis: note.project == nil ? inferred.projectBasis : "note",
            categoryBasis: note.category == nil ? inferred.categoryBasis : "note",
            confidence: "confirmed"
        )
    }

    private func project(for focus: ObservedSpan, sessions: [ObservedSpan], turns: [ObservedSpan]) -> ProjectAssignment {
        let title = focus.attributes["window.title"] ?? ""
        let domain = focus.attributes["url.domain"] ?? ""
        let path = focus.attributes["url.path"] ?? ""
        for rule in configuration.projects {
            if rule.title.contains(where: { wildcard($0, matches: title) }) {
                return ProjectAssignment(code: rule.code, basis: "title")
            }
            if rule.url.contains(where: { wildcard($0, matches: domain) || wildcard($0, matches: domain + path) }) {
                return ProjectAssignment(code: rule.code, basis: "url")
            }
        }
        if domain == "github.com", let code = projectCode(at: domain + path, anyOwner: false) {
            return ProjectAssignment(code: code, basis: "url")
        }

        guard isCodeApplication(focus) else {
            return ProjectAssignment(code: nil, basis: "none")
        }
        // Sessions stay open for days, so a turn running under the focus says more than an idle open session.
        let overlapping = { (spans: [ObservedSpan]) in spans.filter { $0.end > focus.start && $0.start < focus.end } }
        // ponytail: 30-minute lookback for reading a turn's output; tune once notes show how often it is wrong.
        let recent = turns.filter { $0.end <= focus.start && $0.end > focus.start.addingTimeInterval(-30 * 60) }.max { $0.end < $1.end }
        let active = overlapping(turns).isEmpty ? (recent.map { [$0] } ?? []) : overlapping(turns)
        let matching = Set((active.isEmpty ? overlapping(sessions) : active).compactMap { span -> String? in
            if let declared = span.attributes["dayglass.project"], configuration.projects.contains(where: { $0.code == declared }) {
                return declared
            }
            let location = span.attributes["vcs.repository.url.full"] ?? span.attributes["dayglass.cwd"] ?? ""
            return projectCode(at: location, anyOwner: true)
        })
        if matching.count == 1, let code = matching.first {
            return ProjectAssignment(code: code, basis: "session")
        }
        return ProjectAssignment(code: nil, basis: matching.isEmpty ? "none" : "session", ambiguous: matching.count > 1)
    }

    /// A configured `git` pattern wins. Otherwise a GitHub checkout or repository page is its own
    /// project, named after the repository; pages are limited to the organization's repositories.
    private func projectCode(at location: String, anyOwner: Bool) -> String? {
        if let rule = configuration.projects.first(where: { $0.git.contains { wildcard($0, matches: location) } }) {
            return rule.code
        }
        guard let repository = repositoryName(in: location, anyOwner: anyOwner) else { return nil }
        let suffix = "/" + repository.lowercased()
        let named = configuration.projects.first { rule in
            rule.git.contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*/")).lowercased().hasSuffix(suffix) }
        }
        return named?.code ?? repository
    }

    private func category(for focus: ObservedSpan) -> CategoryAssignment {
        let bundle = focus.attributes["app.bundle_id"] ?? ""
        let app = (focus.attributes["app.name"] ?? "").lowercased()
        let domain = (focus.attributes["url.domain"] ?? "").lowercased()
        let path = (focus.attributes["url.path"] ?? "").lowercased()

        for rule in configuration.categories where
            rule.bundles.contains(where: { wildcard($0.lowercased(), matches: bundle.lowercased()) }) ||
            rule.domains.contains(where: { wildcard($0.lowercased(), matches: domain) }) ||
            rule.paths.contains(where: { path.contains($0.lowercased()) }) {
            return CategoryAssignment(category: rule.category, basis: domain.isEmpty ? "bundle" : "url")
        }

        if isMeetingApp(app: app, bundle: bundle) || domain == "meet.google.com" || domain == "teams.microsoft.com" || domain.hasSuffix(".zoom.us") {
            return CategoryAssignment(category: .meeting, basis: domain.isEmpty ? "bundle" : "url")
        }
        if isChatApp(app: app, bundle: bundle) || ["app.slack.com", "discord.com", "www.chatwork.com", "talk.worksmobile.com"].contains(domain) {
            return CategoryAssignment(category: .communication, basis: domain.isEmpty ? "bundle" : "url")
        }
        if domain == "github.com" && (path.contains("/pull/") || path.contains("/compare/")) {
            return CategoryAssignment(category: .review, basis: "url")
        }
        if isDocsApp(app: app, bundle: bundle) || domain == "docs.google.com" || domain == "notion.so" || (domain.hasSuffix(".atlassian.net") && path.contains("/wiki/")) {
            return CategoryAssignment(category: .docs, basis: domain.isEmpty ? "bundle" : "url")
        }
        if isBrowser(bundle: bundle, app: app) && !domain.isEmpty {
            return CategoryAssignment(category: .research, basis: "url")
        }
        if isCodeApplication(focus) {
            return CategoryAssignment(category: .coding, basis: "bundle", ambiguous: true)
        }
        return CategoryAssignment(category: .other, basis: "none")
    }

    private func roundedRows(candidates: [Candidate]) -> [ReportTimeRow] {
        let grouped = Dictionary(grouping: candidates) { candidate in
            GroupKey(day: dayString(candidate.range.start), project: candidate.project, category: candidate.category)
        }
        let rawGroups = grouped.map { key, values in
            RawGroup(
                key: key,
                seconds: values.reduce(0) { $0 + duration($1.range) },
                aiSeconds: values.reduce(0) { $0 + $1.aiSeconds },
                confidenceSeconds: Dictionary(grouping: values, by: \ .confidence).mapValues { group in
                    group.reduce(0) { $0 + duration($1.range) }
                },
                projectBasis: values.map(\ .projectBasis).max() ?? "none",
                categoryBasis: values.map(\ .categoryBasis).max() ?? "none"
            )
        }
        let byDay = Dictionary(grouping: rawGroups, by: \ .key.day)
        return byDay.keys.sorted().flatMap { day in
            let dayGroups = byDay[day, default: []].sorted { $0.key.label < $1.key.label }
            let total = dayGroups.reduce(0) { $0 + $1.seconds }
            let targetUnits = Int((Double(total) / 900).rounded())
            let allocations = allocateUnits(dayGroups.map(\ .seconds), targetUnits: targetUnits)
            return zip(dayGroups, allocations).map { group, units in
                let seconds = units * 900
                let confidence = group.confidenceSeconds.count == 1 ? group.confidenceSeconds.keys.first! : "mixed"
                let confirmed = allocateSeconds(group.confidenceSeconds["confirmed"] ?? 0, within: group.seconds, total: seconds)
                let inferred = allocateSeconds(group.confidenceSeconds["inferred"] ?? 0, within: group.seconds, total: seconds)
                let unassigned = max(0, seconds - confirmed - inferred)
                return ReportTimeRow(
                    day: day,
                    project: group.key.project,
                    category: group.key.category,
                    seconds: seconds,
                    aiSeconds: Int(Double(group.aiSeconds).rounded()),
                    confidence: confidence,
                    confirmedSeconds: confirmed,
                    inferredSeconds: inferred,
                    unassignedSeconds: unassigned,
                    projectBasis: group.projectBasis,
                    categoryBasis: group.categoryBasis
                )
            }
        }
    }

    private func makeAIRows(turns: [ObservedSpan], sessions: [ObservedSpan]) -> [ReportAIRow] {
        struct Key: Hashable { let day: String; let project: String?; let agent: String }
        typealias Totals = (sessions: Set<String>, turns: Int, edits: Int, input: Int, read: Int, write: Int, output: Int)
        let empty: Totals = (sessions: [], turns: 0, edits: 0, input: 0, read: 0, write: 0, output: 0)
        var values: [Key: Totals] = [:]
        for turn in turns {
            let agent = turn.attributes["gen_ai.agent.name"] ?? "unknown"
            let overlappingSessions = sessions.filter { $0.end > turn.start && $0.start < turn.end }
            let projects = Set(overlappingSessions.compactMap { $0.attributes["dayglass.project"] })
            let project = projects.count == 1 ? projects.first : turn.attributes["dayglass.project"]
            let key = Key(day: dayString(turn.start), project: project, agent: agent)
            var updated = values[key] ?? empty
            updated.turns += 1
            updated.edits += Int(turn.attributes["dayglass.edit_calls"] ?? "0") ?? 0 > 0 ? 1 : 0
            updated.input += integerAttribute(turn, names: ["gen_ai.usage.input_uncached", "input_uncached"])
            updated.read += integerAttribute(turn, names: ["gen_ai.usage.cache_read_tokens", "cache_read_tokens"])
            updated.write += integerAttribute(turn, names: ["gen_ai.usage.cache_creation_tokens", "cache_write_tokens", "cache_write_token_count"])
            updated.output += integerAttribute(turn, names: ["gen_ai.usage.output_tokens", "output_tokens", "output_token_count"])
            for session in overlappingSessions { updated.sessions.insert(session.attributes["gen_ai.conversation.id"] ?? session.start.description) }
            values[key] = updated
        }
        for session in sessions where !turns.contains(where: { $0.end > session.start && $0.start < session.end }) {
            let agent = session.attributes["gen_ai.agent.name"] ?? "unknown"
            let key = Key(day: dayString(session.start), project: session.attributes["dayglass.project"], agent: agent)
            var existing = values[key] ?? empty
            existing.sessions.insert(session.attributes["gen_ai.conversation.id"] ?? session.start.description)
            values[key] = existing
        }
        return values.map { key, value in
            ReportAIRow(
                day: key.day,
                project: key.project,
                agent: key.agent,
                sessions: value.sessions.count,
                turns: value.turns,
                editTurns: value.edits,
                inputUncached: value.input,
                cacheRead: value.read,
                cacheWrite: value.write,
                output: value.output
            )
        }.sorted { "\($0.day)|\($0.project ?? "")|\($0.agent)" < "\($1.day)|\($1.project ?? "")|\($1.agent)" }
    }

    private func makeOutputRows(logs: [ObservedLog]) -> [ReportOutputRow] {
        struct Key: Hashable { let day: String; let project: String? }
        var values: [Key: ReportOutputRow] = [:]
        for log in logs where log.name == "github.event" || log.name == "git.commit" {
            let key = Key(day: dayString(log.timestamp), project: log.attributes["dayglass.project"])
            var row = values[key] ?? ReportOutputRow(day: key.day, project: key.project)
            let type = log.attributes["github.event.type"] ?? log.attributes["type"] ?? ""
            let action = log.attributes["github.event.action"] ?? log.attributes["action"] ?? ""
            let isPullRequest = type == "PullRequestEvent" || type == "PullRequestReviewEvent"
            let isLocalCommit = log.name == "git.commit"
            row = ReportOutputRow(
                day: row.day,
                project: row.project,
                commits: row.commits + (isLocalCommit || type == "PushEvent" ? 1 : 0),
                changedLines: row.changedLines + (Int(log.attributes["changed_lines"] ?? "0") ?? 0),
                createdPRs: row.createdPRs + (isPullRequest && action == "opened" ? 1 : 0),
                mergedPRs: row.mergedPRs + (isPullRequest && action == "closed" && log.attributes["merged"] == "true" ? 1 : 0),
                reviewedPRs: row.reviewedPRs + (type == "PullRequestReviewEvent" ? 1 : 0)
            )
            values[key] = row
        }
        return values.values.sorted { "\($0.day)|\($0.project ?? "")" < "\($1.day)|\($1.project ?? "")" }
    }

    private func makeQuestions(
        candidates: [Candidate],
        afk: [ObservedSpan],
        signals: [MeetingSignal],
        activeWindow: TimeRange?,
        focus: [ObservedSpan]
    ) -> [ReportQuestion] {
        var questions: [ReportQuestion] = []
        for candidate in merge(candidates.filter { $0.project == nil }.map(\ .range)) where Double(duration(candidate)) >= configuration.thresholds.unassigned {
            questions.append(question(kind: "unassigned", range: candidate, options: neighboringProjects(candidates: candidates, range: candidate), evidence: onScreenEvidence(in: candidate, focus: focus)))
        }
        for range in merge(candidates.filter(\.projectAmbiguous).map(\.range)) where Double(duration(range)) >= configuration.thresholds.unassigned {
            questions.append(question(kind: "ambiguous_project", range: range, options: configuration.projects.map(\ .code), evidence: onScreenEvidence(in: range, focus: focus)))
        }
        for candidate in merge(candidates.filter { $0.categoryAmbiguous && $0.aiSeconds == 0 }.map(\ .range)) where Double(duration(candidate)) >= configuration.thresholds.ambiguousCategory {
            questions.append(question(kind: "ambiguous_category", range: candidate, options: ["coding", "review", "docs", "research"], evidence: onScreenEvidence(in: candidate, focus: focus)))
        }
        if let activeWindow {
            let uncovered = uncoveredAfkRanges(afk: afk, activeWindow: activeWindow, signals: signals)
            for span in uncovered where Double(duration(span)) >= configuration.thresholds.gap {
                let reason = afk.first { $0.start <= span.start && $0.end >= span.end }?.attributes["dayglass.afk.reason"]
                // ponytail: fixed 2h ceiling; a lock that long is off hours, make it a threshold if teams disagree.
                if reason == "locked" || reason == "sleep", duration(span) >= 2 * 3600 { continue }
                let options = reason == "locked" || reason == "sleep" ? ["skip", "meeting", "research"] : ["meeting", "research", "skip"]
                questions.append(question(kind: "gap", range: span, options: options, evidence: onScreenEvidence(in: span, focus: focus)))
            }
            let runs = input.spans.filter { $0.name == "dayglass.run" }.map { TimeRange(start: $0.start, end: $0.end) }
            for missing in subtract(activeWindow, by: runs) where Double(duration(missing)) >= configuration.thresholds.missing {
                questions.append(question(kind: "missing", range: missing, options: ["meeting", "research", "skip", "daemon stopped"], evidence: onScreenEvidence(in: missing, focus: focus)))
            }
        }
        return questions.sorted { $0.start == $1.start ? $0.kind < $1.kind : $0.start < $1.start }
    }

    /// Window titles and URL fragments that were on screen during `range`, so the
    /// person answering can recall what the block was. `--no-titles` drops these.
    private func onScreenEvidence(in range: TimeRange, focus: [ObservedSpan]) -> [String] {
        var fragments: [String] = []
        for span in focus.sorted(by: { $0.start < $1.start }) where span.end > range.start && span.start < range.end {
            guard let fragment = evidenceFragment(span), !fragments.contains(fragment) else { continue }
            fragments.append(fragment)
        }
        return Array(fragments.prefix(4))
    }

    private func evidenceFragment(_ span: ObservedSpan) -> String? {
        if let title = span.attributes["window.title"], !title.isEmpty { return title }
        guard let domain = span.attributes["url.domain"], !domain.isEmpty else { return nil }
        return domain + (span.attributes["url.path"] ?? "")
    }

    private func question(kind: String, range: TimeRange, options: [String], evidence: [String]) -> ReportQuestion {
        let key = "\(kind)|\(range.start.timeIntervalSince1970)|\(range.end.timeIntervalSince1970)"
        return ReportQuestion(
            id: stableID(key),
            kind: kind,
            start: range.start,
            end: range.end,
            seconds: duration(range),
            options: Array(options.prefix(4)),
            evidence: evidence
        )
    }

    private func neighboringProjects(candidates: [Candidate], range: TimeRange) -> [String] {
        var values = candidates.filter { $0.range.end <= range.start || $0.range.start >= range.end }.compactMap(\ .project)
        values.append(contentsOf: configuration.projects.map(\ .code))
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// `afk` inside the active window, with meeting-signal overlaps removed, before the gap threshold.
    private func uncoveredAfkRanges(afk: [ObservedSpan], activeWindow: TimeRange, signals: [MeetingSignal]) -> [TimeRange] {
        let signalRanges = signals.map(\.range)
        let clipped = afk
            .filter { $0.attributes["dayglass.afk.reason"] != "paused" }
            .map { TimeRange(start: max($0.start, activeWindow.start), end: min($0.end, activeWindow.end)) }
            .filter { $0.end > $0.start }
        return merge(clipped).flatMap { subtract($0, by: signalRanges) }
    }

    private func latestNote(overlapping range: TimeRange) -> NoteRecord? {
        notes.last { note in
            guard let start = note.start, let end = note.end else { return false }
            return end > range.start && start < range.end
        }
    }

    private func dayString(_ date: Date) -> String {
        let parts = configuration.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

private func integerAttribute(_ span: ObservedSpan, names: [String]) -> Int {
    for name in names {
        if let value = span.attributes[name] { return Int(value) ?? 0 }
    }
    return 0
}

private struct Candidate: Sendable {
    let range: TimeRange
    let project: String?
    let category: String
    let projectBasis: String
    let categoryBasis: String
    let confidence: String
    let projectAmbiguous: Bool
    let categoryAmbiguous: Bool
    let title: String?
    let aiSeconds: Int

    func with(
        project: String?,
        category: String,
        projectBasis: String,
        categoryBasis: String,
        confidence: String
    ) -> Candidate {
        Candidate(
            range: range,
            project: project,
            category: category,
            projectBasis: projectBasis,
            categoryBasis: categoryBasis,
            confidence: confidence,
            projectAmbiguous: false,
            categoryAmbiguous: false,
            title: title,
            aiSeconds: aiSeconds
        )
    }

    func replacing(
        range: TimeRange,
        project: String? = nil,
        projectBasis: String? = nil,
        category: String? = nil,
        categoryBasis: String? = nil,
        confidence: String? = nil,
        categoryAmbiguous: Bool? = nil,
        aiSeconds: Int
    ) -> Candidate {
        Candidate(
            range: range,
            project: project ?? self.project,
            category: category ?? self.category,
            projectBasis: projectBasis ?? self.projectBasis,
            categoryBasis: categoryBasis ?? self.categoryBasis,
            confidence: confidence ?? self.confidence,
            projectAmbiguous: projectAmbiguous,
            categoryAmbiguous: categoryAmbiguous ?? self.categoryAmbiguous,
            title: title,
            aiSeconds: aiSeconds
        )
    }
}

private struct MeetingSignal: Sendable {
    let range: TimeRange
    let basis: String
    let project: String?
}

private struct ProjectAssignment {
    let code: String?
    let basis: String
    var ambiguous: Bool = false
}

private struct CategoryAssignment {
    let category: WorkCategory
    let basis: String
    var ambiguous: Bool = false
}

private struct TimeRange: Equatable, Sendable {
    let start: Date
    let end: Date
}

private struct GroupKey: Hashable, Sendable {
    let day: String
    let project: String?
    let category: String

    var label: String { "\(project ?? "")|\(category)" }
}

private struct RawGroup: Sendable {
    let key: GroupKey
    let seconds: Int
    let aiSeconds: Int
    let confidenceSeconds: [String: Int]
    let projectBasis: String
    let categoryBasis: String
}

private func duration(_ range: TimeRange) -> Int {
    max(0, Int(range.end.timeIntervalSince(range.start).rounded()))
}

private func overlappingRanges(_ range: TimeRange, with spans: [ObservedSpan]) -> [TimeRange] {
    merge(spans.compactMap { span in
        let start = max(range.start, span.start)
        let end = min(range.end, span.end)
        guard end > start else { return nil }
        return TimeRange(start: start, end: end)
    })
}

private func overlapSeconds(_ range: TimeRange, with spans: [ObservedSpan]) -> Int {
    spans.reduce(0) { total, span in
        let start = max(range.start, span.start)
        let end = min(range.end, span.end)
        return total + (end > start ? Int(end.timeIntervalSince(start).rounded()) : 0)
    }
}

private func subtract(_ source: TimeRange, by cuts: [TimeRange]) -> [TimeRange] {
    var result = [source]
    for cut in cuts.sorted(by: { $0.start < $1.start }) {
        result = result.flatMap { range in
            guard cut.end > range.start && cut.start < range.end else { return [range] }
            var pieces: [TimeRange] = []
            if cut.start > range.start { pieces.append(TimeRange(start: range.start, end: min(cut.start, range.end))) }
            if cut.end < range.end { pieces.append(TimeRange(start: max(cut.end, range.start), end: range.end)) }
            return pieces.filter { $0.end > $0.start }
        }
    }
    return result
}

private func splitByDay(_ source: TimeRange, calendar: Calendar) -> [TimeRange] {
    var ranges: [TimeRange] = []
    var cursor = source.start
    while cursor < source.end {
        let dayStart = calendar.startOfDay(for: cursor)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? source.end
        let end = min(nextDay, source.end)
        ranges.append(TimeRange(start: cursor, end: end))
        cursor = end
    }
    return ranges
}

private func merge(_ ranges: [TimeRange]) -> [TimeRange] {
    ranges.sorted { $0.start < $1.start }.reduce(into: [TimeRange]()) { result, range in
        guard let last = result.last else {
            result.append(range)
            return
        }
        if range.start <= last.end {
            result[result.count - 1] = TimeRange(start: last.start, end: max(last.end, range.end))
        } else {
            result.append(range)
        }
    }
}

private func allocateUnits(_ values: [Int], targetUnits: Int) -> [Int] {
    guard let total = values.reduce(0, +) as Int?, total > 0, targetUnits > 0 else { return Array(repeating: 0, count: values.count) }
    let exact = values.map { Double($0) / Double(total) * Double(targetUnits) }
    var units = exact.map { Int($0.rounded(.down)) }
    var remaining = targetUnits - units.reduce(0, +)
    for index in exact.indices.sorted(by: { exact[$0] - floor(exact[$0]) > exact[$1] - floor(exact[$1]) }) where remaining > 0 {
        units[index] += 1
        remaining -= 1
    }
    return units
}

private func allocateSeconds(_ value: Int, within raw: Int, total: Int) -> Int {
    guard raw > 0, total > 0 else { return 0 }
    return Int((Double(value) / Double(raw) * Double(total)).rounded())
}

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

private func isBrowser(bundle: String, app: String) -> Bool {
    ["safari", "chrome", "edge", "firefox", "brave", "arc", "aside"].contains { app.contains($0) } ||
        ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser", "company.thebrowser.Browser", "at.studio.AsideBrowser"].contains(bundle)
}

private func isCodeApplication(_ span: ObservedSpan) -> Bool {
    let app = (span.attributes["app.name"] ?? "").lowercased()
    let bundle = (span.attributes["app.bundle_id"] ?? "").lowercased()
    return ["terminal", "iterm", "wezterm", "ghostty", "kitty", "alacritty", "warp", "xcode", "visual studio", "code", "cursor", "zed", "emacs", "nvim", "neovim"].contains { app.contains($0) } ||
        ["com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode"].contains(bundle)
}

private func isMeetingApp(app: String, bundle: String) -> Bool {
    app.contains("zoom") || app.contains("teams") || app.contains("facetime") || bundle.lowercased().contains("zoom") || bundle.lowercased().contains("teams")
}

private func isChatApp(app: String, bundle: String) -> Bool {
    ["slack", "line works", "discord", "chatwork"].contains { app.contains($0) } ||
        ["com.tinyspeck.slackmacgap", "com.naver.lineworks", "com.hnc.Discord"].contains(bundle)
}

private func isDocsApp(app: String, bundle: String) -> Bool {
    ["keynote", "pages", "numbers", "word", "excel", "powerpoint", "obsidian", "notion"].contains { app.contains($0) } || bundle.lowercased().contains("obsidian") || bundle.lowercased().contains("notion")
}

private func stableID(_ value: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1099511628211
    }
    return String(format: "%016llx", hash)
}

private func isLockScreen(_ span: ObservedSpan) -> Bool {
    span.attributes["app.bundle_id"] == "com.apple.loginwindow" || span.attributes["app.name"] == "loginwindow"
}

private let workOrganization = "Gigooo-organization"

private func repositoryName(in location: String, anyOwner: Bool) -> String? {
    let parts = location.split(separator: "/").map(String.init)
    if let host = parts.firstIndex(of: "github.com"), parts.count > host + 2 {
        let owner = parts[host + 1]
        guard anyOwner || owner.caseInsensitiveCompare(workOrganization) == .orderedSame else { return nil }
        return parts[host + 2]
    }
    if anyOwner, let worktrees = parts.firstIndex(of: "worktrees"), worktrees > 0, parts[worktrees - 1] == ".t3", parts.count > worktrees + 1 {
        return parts[worktrees + 1]
    }
    return nil
}

private func syncedAt(_ span: ObservedSpan) -> Double {
    Double(span.attributes["calendar.synced_at"] ?? "") ?? 0
}
