import Foundation

/// Runs a child process through `/usr/bin/env` and captures what it writes.
///
/// Lives here rather than in the CLI shell because the capture rules are the
/// part worth testing: a child that outgrows the pipe buffer must still finish.
public enum CommandRunner {
    public enum Failure: Error, CustomStringConvertible {
        case status(String)

        public var description: String {
            if case .status(let value) = self { return value }
            return "command failed"
        }
    }

    public static func data(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()

        // Drain both pipes while the child still runs. Waiting for exit first
        // deadlocks the moment either stream fills the 64 KiB pipe buffer: the
        // child blocks on write, the parent blocks on wait, neither gives way.
        let captured = Capture()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            captured.error = error.fileHandleForReading.readDataToEndOfFile()
        }
        captured.output = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: captured.error, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.status(message.isEmpty ? "command failed" : message)
        }
        return captured.output
    }
}

/// Hand-off box for the background reader. `group.wait()` orders the writes
/// before the reads, which the compiler cannot see on its own.
private final class Capture: @unchecked Sendable {
    var output = Data()
    var error = Data()
}
