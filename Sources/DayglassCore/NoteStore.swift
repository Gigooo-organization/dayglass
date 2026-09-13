import Foundation

public final class NoteStore: @unchecked Sendable {
    private let root: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL) {
        self.root = root
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func fileURL(month: String) -> URL {
        root.appendingPathComponent("notes", isDirectory: true).appendingPathComponent("\(month).jsonl")
    }

    public func append(_ note: NoteRecord, month: String) throws {
        let directory = fileURL(month: month).deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL(month: month).path) {
            fileManager.createFile(atPath: fileURL(month: month).path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL(month: month))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encoder.encode(note) + Data([0x0A]))
    }

    public func load(month: String) throws -> [NoteRecord] {
        let url = fileURL(month: month)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(whereSeparator: \.isNewline)
        return try lines.map { try decoder.decode(NoteRecord.self, from: Data($0.utf8)) }
    }
}
