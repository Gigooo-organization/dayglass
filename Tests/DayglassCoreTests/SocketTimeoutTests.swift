#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import DayglassCore

@Suite struct SocketTimeoutTests {
    @Test func readFromSilentPeerGivesUpAfterTimeout() throws {
        var pair: [Int32] = [0, 0]
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        #expect(socketpair(AF_UNIX, streamType, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }

        #expect(setSocketTimeout(pair[0], seconds: 1))
        var buffer = [UInt8](repeating: 0, count: 16)
        let started = Date()
        let count = read(pair[0], &buffer, buffer.count)

        #expect(count == -1)
        #expect(errno == EAGAIN || errno == EWOULDBLOCK)
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
