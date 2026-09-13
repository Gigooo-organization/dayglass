import AppKit
import ApplicationServices
import Darwin
import DayglassCore
import Foundation

enum DaemonError: Error, CustomStringConvertible {
    case accessibilityPermission
    case socket(String)

    var description: String {
        switch self {
        case .accessibilityPermission:
            return "Accessibility permission required. Grant it in System Settings > Privacy & Security > Accessibility."
        case .socket(let message): return "daemon socket: \(message)"
        }
    }
}

final class DayglassDaemon: @unchecked Sendable {
    private let dataRoot: URL
    private let dayFile: DayFile
    private let pauseStore: PauseStore
    private let socketServer: LocalSinkServer
    private let windowMonitor: WindowMonitor

    init(dataRoot: URL) {
        self.dataRoot = dataRoot
        self.dayFile = DayFile(root: dataRoot.appendingPathComponent("otlp", isDirectory: true))
        self.pauseStore = PauseStore(url: dataRoot.appendingPathComponent("state/pause.json"))
        self.socketServer = LocalSinkServer(
            path: dataRoot.appendingPathComponent("run/dayglass.sock").path,
            dayFile: dayFile
        )
        self.windowMonitor = WindowMonitor()
    }

    func run() throws {
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            throw DaemonError.accessibilityPermission
        }
        try socketServer.start()
        let started = Date()
        try writeLog("session.started", at: started)
        var runSpan = ObservedSpan(name: "dayglass.run", start: started, end: started)
        var tracker = FocusTracker()
        var afkStart: Date?
        var afkReason = "idle"
        var stopped = false
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler { stopped = true }
        signalSource.resume()
        signal(SIGINT, SIG_IGN)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { stopped = true }
        termSource.resume()
        signal(SIGTERM, SIG_IGN)

        while !stopped {
            let now = Date()
            let paused = (try? pauseStore.current(at: now)) != nil
            if paused {
                if afkStart == nil {
                    try tracker.afkStarted(at: now).forEach(write)
                    afkStart = now
                    afkReason = "paused"
                }
            } else if let idle = windowMonitor.idleSeconds(), idle >= 300 {
                if afkStart == nil {
                    try tracker.afkStarted(at: now).forEach(write)
                    afkStart = max(started, now.addingTimeInterval(-idle))
                    afkReason = "idle"
                }
            } else if let activeAfkStart = afkStart {
                if now > activeAfkStart {
                    try write(ObservedSpan(name: "afk", start: activeAfkStart, end: now, attributes: ["dayglass.afk.reason": afkReason]))
                }
                afkStart = nil
                if let snapshot = windowMonitor.snapshot() {
                    try tracker.update(snapshot, at: now).forEach(write)
                }
            } else if let snapshot = windowMonitor.snapshot() {
                try tracker.update(snapshot, at: now).forEach(write)
            }
            runSpan = ObservedSpan(name: "dayglass.run", start: started, end: now)
            RunLoop.current.run(until: Date().addingTimeInterval(5))
        }

        let ended = Date()
        if let afkStart, ended > afkStart {
            try write(ObservedSpan(name: "afk", start: afkStart, end: ended, attributes: ["dayglass.afk.reason": afkReason]))
        }
        try tracker.close(at: ended).forEach(write)
        runSpan = ObservedSpan(name: "dayglass.run", start: runSpan.start, end: ended)
        try write(runSpan)
        try writeLog("session.ended", at: ended)
        socketServer.stop()
        signalSource.cancel()
        termSource.cancel()
    }

    private func write(_ span: ObservedSpan) throws {
        let attributes = span.attributes.map { OTLPAttribute(key: $0.key, value: .string($0.value)) }.sorted { $0.key < $1.key }
        let value = OTLPSpan(
            name: span.name,
            startTimeUnixNano: String(Int64(span.start.timeIntervalSince1970 * 1_000_000_000)),
            endTimeUnixNano: String(Int64(span.end.timeIntervalSince1970 * 1_000_000_000)),
            attributes: attributes
        )
        try dayFile.append(try OTLPJSONL.traceLine(span: value), signal: .traces, at: span.start)
    }

    private func writeLog(_ name: String, at date: Date) throws {
        try dayFile.append(try OTLPJSONL.logLine(eventName: name, at: date), signal: .logs, at: date)
    }
}

final class WindowMonitor: @unchecked Sendable {
    private var churn = ChurnFilter()
    private let excluded: Set<String>

    init() {
        var excluded: Set<String> = [
            "com.apple.keychainaccess",
            "com.1password.1password",
            "com.agilebits.onepassword7",
        ]
        if let extra = ProcessInfo.processInfo.environment["DAYGLASS_EXCLUDE_BUNDLES"] {
            excluded.formUnion(extra.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        self.excluded = excluded
    }

    func snapshot() -> FocusSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleID = application.bundleIdentifier,
              !excluded.contains(bundleID) else { return nil }
        let axApplication = AXUIElementCreateApplication(application.processIdentifier)
        let window = element(axApplication, attribute: kAXFocusedWindowAttribute) ?? element(axApplication, attribute: kAXMainWindowAttribute)
        let rawTitle = window.flatMap { string($0, attribute: kAXTitleAttribute) } ?? application.localizedName ?? ""
        let title = ChurnPolicy.default.stem(of: rawTitle)
        let appName = application.localizedName ?? bundleID
        if isPrivateWindow(title: rawTitle, bundleID: bundleID) { return nil }
        let url = window.flatMap { documentURL($0, bundleID: bundleID) }
        return FocusSnapshot(
            appBundleID: bundleID,
            appName: appName,
            title: title,
            urlDomain: url?.host,
            urlPath: allowedPath(url)
        )
    }

    func idleSeconds() -> TimeInterval? {
        let keyboard = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let mouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let values = [keyboard, mouse].filter { $0.isFinite && $0 >= 0 }
        return values.min()
    }

    private func documentURL(_ window: AXUIElement, bundleID: String) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private func isPrivateWindow(title: String, bundleID: String) -> Bool {
        let browser = ["safari", "chrome", "edge", "firefox", "brave", "arc"].contains { bundleID.localizedCaseInsensitiveContains($0) }
        return browser && ["private browsing", "inprivate", "incognito"].contains { title.localizedCaseInsensitiveContains($0) }
    }

    private func allowedPath(_ url: URL?) -> String? {
        guard let url, let host = url.host?.lowercased() else { return nil }
        let allowed = host == "github.com" || host == "gitlab.com" || host == "docs.google.com" || host == "notion.so" || host.hasSuffix(".atlassian.net") || host == "meet.google.com" || host == "teams.microsoft.com" || host.hasSuffix(".zoom.us")
        return allowed ? url.path : nil
    }
}

private func element(_ element: AXUIElement, attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func string(_ element: AXUIElement, attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}

final class LocalSinkServer: @unchecked Sendable {
    private let path: String
    private let dayFile: DayFile
    private var serverFD: Int32 = -1
    private let queue = DispatchQueue(label: "dayglass.socket")

    init(path: String, dayFile: DayFile) {
        self.path = path
        self.dayFile = dayFile
    }

    func start() throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.socket(String(cString: strerror(errno))) }
        serverFD = fd
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw DaemonError.socket("path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            serverFD = -1
            throw DaemonError.socket(message)
        }
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        let fd = serverFD
        serverFD = -1
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(path)
    }

    private func acceptLoop() {
        while serverFD >= 0 {
            let client = accept(serverFD, nil, nil)
            guard client >= 0 else { continue }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            close(client)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let signalName = object["signal"] as? String,
                  let signal = OTLPFileSignal(rawValue: signalName),
                  let timestamp = object["date"] as? NSNumber,
                  let line = object["line"] as? String else { continue }
            try? dayFile.append(line, signal: signal, at: Date(timeIntervalSince1970: timestamp.doubleValue))
        }
    }
}
