#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Bounds blocking reads and writes on an accepted connection. The servers handle one client at a time,
/// so without this a peer that connects and never sends would stall every later request.
@discardableResult
public func setSocketTimeout(_ fd: Int32, seconds: Int) -> Bool {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    let size = socklen_t(MemoryLayout<timeval>.size)
    return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0
        && setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0
}
