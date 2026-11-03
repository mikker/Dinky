import Foundation
import Testing
@testable import DinkySocket

struct SocketIntegrationTests {
    // Every listener has an explicitly injected private path, never the app's default path.
    private final class Server {
        let directory = "/tmp/dinky-socket-\(UUID().uuidString)"
        var path: String { directory + "/s" }
        let server: SocketServer

        init(handle: @escaping (String) -> Reply) throws {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            server = try #require(SocketServer(path: directory + "/s", handle: handle))
        }

        deinit {
            server.stop()
            // The cancel handler closes and unlinks asynchronously; removing the directory is safe
            // because every test owns a unique one and never reuses the socket path.
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    private let script = "exec-and-forget " + (1...400).map { "echo \($0) café 🐈 日本語" }.joined(separator: "\n")

    @Test func `Real client half-closes and receives a complete multiline reply`() async throws {
        let request = script
        #expect(request.utf8.count > 4096)
        let server = try Server { line in
            #expect(Thread.isMainThread)
            #expect(line == request)
            return .ok(line)
        }
        let reply = await Task.detached { sendToApp(request, path: server.path) }.value
        #expect(reply?.ok == true)
        #expect(reply?.text == request)
    }

    @Test func `Fragmented multiline UTF8 is not dispatched before half-close`() async throws {
        let request = script
        let server = try Server { line in
            #expect(line == request)
            return .ok(line)
        }
        try await Task.detached {
            let fd = try #require(connectSocket(server.path))
            defer { close(fd) }
            configureSocket(fd, receiveTimeout: 5)
            // Deliberately split every multibyte scalar, with a pause after an early newline.
            let bytes = Array(request.utf8)
            let splitScalar = try #require(bytes.firstIndex(of: 0xf0))
            for (index, byte) in bytes.enumerated() {
                var byte = byte
                try #require(send(fd, &byte, 1, MSG_NOSIGNAL) == 1)
                if index == splitScalar || index == 80 { usleep(100_000) }
            }
            // No reply (and hence no execution) may precede EOF, even after all bytes arrive.
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            #expect(poll(&descriptor, 1, 100) == 0)
            try #require(shutdown(fd, SHUT_WR) == 0)
            #expect(try readAll(fd) == "ok\n" + request)
        }.value
    }

    @Test(arguments: [false, true])
    func `Timeout rejects partial requests and the listener remains usable`(atLimit: Bool) async throws {
        let server = try Server { line in
            #expect(line == "next")
            return .ok(line)
        }
        try await Task.detached {
            let fd = try #require(connectSocket(server.path))
            defer { close(fd) }
            // Allow the server's two-second timeout to send its error before our read times out.
            configureSocket(fd, receiveTimeout: 5)
            let request = atLimit ? String(repeating: "x", count: 1 << 20) : "exec-and-forget echo partial\n"
            try writeAll(fd, request)
            let reply = try readAll(fd)
            #expect(reply.hasPrefix("error\n"))
            #expect(reply.contains("timed out"))
            #expect(sendToApp("next", path: server.path)?.text == "next")
        }.value
    }

    @Test(arguments: [(1 << 20) - 1, 1 << 20, (1 << 20) + 1])
    func `Size boundary never dispatches an oversized prefix`(size: Int) async throws {
        let request = String(repeating: "x", count: size)
        let server = try Server { line in
            #expect(size <= 1 << 20)
            #expect(line == request)
            return .ok("complete")
        }
        try await Task.detached {
            let fd = try #require(connectSocket(server.path))
            defer { close(fd) }
            configureSocket(fd, receiveTimeout: 5)
            try writeAll(fd, request)
            shutdown(fd, SHUT_WR)
            let reply = try readAll(fd)
            #expect(reply == (size <= 1 << 20 ? "ok\ncomplete" : "error\nsocket message exceeds 1 MiB"))
        }.value
    }

    @Test func `Invalid UTF8 is rejected instead of executing replacement characters`() async throws {
        let server = try Server { _ in
            Issue.record("Invalid UTF-8 reached the command handler")
            return .ok("")
        }
        try await Task.detached {
            let fd = try #require(connectSocket(server.path))
            defer { close(fd) }
            configureSocket(fd, receiveTimeout: 5)
            var bytes: [UInt8] = [0x65, 0x63, 0x68, 0x6f, 0x20, 0xf0, 0x9f]
            try #require(send(fd, &bytes, bytes.count, MSG_NOSIGNAL) == bytes.count)
            shutdown(fd, SHUT_WR)
            #expect(try readAll(fd) == "error\nsocket message is not valid UTF-8")
        }.value
    }

    @Test func `Empty probes do not execute and disconnected peers cannot kill the listener`() async throws {
        let server = try Server { line in
            #expect(line == "next" || line == "disconnected")
            return .ok(line)
        }
        try await Task.detached {
            #expect(appIsRunning(path: server.path))
            let fd = try #require(connectSocket(server.path))
            configureSocket(fd, receiveTimeout: 5)
            try writeAll(fd, "disconnected\n")
            close(fd)
            #expect(sendToApp("next", path: server.path)?.text == "next")
        }.value
    }

    @Test func `macOS nc closes stdin and receives the reply without waiting for timeout`() async throws {
        let request = script
        let server = try Server { line in
            #expect(line == request)
            return .ok("complete")
        }
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            process.arguments = ["-U", server.path]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
            try input.fileHandleForWriting.close()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while process.isRunning && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let timedOut = process.isRunning
            if timedOut { process.terminate() }
            #expect(!timedOut)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "ok\ncomplete")
        }.value
    }
}
