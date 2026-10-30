import Foundation

// Byte transport for the CLI socket. Each side writes its whole message and then closes its writing
// half, so a reader takes everything up to end of file. A request may hold newlines (a multi-line
// exec-and-forget script), so a newline never ends one.

/// Reads until the peer closes its side, the socket's receive timeout expires, or 1 MiB has arrived.
public func readAll(_ fd: Int32) -> String {
    var data = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count < 1 << 20 {
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { break }
        data += buffer[..<n]
    }
    return String(decoding: data, as: UTF8.self)
}

/// Writes all of `string`, stopping early only if the peer has gone.
public func writeAll(_ fd: Int32, _ string: String) {
    var bytes = Array(string.utf8)[...]
    while !bytes.isEmpty {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return }
        bytes = bytes.dropFirst(n)
    }
}
