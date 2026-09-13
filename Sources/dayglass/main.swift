import DayglassCore
import Darwin
import Foundation

enum DayglassCLIError: Error, CustomStringConvertible {
    case usage(String)
    case message(String)

    var description: String {
        switch self {
        case .usage(let text), .message(let text): return text
        }
    }
}

struct CLIOptions {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []

    init(_ arguments: ArraySlice<String>) throws {
        let arguments = Array(arguments)
        let flagKeys: Set<String> = ["questions", "no-titles", "freeze", "skip"]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                positionals.append(argument)
                index += 1
                continue
            }
            let keyValue = argument.dropFirst(2)
            if let equals = keyValue.firstIndex(of: "=") {
                values[String(keyValue[..<equals])] = String(keyValue[keyValue.index(after: equals)...])
            } else if !flagKeys.contains(String(keyValue)), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                let next = arguments[index + 1]
                values[String(keyValue)] = next
                index += 1
            } else {
                flags.insert(String(keyValue))
            }
            index += 1
        }
    }

    func value(_ key: String) -> String? { values[key] }
    func required(_ key: String) throws -> String { try value(key) ?? { throw DayglassCLIError.usage("missing --\(key)") }() }
    func has(_ key: String) -> Bool { flags.contains(key) }
}

let dataRootEnvironment = ProcessInfo.processInfo.environment["DAYGLASS_DATA_ROOT"]
let defaultDataRoot: URL = {
    if let dataRootEnvironment, !dataRootEnvironment.isEmpty {
        return URL(fileURLWithPath: dataRootEnvironment, isDirectory: true)
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent("dayglass", isDirectory: true)
}()

func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        print(helpText)
        return
    }
    if command == "--version" || command == "version" {
        print(DayglassCore.version)
        return
    }
    let options = try CLIOptions(arguments.dropFirst())
    switch command {
    case "report": try report(options)
    case "note": try note(options)
    case "reap": try reap(options)
    case "hook": try hook(options)
    case "pause": try pause(options)
    case "daemon": try DayglassDaemon(dataRoot: defaultDataRoot).run()
    case "serve": try TelemetryServer(dataRoot: defaultDataRoot).run()
    default: throw DayglassCLIError.usage("unknown command: \(command)\n\n\(helpText)")
    }
}

func report(_ options: CLIOptions) throws {
    let month = options.value("month") ?? monthString(Date())
    let result = try loadResult(month: month)
    if options.has("questions") {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result.questions), as: UTF8.self))
    } else {
        let format = options.value("format").flatMap { ReportFormat(rawValue: $0) } ?? .json
        let table = options.value("table").flatMap { ReportTable(rawValue: $0) } ?? .time
        print(try ReportRenderer.render(result, format: format, table: table, noTitles: options.has("no-titles")), terminator: "")
    }
    if options.has("freeze") {
        let path = try freeze(result: result, month: month)
        print("\nFrozen report: \(path.path)")
    }
}

func note(_ options: CLIOptions) throws {
    let store = NoteStore(root: defaultDataRoot)
    if let questionID = options.value("question") {
        let month = options.value("month") ?? monthString(Date())
        let question = try loadResult(month: month).questions.first { $0.id == questionID }
        guard let question else { throw DayglassCLIError.message("question not found: \(questionID)") }
        let skip = options.has("skip")
        guard skip || (options.value("project") != nil && options.value("category") != nil) else {
            throw DayglassCLIError.usage("--question requires --project and --category, or --skip")
        }
        try store.append(
            NoteRecord(
                start: question.start,
                end: question.end,
                project: options.value("project"),
                category: options.value("category"),
                skip: skip
            ),
            month: monthString(question.start)
        )
        print("Recorded \(questionID)")
        return
    }
    if let summary = options.value("summary") {
        let day = try parseDay(options.value("day") ?? monthString(Date()) + "-01")
        try store.append(NoteRecord(summary: summary), month: monthString(day))
        print("Recorded summary for \(dayString(day))")
        return
    }
    guard let dayValue = options.value("day"), let from = options.value("from"), let to = options.value("to") else {
        throw DayglassCLIError.usage("note requires --question, --day --summary, or --day --from --to")
    }
    let day = try parseDay(dayValue)
    let start = try parseClock(from, on: day)
    let end = try parseClock(to, on: day)
    guard end > start else { throw DayglassCLIError.message("--to must be after --from") }
    try store.append(
        NoteRecord(start: start, end: end, project: options.value("project"), category: options.value("category"), skip: options.has("skip")),
        month: monthString(day)
    )
    print("Recorded \(dayString(day)) \(from)-\(to)")
}

func reap(_ options: CLIOptions) throws {
    let days = Int(options.value("days") ?? "90") ?? 90
    let root = defaultDataRoot.appendingPathComponent("otlp", isDirectory: true)
    let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
    let fm = FileManager.default
    var removed = 0
    if fm.fileExists(atPath: root.path) {
        for folder in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let day = try? parseDay(folder.lastPathComponent), day < cutoff else { continue }
            try fm.removeItem(at: folder)
            removed += 1
        }
    }
    print("Removed \(removed) day(s)")
}

func hook(_ options: CLIOptions) throws {
    guard let toolName = options.positionals.first, let tool = HookTool(rawValue: toolName) else {
        throw DayglassCLIError.usage("hook requires claude or codex")
    }
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    let event = try HookDecoder.decode(tool: tool, data: payload)
    try HookRecorder(dataRoot: defaultDataRoot).record(event)
}

func pause(_ options: CLIOptions) throws {
    let value = options.positionals.first ?? options.value("for")
    guard let value, let duration = PauseStore.parseDuration(value) else {
        throw DayglassCLIError.usage("pause requires a duration such as 15m, 2h, or 1d")
    }
    let window = try PauseStore(url: defaultDataRoot.appendingPathComponent("state/pause.json")).pause(for: duration)
    print("Paused until \(ISO8601DateFormatter().string(from: window.until))")
}

func loadResult(month: String) throws -> ReportResult {
    let input = try ObservationStore(root: defaultDataRoot.appendingPathComponent("otlp", isDirectory: true)).load(month: month)
    let configurationURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/dayglass/projects.toml")
    let configuration = FileManager.default.fileExists(atPath: configurationURL.path)
        ? try ReportConfiguration.loadTOML(from: configurationURL)
        : ReportConfiguration()
    let notes = try NoteStore(root: defaultDataRoot).load(month: month)
    return ReportEngine(input: input, configuration: configuration, notes: notes).build()
}

func freeze(result: ReportResult, month: String) throws -> URL {
    let directory = defaultDataRoot.appendingPathComponent("submissions/\(month)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try write(try ReportRenderer.render(result, format: .json), to: directory.appendingPathComponent("report.json"))
    try write(try ReportRenderer.render(result, format: .csv, table: .time), to: directory.appendingPathComponent("time.csv"))
    try write(try ReportRenderer.render(result, format: .csv, table: .ai), to: directory.appendingPathComponent("ai.csv"))
    try write(try ReportRenderer.render(result, format: .csv, table: .output), to: directory.appendingPathComponent("output.csv"))
    try write(DayglassCore.version + "\n", to: directory.appendingPathComponent("version.txt"))
    let notes = NoteStore(root: defaultDataRoot).fileURL(month: month)
    if FileManager.default.fileExists(atPath: notes.path) {
        try FileManager.default.copyItem(at: notes, to: directory.appendingPathComponent("notes.jsonl"))
    }
    let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/dayglass/projects.toml")
    if FileManager.default.fileExists(atPath: config.path) {
        try FileManager.default.copyItem(at: config, to: directory.appendingPathComponent("projects.toml"))
    }
    return directory
}

func write(_ value: String, to url: URL) throws {
    try value.write(to: url, atomically: true, encoding: .utf8)
}

func monthString(_ date: Date) -> String {
    let components = DayglassCalendar.local.dateComponents([.year, .month], from: date)
    return String(format: "%04d-%02d", components.year!, components.month!)
}

func dayString(_ date: Date) -> String {
    let components = DayglassCalendar.local.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
}

func parseDay(_ value: String) throws -> Date {
    let formatter = DateFormatter()
    formatter.calendar = DayglassCalendar.local
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: value) else { throw DayglassCLIError.message("invalid day: \(value)") }
    return date
}

func parseClock(_ value: String, on day: Date) throws -> Date {
    let fields = value.split(separator: ":").compactMap { Int($0) }
    guard fields.count == 2, fields[0] >= 0, fields[0] < 24, fields[1] >= 0, fields[1] < 60 else {
        throw DayglassCLIError.message("invalid time: \(value)")
    }
    return DayglassCalendar.local.date(bySettingHour: fields[0], minute: fields[1], second: 0, of: day)!
}

let helpText = """
dayglass \(DayglassCore.version)

Commands:
  report --month YYYY-MM --format csv|json|md|otlp-metrics [--questions] [--freeze]
  note --question ID --project CODE --category CATEGORY | --skip
  note --day YYYY-MM-DD --from HH:MM --to HH:MM --project CODE --category CATEGORY
  note --day YYYY-MM-DD --summary TEXT
  hook claude|codex < hook-payload.json
  pause 1h
  daemon
  serve
  reap [--days N]
"""

do {
    try run()
} catch {
    fputs("dayglass: \(error)\n", stderr)
    exit(1)
}
