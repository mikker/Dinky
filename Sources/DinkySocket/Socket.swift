import Foundation

public struct Reply {
    public var ok: Bool
    public var text: String

    public static func ok(_ text: String) -> Reply { Reply(ok: true, text: text) }
    public static func error(_ text: String) -> Reply { Reply(ok: false, text: text) }
}

/// One UTF-8 request per connection, terminated by EOF (shutdown(SHUT_WR) on the client).
/// Replies start with "ok\n" or "error\n" and end when the server closes the connection.
public final class SocketServer {
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "dinky.socket")

    /// `handle` runs on the main queue. Replaces a stale socket at the supplied path.
    public init?(path: String, handle: @escaping (String) -> Reply) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, withAddress(path, { Darwin.bind(fd, $0, $1) }) == 0, listen(fd, 8) == 0 else {
            fputs("socket: can't listen on \(path): \(String(cString: strerror(errno)))\n", stderr)
            if fd >= 0 { close(fd) }
            return nil
        }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            configureSocket(client, receiveTimeout: 2)
            let reply: Reply
            do {
                let line = try readAll(client).trimmingCharacters(in: .whitespacesAndNewlines)
                // Empty connections include appIsRunning probes, not commands.
                guard !line.isEmpty else { return }
                reply = DispatchQueue.main.sync { handle(line) }
            } catch {
                reply = .error(String(describing: error))
            }
            try? writeAll(client, (reply.ok ? "ok\n" : "error\n") + reply.text)
        }
        source.setCancelHandler {
            close(fd)
            unlink(path)
        }
        source.resume()
    }

    public func stop() { source.cancel() }
}

public func appIsRunning(path: String) -> Bool {
    guard let fd = connectSocket(path) else { return false }
    close(fd)
    return true
}

/// Nil if nothing is listening. A connected transport failure is an error reply, never a partial reply.
public func sendToApp(_ line: String, path: String) -> Reply? {
    guard let fd = connectSocket(path) else { return nil }
    defer { close(fd) }
    // Commands run on the app's main queue and may legitimately take longer than the request's
    // two-second receive timeout. Preserve the CLI's wait for writes and their complete reply.
    do {
        try writeAll(fd, line + "\n")
        guard shutdown(fd, SHUT_WR) == 0 else { throw SocketError.system(errno) }
        let response = try readAll(fd)
        guard let newline = response.firstIndex(of: "\n") else { return .error("no reply from the app") }
        return Reply(ok: response[..<newline] == "ok", text: String(response[response.index(after: newline)...]))
    } catch {
        return .error(String(describing: error))
    }
}

func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    guard withAddress(path, { connect(fd, $0, $1) }) == 0 else {
        close(fd)
        return nil
    }
    return fd
}

private func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path), !bytes.contains(0) else {
        errno = ENAMETOOLONG
        return -1
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}
