import Foundation

public struct RepeatFilter: Sendable {
    private var previous: String?

    public init() {}

    public mutating func admits(_ signature: String) -> Bool {
        guard signature != previous else { return false }
        previous = signature
        return true
    }
}

public struct ChurnPolicy: Sendable {
    public let animationScalars: [ClosedRange<UInt32>]

    public init(animationScalars: [ClosedRange<UInt32>]) {
        self.animationScalars = animationScalars
    }

    public static let `default` = ChurnPolicy(
        animationScalars: [0x2800...0x28FF, 0x2580...0x259F]
    )

    public func stem(of title: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in title.unicodeScalars where !animationScalars.contains(where: { $0.contains(scalar.value) }) {
            kept.append(scalar)
        }
        return String(kept).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public struct ChurnFilter: Sendable {
    public enum Decision: Equatable, Sendable {
        case record
        case animating
    }

    private let policy: ChurnPolicy
    private var previous: String?

    public init(policy: ChurnPolicy = .default) {
        self.policy = policy
    }

    public mutating func decide(scope: String, title: String) -> Decision {
        let key = scope + "\u{1}" + policy.stem(of: title)
        defer { previous = key }
        return key == previous ? .animating : .record
    }
}
