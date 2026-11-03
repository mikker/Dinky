import Foundation
import Testing
@testable import DinkySocket

struct SocketIOTests {
    /// A connected pair of unix sockets, closed when the test ends.
    private final class Pair {
        let a: Int32
        let b: Int32

        init() throws {
            var fds: [Int32] = [0, 0]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            (a, b) = (fds[0], fds[1])
        }

        deinit {
            close(a)
            close(b)
        }
    }

    @Test func `A multi-line request larger than one read arrives whole`() throws {
        let pair = try Pair()
        let lines = (1...400).map { "echo line \($0) xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }
        let request = "exec-and-forget " + lines.joined(separator: "\n") + "\n"
        #expect(request.utf8.count > 16 * 1024)

        // The request is bigger than the socket buffer, so the writer must run beside the reader.
        let writer = Thread { [a = pair.a] in
            try! writeAll(a, request)
            shutdown(a, SHUT_WR)
        }
        writer.start()

        #expect(try readAll(pair.b) == request)
    }

    @Test func `A receive timeout rejects the accumulated command`() throws {
        let pair = try Pair()
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(pair.b, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        try writeAll(pair.a, "workspace 2\n")

        #expect(throws: SocketError.self) { try readAll(pair.b) }
    }

    @Test func `Writing to a disconnected peer throws without SIGPIPE`() throws {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]) }
        close(fds[1])
        #expect(throws: SocketError.self) { try writeAll(fds[0], "reply") }
    }
}
