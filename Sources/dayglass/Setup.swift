import Foundation

final class SetupCoordinator {
    enum Mode: String {
        case all
        case hooks
        case telemetry
    }

    private let dataRoot: URL
    private let home: URL
    private let fileManager = FileManager.default

    init(dataRoot: URL, home: URL? = nil) {
        self.dataRoot = dataRoot
        let configuredHome = ProcessInfo.processInfo.environment["DAYGLASS_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.home = home ?? configuredHome ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func run(mode: Mode) throws {
        if mode == .all || mode == .hooks { try installHooks() }
        if mode == .all || mode == .telemetry { try installTelemetry() }
        if mode == .all {
            try createBaseFiles()
            try installLaunchAgents()
            addTimeMachineExclusion()
            printGHStatus()
            printSigningInstructions()
        }
        print("dayglass setup \(mode.rawValue) complete")
    }

    private func installHooks() throws {
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        try updateJSON(at: claudeURL) { root in
            var hooks = try object(root["hooks"], key: "hooks", path: claudeURL)
            for event in hookEvents {
                var entries = try array(hooks[event], key: event, path: claudeURL)
                guard !entries.contains(where: containsDayglassHook) else { continue }
                entries.append(["hooks": [["type": "command", "command": "dayglass hook claude", "async": true]]])
                hooks[event] = entries
            }
            root["hooks"] = hooks
        }

        let codexURL = home.appendingPathComponent(".codex/hooks.json")
        try updateJSON(at: codexURL) { root in
            var features = try object(root["features"], key: "features", path: codexURL)
            features["hooks"] = true
            root["features"] = features
            var hooks = try object(root["hooks"], key: "hooks", path: codexURL)
            for event in hookEvents {
                var entries = try array(hooks[event], key: event, path: codexURL)
                guard !entries.contains(where: containsDayglassHook) else { continue }
                entries.append(["command": "dayglass hook codex", "async": true])
                hooks[event] = entries
            }
            root["hooks"] = hooks
        }
    }

    private func installTelemetry() throws {
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        try updateJSON(at: claudeURL) { root in
            var env = try object(root["env"], key: "env", path: claudeURL)
            env["CLAUDE_CODE_ENABLE_TELEMETRY"] = "1"
            env["OTEL_METRICS_EXPORTER"] = "otlp"
            env["OTEL_LOGS_EXPORTER"] = "otlp"
            env["OTEL_EXPORTER_OTLP_PROTOCOL"] = "http/json"
            env["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://127.0.0.1:4318"
            root["env"] = env
        }

        let codexURL = home.appendingPathComponent(".codex/config.toml")
        try fileManager.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = fileManager.fileExists(atPath: codexURL.path) ? try String(contentsOf: codexURL, encoding: .utf8) : ""
        guard existing.range(of: "(?m)^\\[otel\\]\\s*$", options: .regularExpression) == nil else { return }
        let block = """

        [otel]
        exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/logs", protocol = "json" } }
        metrics_exporter = "otlp-http"
        """
        try (existing + block).write(to: codexURL, atomically: true, encoding: .utf8)
    }

    private func createBaseFiles() throws {
        try fileManager.createDirectory(at: dataRoot.appendingPathComponent("otlp", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dataRoot.appendingPathComponent("state", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dataRoot.appendingPathComponent("run", isDirectory: true), withIntermediateDirectories: true)

        let sourceURL = dataRoot.appendingPathComponent("source.json")
        if !fileManager.fileExists(atPath: sourceURL.path) {
            let source: [String: Any] = [
                "schemaVersion": 1,
                "sourceId": UUID().uuidString.lowercased(),
                "platform": "macOS",
                "createdAt": ISO8601DateFormatter().string(from: Date()),
            ]
            try writeJSON(source, to: sourceURL)
        }

        let projectsURL = home.appendingPathComponent(".config/dayglass/projects.toml")
        if !fileManager.fileExists(atPath: projectsURL.path) {
            try fileManager.createDirectory(at: projectsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try """
            # Add one [[project]] block per repository.
            # [[project]]
            # code = "EXAMPLE"
            # name = "Example project"
            # git = ["*github.com/Gigooo-organization/example*"]
            """.write(to: projectsURL, atomically: true, encoding: .utf8)
        }
        try installSkill()
    }

    private func installSkill() throws {
        let skills = [
            (name: "dayglass-report", contents: dayglassReportSkill),
            (name: "dayglass-search", contents: dayglassSearchSkill),
        ]
        for skill in skills {
            for root in [home.appendingPathComponent(".claude/skills"), home.appendingPathComponent(".codex/skills")] {
                let location = root.appendingPathComponent("\(skill.name)/SKILL.md")
                try fileManager.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: location.path) {
                    try (skill.contents + "\n").write(to: location, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private func installLaunchAgents() throws {
        let binary = home.appendingPathComponent(".local/libexec/dayglass")
        let current = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        try fileManager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        if current.path != binary.path {
            if fileManager.fileExists(atPath: binary.path) { try fileManager.removeItem(at: binary) }
            try fileManager.copyItem(at: current, to: binary)
        }
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let logRoot = dataRoot.appendingPathComponent("state", isDirectory: true).path
        try launchdPlist(label: "com.gigooo.dayglass.daemon", arguments: ["daemon"], binary: binary.path, logRoot: logRoot)
            .write(to: launchAgents.appendingPathComponent("com.gigooo.dayglass.daemon.plist"), atomically: true, encoding: .utf8)
        try launchdPlist(label: "com.gigooo.dayglass.serve", arguments: ["serve"], binary: binary.path, logRoot: logRoot)
            .write(to: launchAgents.appendingPathComponent("com.gigooo.dayglass.serve.plist"), atomically: true, encoding: .utf8)
        try syncLaunchdPlist(binary: binary.path, logRoot: logRoot)
            .write(to: launchAgents.appendingPathComponent("com.gigooo.dayglass.sync.plist"), atomically: true, encoding: .utf8)
    }

    private func addTimeMachineExclusion() {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/tmutil") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["addexclusion", dataRoot.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private func printGHStatus() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "auth", "status"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else {
            print("gh auth status could not be checked; install GitHub CLI and run gh auth login.")
            return
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 { print("gh is not authenticated; run gh auth login before sync github.") }
    }

    private func printSigningInstructions() {
        print("Accessibility: grant access to ~/.local/libexec/dayglass in System Settings.")
        print("Updates replace that fixed path; re-approve Accessibility after a binary update unless you self-sign consistently.")
        print("Optional: create a Keychain Code Signing identity named dayglass-selfsigned and codesign --force --sign it ~/.local/libexec/dayglass.")
    }

    private func updateJSON(at url: URL, mutate: (inout [String: Any]) throws -> Void) throws {
        var root: [String: Any] = [:]
        if fileManager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data), let object = value as? [String: Any] else {
                throw SetupError.invalidJSON(url.path)
            }
            root = object
        }
        try mutate(&root)
        try writeJSON(root, to: url)
    }

    private func writeJSON(_ value: [String: Any], to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func object(_ value: Any?, key: String, path: URL) throws -> [String: Any] {
        guard value == nil || value is [String: Any] else { throw SetupError.invalidShape("\(path.path): \(key) must be an object") }
        return value as? [String: Any] ?? [:]
    }

    private func array(_ value: Any?, key: String, path: URL) throws -> [[String: Any]] {
        guard value == nil || value is [[String: Any]] else { throw SetupError.invalidShape("\(path.path): \(key) must be an array") }
        return value as? [[String: Any]] ?? []
    }

    private func containsDayglassHook(_ value: [String: Any]) -> Bool {
        if let command = value["command"] as? String { return command.contains("dayglass hook") }
        if let hooks = value["hooks"] as? [[String: Any]] { return hooks.contains { ($0["command"] as? String)?.contains("dayglass hook") == true } }
        return false
    }

    private func launchdPlist(label: String, arguments: [String], binary: String, logRoot: String) -> String {
        let values = ([binary] + arguments).map { "        <string>\(xmlEscape($0))</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
        \(values)
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardOutPath</key><string>\(xmlEscape(logRoot))/\(label).out.log</string>
            <key>StandardErrorPath</key><string>\(xmlEscape(logRoot))/\(label).err.log</string>
        </dict>
        </plist>
        """
    }

    private func syncLaunchdPlist(binary: String, logRoot: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.gigooo.dayglass.sync</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscape(binary))</string>
                <string>sync</string>
                <string>github</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>StartInterval</key><integer>86400</integer>
            <key>StandardOutPath</key><string>\(xmlEscape(logRoot))/com.gigooo.dayglass.sync.out.log</string>
            <key>StandardErrorPath</key><string>\(xmlEscape(logRoot))/com.gigooo.dayglass.sync.err.log</string>
        </dict>
        </plist>
        """
    }
}

private enum SetupError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case invalidShape(String)
    var description: String {
        switch self {
        case .invalidJSON(let path): return "invalid JSON: \(path)"
        case .invalidShape(let message): return message
        }
    }
}

private let hookEvents = ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"]

private let dayglassReportSkill = """
---
name: dayglass-report
description: Review and freeze a dayglass work report.
---

# dayglass-report

1. Run `dayglass report --month YYYY-MM --questions`.
2. Present questions in date order, one at a time, without adding candidates.
3. Record each answer immediately with `dayglass note --question`.
4. Ask once about meetings outside Zoom, Meet, or Teams and record explicit times.
5. Re-run the report and show the remaining unassigned seconds.
6. Run `dayglass evidence --day YYYY-MM-DD` for bounded, redacted request/outcome material.
7. Draft one to three lines per project; keep repository names and PR numbers unchanged.
8. Let the user review and correct the draft, then save it with `dayglass note --day --summary`.
9. Run `dayglass report --freeze --format csv` and ask the user to inspect and submit it manually.

Never invent candidates, treat a gap as a meeting, or send raw logs. Only the user's explicit answer may add a project or category.
"""

private let dayglassSearchSkill = """
---
name: dayglass-search
description: Search local dayglass work logs, AI usage, and GitHub output from natural-language questions without exposing raw logs or window titles.
---

# dayglass-search

Translate the user's question into the smallest relevant local dayglass query.

1. Resolve relative dates in the user's local timezone and state the searched date range. If no period is given, use the current month.
2. Run `dayglass report --month YYYY-MM --format json --no-titles` once for each calendar month in the range.
3. Use `time` for work duration, `ai` for sessions, turns, edits, and tokens, `output` for commits and pull requests, and `blocks` for time-of-day searches. Filter all results to the requested dates and projects.
4. When the user asks what happened in an AI conversation, run `dayglass evidence --day YYYY-MM-DD` only for the relevant day. Treat it as a bounded, redacted excerpt, not a complete transcript.
5. Answer with the matched period, totals, and whether each value is confirmed, inferred, or unassigned. Keep unknowns unknown and distinguish observed activity from human-confirmed work.

Never read files under `~/Library/Application Support/dayglass/otlp/` or raw Claude Code/Codex transcripts directly. Never expose window titles, question evidence, raw prompts or responses, tool arguments, or tool results. Do not run `note`, `freeze`, `reap`, `setup`, or other explicit mutation commands; the normal GitHub synchronization attempted by `report` is allowed. If the safe report and redacted evidence cannot answer the question, say what is unavailable instead of guessing.
"""

private func xmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}
