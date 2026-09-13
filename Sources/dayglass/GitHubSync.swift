import DayglassCore
import Foundation

final class GitHubSync {
    private struct State: Codable {
        var ids: [String] = []
    }

    private struct Commit {
        let id: String
        let date: Date
        let changedLines: Int
    }

    private let dataRoot: URL

    init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    @discardableResult
    func run() throws -> Int {
        let login = try command(["api", "user", "--jq", ".login"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { throw GitHubSyncError.message("gh did not return a login") }
        let stateURL = dataRoot.appendingPathComponent("state/github-events.json")
        var known = Set(loadState(from: stateURL).ids)
        let sink = Sink(
            dayFile: DayFile(root: dataRoot.appendingPathComponent("otlp", isDirectory: true)),
            socketPath: dataRoot.appendingPathComponent("run/dayglass.sock")
        )
        let configuration = try loadConfiguration()
        var imported = 0
        for event in try events(login: login) {
            guard let id = string(event["id"]), let repository = string((event["repo"] as? [String: Any])?["name"]),
                  repository.hasPrefix("Gigooo-organization/") else { continue }
            let stateID = "github:\(id)"
            guard known.insert(stateID).inserted else { continue }
            guard let date = parseDate(string(event["created_at"])) else { continue }
            let payload = event["payload"] as? [String: Any]
            var attributes = [
                OTLPAttribute(key: "github.event.id", value: .string(id)),
                OTLPAttribute(key: "github.event.type", value: .string(string(event["type"]) ?? "unknown")),
                OTLPAttribute(key: "github.event.repo", value: .string(repository)),
                OTLPAttribute(key: "github.event.created_at", value: .string(string(event["created_at"]) ?? "")),
            ]
            appendPullRequestAttributes(&attributes, payload: payload)
            appendProject(&attributes, repository: repository, configuration: configuration)
            let line = try OTLPJSONL.logLine(eventName: "github.event", at: date, attributes: attributes)
            try sink.append(line, signal: .logs, at: date)
            imported += 1
        }

        imported += try importPullRequests(sink: sink, known: &known, configuration: configuration)
        imported += try importLocalCommits(sink: sink, known: &known, configuration: configuration)
        try saveState(State(ids: known.sorted()), to: stateURL)
        print("Imported \(imported) activity record(s)")
        return imported
    }

    private func events(login: String) throws -> [[String: Any]] {
        let data = try commandData(["api", "--paginate", "--slurp", "/users/\(login)/events?per_page=100"])
        let object = try JSONSerialization.jsonObject(with: data)
        if let pages = object as? [[[String: Any]]] { return pages.flatMap { $0 } }
        if let page = object as? [[String: Any]] { return page }
        throw GitHubSyncError.message("unexpected events response")
    }

    private func importPullRequests(
        sink: Sink,
        known: inout Set<String>,
        configuration: ReportConfiguration
    ) throws -> Int {
        guard let data = try? commandData([
            "search", "prs", "--author=@me", "--owner=Gigooo-organization", "--limit", "100",
            "--json", "number,repository,createdAt,mergedAt"
        ]), let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return 0
        }
        var imported = 0
        for value in values {
            guard let number = integer(value["number"]),
                  let repository = string((value["repository"] as? [String: Any])?["nameWithOwner"]),
                  repository.hasPrefix("Gigooo-organization/") else { continue }
            if let created = parseDate(string(value["createdAt"])) {
                imported += try appendSyntheticPullRequest(
                    id: "pr-created:\(repository)#\(number)",
                    date: created,
                    action: "opened",
                    merged: false,
                    number: number,
                    repository: repository,
                    sink: sink,
                    known: &known,
                    configuration: configuration
                )
            }
            if let merged = parseDate(string(value["mergedAt"])) {
                imported += try appendSyntheticPullRequest(
                    id: "pr-merged:\(repository)#\(number)",
                    date: merged,
                    action: "closed",
                    merged: true,
                    number: number,
                    repository: repository,
                    sink: sink,
                    known: &known,
                    configuration: configuration
                )
            }
        }
        return imported
    }

    private func appendSyntheticPullRequest(
        id: String,
        date: Date,
        action: String,
        merged: Bool,
        number: Int,
        repository: String,
        sink: Sink,
        known: inout Set<String>,
        configuration: ReportConfiguration
    ) throws -> Int {
        guard known.insert("github:\(id)").inserted else { return 0 }
        var attributes = [
            OTLPAttribute(key: "github.event.id", value: .string(id)),
            OTLPAttribute(key: "github.event.type", value: .string("PullRequestEvent")),
            OTLPAttribute(key: "github.event.repo", value: .string(repository)),
            OTLPAttribute(key: "github.event.action", value: .string(action)),
            OTLPAttribute(key: "github.event.pr_number", value: .int(Int64(number))),
            OTLPAttribute(key: "merged", value: .bool(merged)),
        ]
        appendProject(&attributes, repository: repository, configuration: configuration)
        try sink.append(try OTLPJSONL.logLine(eventName: "github.event", at: date, attributes: attributes), signal: .logs, at: date)
        return 1
    }

    private func importLocalCommits(
        sink: Sink,
        known: inout Set<String>,
        configuration: ReportConfiguration
    ) throws -> Int {
        let month = syncMonthString(Date())
        let input = try? ObservationStore(root: dataRoot.appendingPathComponent("otlp", isDirectory: true)).load(month: month)
        let directories = Set((input?.spans ?? []).compactMap { $0.attributes["dayglass.cwd"] })
        var imported = 0
        for directory in directories where FileManager.default.fileExists(atPath: directory) {
            let email = try? command(["-C", directory, "config", "user.email"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let email, !email.isEmpty else { continue }
            let start = "\(month)-01T00:00:00"
            let output = try? command([
                "-C", directory, "log", "--all", "--author=\(email)", "--since=\(start)",
                "--format=%H%x09%cI", "--numstat"
            ])
            let commits = parseCommits(output ?? "")
            for commit in commits {
                guard known.insert("git:\(commit.id)").inserted else { continue }
                var attributes = [
                    OTLPAttribute(key: "git.commit", value: .string(commit.id)),
                    OTLPAttribute(key: "changed_lines", value: .int(Int64(commit.changedLines))),
                ]
                appendProject(&attributes, path: directory, configuration: configuration)
                let line = try OTLPJSONL.logLine(eventName: "git.commit", at: commit.date, attributes: attributes)
                try sink.append(line, signal: .logs, at: commit.date)
                imported += 1
            }
        }
        return imported
    }

    private func parseCommits(_ output: String) -> [Commit] {
        var commits: [Commit] = []
        var currentID: String?
        var currentDate: Date?
        var changedLines = 0
        func flush() {
            guard let currentID, let currentDate else { return }
            commits.append(Commit(id: currentID, date: currentDate, changedLines: changedLines))
        }
        for line in output.split(whereSeparator: \ .isNewline) {
            let value = String(line)
            let header = value.split(separator: "\t", maxSplits: 1).map(String.init)
            if header.count == 2, header[0].count >= 7, header[0].allSatisfy({ $0.isHexDigit }), let date = parseDate(header[1]) {
                flush()
                currentID = header[0]
                currentDate = date
                changedLines = 0
            } else {
                let stats = value.split(separator: "\t")
                if stats.count >= 2 {
                    changedLines += (Int(stats[0]) ?? 0) + (Int(stats[1]) ?? 0)
                }
            }
        }
        flush()
        return commits
    }

    private func appendPullRequestAttributes(_ attributes: inout [OTLPAttribute], payload: [String: Any]?) {
        if let action = string(payload?["action"]) {
            attributes.append(OTLPAttribute(key: "github.event.action", value: .string(action)))
        }
        let pullRequest = payload?["pull_request"] as? [String: Any]
        let issue = payload?["issue"] as? [String: Any]
        if let number = integer(pullRequest?["number"] ?? issue?["number"]) {
            attributes.append(OTLPAttribute(key: "github.event.pr_number", value: .int(Int64(number))))
        }
        if let merged = pullRequest?["merged"] as? Bool {
            attributes.append(OTLPAttribute(key: "merged", value: .bool(merged)))
        }
    }

    private func appendProject(_ attributes: inout [OTLPAttribute], repository: String, configuration: ReportConfiguration) {
        if let project = configuration.projects.first(where: { $0.git.contains(where: { wildcard($0, matches: repository) }) }) {
            attributes.append(OTLPAttribute(key: "dayglass.project", value: .string(project.code)))
        }
    }

    private func appendProject(_ attributes: inout [OTLPAttribute], path: String, configuration: ReportConfiguration) {
        if let project = configuration.projects.first(where: { $0.git.contains(where: { wildcard($0, matches: path) }) }) {
            attributes.append(OTLPAttribute(key: "dayglass.project", value: .string(project.code)))
        }
    }

    private func loadConfiguration() throws -> ReportConfiguration {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/dayglass/projects.toml")
        return FileManager.default.fileExists(atPath: url.path) ? try ReportConfiguration.loadTOML(from: url) : ReportConfiguration()
    }

    private func loadState(from url: URL) -> State {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private func saveState(_ state: State, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func command(_ arguments: [String]) throws -> String {
        String(decoding: try commandData(arguments), as: UTF8.self)
    }

    private func commandData(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments.first == "git" ? arguments : ([arguments.first == "api" || arguments.first == "search" ? "gh" : "git"] + arguments)
        if arguments.first == "api" || arguments.first == "search" { process.arguments = ["gh"] + arguments }
        if arguments.first == "-C" { process.arguments = ["git"] + arguments }
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubSyncError.message(message.isEmpty ? "command failed" : message)
        }
        return output.fileHandleForReading.readDataToEndOfFile()
    }
}

private enum GitHubSyncError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let value) = self { return value }; return "github sync failed" }
}

private func string(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
}

private func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
}

private func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func syncMonthString(_ date: Date) -> String {
    let parts = DayglassCalendar.local.dateComponents([.year, .month], from: date)
    return String(format: "%04d-%02d", parts.year!, parts.month!)
}

private func wildcard(_ pattern: String, matches value: String) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
    return value.range(of: "^\(escaped)$", options: .regularExpression) != nil
}
