// The master layout, after Hyprland's: one window, the master, takes a share of the screen on one side and the
// others share the rest in a stack beside it. The first window is the master and fills the screen alone; the
// second opens the stack and later ones join its bottom. When the master closes, the top of the stack takes its
// place; when the stack empties, the master fills the screen again.
//
// The tree keeps one shape: a row holding the master window and the stack, a container of windows only. The stack
// runs top to bottom as tiles or an accordion, and `layout` commands change it whichever window is focused. A
// command that changes the shape, such as join-with, leaves the master layout the way a tree command leaves a
// fixed template: windows then open beside the focused one until `flatten-workspace-tree` rebuilds the shape.
//
// Centred, for wide displays, after Hyprland's `orientation = center`: from the second stacked window on, the
// master takes the middle and the stack splits in two, the row holding the left stack, the master and the right
// stack. New windows join the shorter stack, the right one on a tie, so they alternate right and left; when a
// window closes, the bottom of the longer stack moves over to keep them even. With one stacked window the master
// takes the left, as Hyprland's `center_master_fallback` does by default.

/// The side of the screen the master window takes.
public enum MasterSide: Equatable, Sendable {
    case left, right, center
}

extension Workspace {
    public var isMaster: Bool { if case .master = algorithm { true } else { false } }

    /// The index of the master in the root row: the stack goes on the other side, or on both of a centred master.
    private var masterIndex: Int {
        switch root.children.count {
        case 2: masterSide == .right ? 1 : 0
        case 3: 1
        default: 0
        }
    }

    /// The paths of the stacks, left to right: none while the master is alone or the workspace is empty, one
    /// beside the master, or one on each side of a centred master.
    var stackPaths: [[Int]] { root.children.indices.filter { $0 != masterIndex }.map { [$0] } }

    /// The path of the stack whose top replaces a closing master: the only one, or a centred master's right one.
    var stackPath: [Int]? { stackPaths.last }

    /// Whether the tree has the master layout's shape: nothing, a lone window, or a window and a stack of windows
    /// side by side, the window on the configured side, or a centred window between two stacks.
    var isMasterTree: Bool {
        guard isMaster, root.orientation == .horizontal, root.mode == .tiles,
              root.children.count <= (masterSide == .center ? 3 : 2) else { return false }
        guard root.children.count >= 2 else { return root.children.allSatisfy { if case .window = $0 { true } else { false } } }
        guard case .window = root.children[masterIndex] else { return false }
        return stackPaths.allSatisfy { path in
            guard case .container(let stack) = root.node(at: path) else { return false }
            return !stack.children.isEmpty && stack.children.allSatisfy { if case .window = $0 { true } else { false } }
        }
    }

    /// The master window, nil if the workspace is empty or not in the master shape.
    var masterWindow: WindowID? {
        guard isMasterTree, !root.children.isEmpty, case .window(let id) = root.children[masterIndex] else { return nil }
        return id
    }

    /// The master's share and the stack's, in the root row's order.
    private var masterRatios: [Double] { ratios(masterShare: masterSize) }

    /// The root row's ratios with the master at `share`. A centred master's stacks split the rest evenly.
    private func ratios(masterShare share: Double) -> [Double] {
        switch root.children.count {
        case 3: [(1 - share) / 2, share, (1 - share) / 2]
        default: masterIndex == 0 ? [share, 1 - share] : [1 - share, share]
        }
    }

    /// Windows in master order: the master, then the stack from the top. A centred master's stacks alternate,
    /// right first, as new windows join them, so laying the order out again gives the same shape.
    var masterOrder: [WindowID] {
        guard let master = masterWindow else { return windows }
        let stacks = stackPaths.reversed().map { root.node(at: $0).windows }
        let depth = stacks.map(\.count).max() ?? 0
        return [master] + (0..<depth).flatMap { row in stacks.compactMap { row < $0.count ? $0[row] : nil } }
    }

    /// Make the first window the master, open the stack with the second and add later ones to its bottom, or to
    /// the bottom of a centred master's shorter stack. False if the tree has left the master shape.
    mutating func insertIntoMaster(_ id: WindowID) -> Bool {
        guard isMasterTree else { return false }
        switch root.children.count {
        case 0:
            root.insert(.window(id), at: 0)
        case 1:
            let stack = Container(stackOrientation, stackMode, [.window(id)])
            root.insert(.container(stack), at: masterSide == .right ? 0 : 1)
            root.setRatios(masterRatios)
        case 2 where masterSide == .center:
            // The second stacked window centres the master: it opens the left stack, and the master keeps its share.
            let share = root.ratios[masterIndex]
            root.insert(.container(Container(stackOrientation, stackMode, [.window(id)])), at: 0)
            root.setRatios(ratios(masterShare: share))
        default:
            let counts = stackPaths.map { root.container(at: $0).children.count }
            let path = counts.count == 2 && counts[0] < counts[1] ? stackPaths[0] : stackPath!
            root.modify(at: path) { $0.insert(.window(id), at: $0.children.count) }
        }
        return true
    }

    /// Remove the window at `path` from a master-shaped tree: the top of the stack replaces a closing master, and
    /// a stack losing its last window goes, leaving the master the screen or, centred, the left.
    mutating func removeFromMaster(at path: [Int]) {
        guard let stackPath else { return root.remove(at: path[0]) }
        let share = root.ratios[masterIndex]
        let stack = root.container(at: stackPath)
        if path.count == 1 {
            // The master closes; the top of the stack takes its place, keeping the master's share.
            let top = stack.children[0]
            if stack.children.count == 1, stackPaths.count == 1 {
                root = Container(.horizontal, .tiles, [top])
            } else if stack.children.count == 1 {
                root.remove(at: stackPath[0])
                root.replace(at: path[0], with: top)
            } else {
                root.modify(at: stackPath) { $0.remove(at: 0) }
                root.replace(at: path[0], with: top)
            }
        } else if root.container(at: [path[0]]).children.count == 1 {
            root.remove(at: path[0])
        } else {
            root.modify(at: [path[0]]) { $0.remove(at: path[1]) }
        }
        if masterSide == .center { evenStacks(masterShare: share) }
    }

    /// After a centred master's window closed, a stack emptied gets the bottom of the other back if it holds two
    /// or more; a lone left stack comes round to the master's right. Then the bottom of the longer stack moves over
    /// until neither holds two more than the other. The master keeps `share` when the row changes.
    private mutating func evenStacks(masterShare share: Double) {
        func takeBottom(of index: Int) -> Node {
            let last = root.container(at: [index]).children.count - 1
            let node = root.container(at: [index]).children[last]
            root.modify(at: [index]) { $0.remove(at: last) }
            return node
        }
        func opensStack(at index: Int, from other: Int) {
            root.insert(.container(Container(stackOrientation, stackMode, [takeBottom(of: other)])), at: index)
        }
        if root.children.count == 2, case .container(let left) = root.children[0] {
            if left.children.count > 1 {
                opensStack(at: 2, from: 0)
            } else {
                let ratios = root.ratios, stack = root.children[0]
                root.remove(at: 0)
                root.insert(stack, at: 1)
                root.setRatios(ratios.reversed())
            }
        }
        if root.children.count == 2, root.container(at: [1]).children.count > 1 { opensStack(at: 0, from: 1) }
        if root.children.count == 3 {
            while true {
                let left = root.container(at: [0]).children.count, right = root.container(at: [2]).children.count
                guard abs(left - right) > 1 else { break }
                let (from, to) = left > right ? (0, 2) : (2, 0)
                let node = takeBottom(of: from)
                root.modify(at: [to]) { $0.insert(node, at: $0.children.count) }
            }
        }
        if root.children.count > 1, abs(root.ratios[masterIndex] - share) > 1e-9 { root.setRatios(ratios(masterShare: share)) }
    }

    /// Switching to the master layout from another: the focused window becomes the master and the others stack in
    /// `ids` order, as an accordion if most of them were shown in one, else as tiles. Returns the master order.
    mutating func takeOverForMaster(_ ids: [WindowID]) -> [WindowID] {
        let others = ids.filter { $0 != focused }
        let inAccordions = others.filter { container(of: $0)?.mode == .accordion }.count
        stackMode = inAccordions * 2 > others.count ? .accordion : .tiles
        guard let focused, ids.contains(focused) else { return ids }
        return [focused] + others
    }

    /// Set the stack's mode, orientation or both, and keep them for a stack opened later. The stack keeps running
    /// top to bottom when it becomes an accordion, whatever `autoOrientAccordions` says, unless an orientation is
    /// given. A centred master's two stacks change together.
    mutating func setStackLayout(_ mode: LayoutMode?, _ orientation: ContainerOrientation?) {
        if let mode { stackMode = mode }
        if let orientation { stackOrientation = orientation }
        for path in stackPaths {
            root.modify(at: path) { stack in
                stack.mode = stackMode
                stack.orientation = stackOrientation
            }
        }
    }

    /// Give the master its configured share and the stacked windows equal ones.
    mutating func balanceMaster() {
        root.balance()
        if stackPath != nil { root.setRatios(masterRatios) }
    }

    /// Swap the focused window with the master, or the master with the top of the stack when it is focused. Both
    /// tiles keep their sizes and the focus stays with the focused window. False with nothing to swap.
    @discardableResult
    public mutating func swapWithMaster() -> Bool {
        isFullscreen = false
        guard let focused, let master = masterWindow, let stackPath else { return false }
        let other = focused == master ? root.node(at: stackPath).windows[0] : master
        return swap(focused, other)
    }

    /// Move the focused window by swapping it with its neighbour in `direction`, so the shape stays.
    mutating func moveInMaster(_ direction: Direction) -> Bool {
        guard let focused, let other = neighbor(of: focused, direction) else { return false }
        return swap(focused, other)
    }
}
