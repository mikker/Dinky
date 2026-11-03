import Foundation

enum SocketError: Error, CustomStringConvertible {
    case timedOut, tooLarge, invalidUTF8, system(Int32)

    var description: String {
        switch self {
        case .timedOut: return "socket receive timed out; close the writing half to finish the request"
        case .tooLarge: return "socket message exceeds 1 MiB"
        case .invalidUTF8: return "socket message is not valid UTF-8"
        case .system(let code): return "socket: \(String(cString: strerror(code)))"
        }
    }
}

// EOF, not newline or an idle timeout, completes a message. Decode only after collecting all
// bytes: a read can split a UTF-8 character, and a command can contain any number of newlines.
func readAll(_ fd: Int32) throws -> String {
    let limit = 1 << 20
    var data = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var timeout = timeval()
    var size = socklen_t(MemoryLayout<timeval>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, &size) == 0 else {
        throw SocketError.system(errno)
    }
    let idle = Double(timeout.tv_sec) + Double(timeout.tv_usec) / 1_000_000
    var deadline = ProcessInfo.processInfo.systemUptime + idle
    while true {
        // Darwin's timed blocking receives can miss a racing half-close, then time out with EOF
        // already readable. Wait for readiness instead; never mistake an idle timeout for EOF.
        let n = recv(fd, &buffer, min(buffer.count, limit - data.count + 1), MSG_DONTWAIT)
        if n == 0 { break }
        if n < 0 {
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw SocketError.system(errno) }
            let milliseconds = idle > 0
                ? Int32(min(Double(Int32.max), max(0, ceil((deadline - ProcessInfo.processInfo.systemUptime) * 1000))))
                : -1 // The CLI's unconfigured socket waits indefinitely for a slow command's reply.
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw SocketError.system(errno) }
            guard ready > 0 else { throw SocketError.timedOut }
            continue
        }
        data += buffer[..<n]
        guard data.count <= limit else { throw SocketError.tooLarge }
        deadline = ProcessInfo.processInfo.systemUptime + idle
    }
    guard let string = String(bytes: data, encoding: .utf8) else { throw SocketError.invalidUTF8 }
    return string
}

func writeAll(_ fd: Int32, _ string: String) throws {
    var bytes = Array(string.utf8)[...]
    while !bytes.isEmpty {
        // Suppress SIGPIPE on each send, even if the peer disconnected before accept/configure.
        let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { throw SocketError.system(errno) }
        bytes = bytes.dropFirst(n)
    }
}

func configureSocket(_ fd: Int32, receiveTimeout: Int) {
    var receive = timeval(tv_sec: receiveTimeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive, socklen_t(MemoryLayout<timeval>.size))
    var send = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size))
}
