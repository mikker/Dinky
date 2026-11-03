import DinkySocket
import Foundation

// Keep the app's path policy here. The transport requires an explicit path so tests and other
// callers cannot accidentally unlink or connect to the running app's socket.
let socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("dinky.sock")
typealias Reply = DinkySocket.Reply
typealias SocketServer = DinkySocket.SocketServer

func appIsRunning() -> Bool { DinkySocket.appIsRunning(path: socketPath) }

func sendToApp(_ line: String) -> Reply? { DinkySocket.sendToApp(line, path: socketPath) }
