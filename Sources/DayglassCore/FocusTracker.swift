import Foundation

public struct FocusSnapshot: Equatable, Sendable {
    public let appBundleID: String
    public let appName: String
    public let title: String
    public let urlDomain: String?
    public let urlPath: String?

    public init(
        appBundleID: String,
        appName: String,
        title: String,
        urlDomain: String? = nil,
        urlPath: String? = nil
    ) {
        self.appBundleID = appBundleID
        self.appName = appName
        self.title = title
        self.urlDomain = urlDomain
        self.urlPath = urlPath
    }

    var attributes: [String: String] {
        var values = [
            "app.bundle_id": appBundleID,
            "app.name": appName,
            "window.title": title,
        ]
        if let urlDomain { values["url.domain"] = urlDomain }
        if let urlPath { values["url.path"] = urlPath }
        return values
    }
}

public struct FocusTracker: Sendable {
    private var current: (snapshot: FocusSnapshot, start: Date)?

    public init() {}

    public mutating func update(_ snapshot: FocusSnapshot, at date: Date) -> [ObservedSpan] {
        guard let current else {
            self.current = (snapshot, date)
            return []
        }
        guard current.snapshot != snapshot else { return [] }
        self.current = (snapshot, date)
        guard date > current.start else { return [] }
        return [ObservedSpan(name: "focus", start: current.start, end: date, attributes: current.snapshot.attributes)]
    }

    public mutating func afkStarted(at date: Date) -> [ObservedSpan] {
        guard let current, date > current.start else { return [] }
        self.current = nil
        return [ObservedSpan(name: "focus", start: current.start, end: date, attributes: current.snapshot.attributes)]
    }

    public mutating func close(at date: Date) -> [ObservedSpan] {
        afkStarted(at: date)
    }
}
