import Foundation
import Testing
@testable import DayglassCore

// macOS pipe buffers hold 64 KiB. `gh api --paginate` over a busy account
// returns several hundred KB, so a runner that waits for exit before draining
// its pipes stops forever: the child blocks writing, the parent blocks waiting.
private let pipeBufferOverflow = 200_000

@Test(.timeLimit(.minutes(1)))
func capturesStandardOutputLargerThanThePipeBuffer() throws {
    let data = try CommandRunner.data(["sh", "-c", "yes dayglass | head -c \(pipeBufferOverflow)"])

    #expect(data.count == pipeBufferOverflow)
}

@Test(.timeLimit(.minutes(1)))
func reportsFailureWhenStandardErrorOutgrowsThePipeBuffer() throws {
    #expect(throws: CommandRunner.Failure.self) {
        try CommandRunner.data(["sh", "-c", "yes dayglass | head -c \(pipeBufferOverflow) >&2; exit 1"])
    }
}
