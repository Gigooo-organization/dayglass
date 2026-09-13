import Foundation

public struct PauseWindow: Codable, Equatable, Sendable {
    public let until: Date

    public init(until: Date) { self.until = until }
}

public final class PauseStore: @unchecked Sendable {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func pause(for duration: TimeInterval, from now: Date = Date()) throws -> PauseWindow {
        let window = PauseWindow(until: now.addingTimeInterval(duration))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(window).write(to: url, options: .atomic)
        return window
    }

    public func current(at now: Date = Date()) throws -> PauseWindow? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let window = try decoder.decode(PauseWindow.self, from: Data(contentsOf: url))
        if window.until <= now {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return window
    }

    public static func parseDuration(_ value: String) -> TimeInterval? {
        guard let unit = value.last, let amount = Double(value.dropLast()), amount > 0 else { return nil }
        switch unit {
        case "m": return amount * 60
        case "h": return amount * 3_600
        case "d": return amount * 86_400
        default: return nil
        }
    }
}
