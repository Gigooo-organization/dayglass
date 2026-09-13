import Foundation

public enum OTLPFileSignal: String, CaseIterable, Codable, Sendable {
    case traces
    case logs
    case metrics
}

public final class DayFile: @unchecked Sendable {
    private let root: URL
    private var calendar: Calendar
    private let fileManager = FileManager.default

    public init(root: URL, calendar: Calendar = .current) {
        self.root = root
        self.calendar = calendar
    }

    public func fileURL(signal: OTLPFileSignal, at date: Date) -> URL {
        folderURL(for: date).appendingPathComponent("\(signal.rawValue).jsonl")
    }

    public func append(
        _ line: String,
        signal: OTLPFileSignal,
        at date: Date,
        newline: Bool = true
    ) throws {
        let folder = folderURL(for: date)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = fileURL(signal: signal, at: date)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let suffix = newline && !line.hasSuffix("\n") ? "\n" : ""
        try handle.write(contentsOf: Data((line + suffix).utf8))
    }

    /// Drops one incomplete trailing record. Complete lines are left byte-for-byte unchanged.
    @discardableResult
    public func repair(signal: OTLPFileSignal, day: Date) throws -> Int {
        let url = fileURL(signal: signal, at: day)
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let data = try Data(contentsOf: url)
        guard let lastNewline = data.lastIndex(of: 0x0A), lastNewline + 1 < data.endIndex else {
            return data.isEmpty ? 0 : 1
        }
        let complete = data[..<(lastNewline + 1)]
        try Data(complete).write(to: url, options: .atomic)
        return 1
    }

    private func folderURL(for date: Date) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let folder = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        return root.appendingPathComponent(folder, isDirectory: true)
    }
}
