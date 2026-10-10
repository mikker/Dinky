import Foundation

/// The user's tree edits. Display geometry, gaps and learned minimums come from the current session.
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public let root: Container
    public let algorithm: TilingAlgorithm
    public let focused: WindowID?
    public let fullscreen: WindowID?

    public init(_ workspace: Workspace) {
        root = workspace.root
        algorithm = workspace.algorithm
        focused = workspace.focused
        fullscreen = workspace.fullscreen
    }

    public var windows: [WindowID] { Node.container(root).windows }

    /// Validate a decoded tree before any layout code indexes its children or ratios.
    public var isValid: Bool {
        var ids: Set<WindowID> = []
        var nodes = 0
        func valid(_ container: Container, depth: Int) -> Bool {
            nodes += 1
            guard depth <= 64, nodes <= 4096, container.active >= 0,
                  container.children.count == container.ratios.count,
                  container.ratios.allSatisfy({ $0.isFinite && $0 > 0 }),
                  container.children.isEmpty || abs(container.ratios.reduce(0, +) - 1) < 0.000001 else { return false }
            for node in container.children {
                switch node {
                case .window(let id):
                    nodes += 1
                    guard nodes <= 4096, id != 0, ids.insert(id).inserted else { return false }
                case .container(let child):
                    guard valid(child, depth: depth + 1) else { return false }
                }
            }
            return true
        }
        guard valid(root, depth: 0), focused.map(ids.contains) ?? true,
              fullscreen == nil || fullscreen == focused else { return false }
        if case .fixed(let rows, let columns, _) = algorithm {
            return rows > 0 && columns > 0 && columns <= 4096 && rows <= 4096 / columns
        }
        return true
    }


}

extension Workspace {
    /// Keep surviving leaves in their saved order and proportions. New windows are inserted by the caller.
    /// A changed layout algorithm takes precedence over the saved tree.
    @discardableResult
    public mutating func restore(_ snapshot: WorkspaceSnapshot, retaining ids: Set<WindowID>) -> Bool {
        guard snapshot.isValid, snapshot.algorithm == algorithm else { return false }
        root = snapshot.root
        focused = snapshot.focused
        isFullscreen = snapshot.fullscreen != nil
        let missing = snapshot.windows.filter { !ids.contains($0) }
        for id in missing { remove(id) }
        return true
    }
}
