import Foundation

public struct ObservationStore: Sendable {
    private let root: URL
    private var calendar: Calendar

    public init(root: URL, calendar: Calendar = .current) {
        self.root = root
        self.calendar = calendar
    }

    public func load(month: String) throws -> ReportInput {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return ReportInput() }
        var spans: [ObservedSpan] = []
        var logs: [ObservedLog] = []
        for folder in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = folder.lastPathComponent
            guard name.hasPrefix(month), (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let day = dayStart(from: name) ?? Date.distantPast
            for signal in [OTLPFileSignal.traces, .logs] {
                let url = folder.appendingPathComponent("\(signal.rawValue).jsonl")
                guard fileManager.fileExists(atPath: url.path) else { continue }
                let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(whereSeparator: \.isNewline)
                for line in lines {
                    let data = Data(line.utf8)
                    if signal == .traces {
                        spans.append(contentsOf: (try? OTLPJSONL.observedSpans(from: data)) ?? [])
                    } else {
                        logs.append(contentsOf: (try? OTLPJSONL.observedLogs(from: data)) ?? [])
                    }
                }
            }
            _ = day
        }
        return ReportInput(spans: spans.sorted { $0.start < $1.start }, logs: logs.sorted { $0.timestamp < $1.timestamp })
    }

    private func dayStart(from value: String) -> Date? {
        let fields = value.split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2]))
    }
}
