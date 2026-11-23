import Foundation
import DinkyLayout

// Native tabs: a newly shown window at the exact frame of a tile of its app is held out of the trees until
// it turns out to be the next tab of that tile (the tile's window is ordered out) or a window of its own.
extension Coordinator {
    static let tabWait: TimeInterval = 0.25

    /// Ghostty can order the old tab out before the replacement shows. Keep its tile until the matching
    /// newcomer arrives, or release it after the same interval used for the opposite event order.
    func holdDepartingTab(_ id: WindowID) {
        guard departingTabs[id] == nil else { return }
        let release = DispatchWorkItem { [weak self] in
            guard let self else { return }
            departingTabs[id] = nil
            guard let key = placements[id]?.space else { return }
            edit(key) { $0.remove(id) }
            placements[id]!.space = nil
            flush()
        }
        departingTabs[id] = release
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tabWait, execute: release)
    }

    /// Holds a newly shown window out of the tree if it may be the next tab of a tile of its app, and has not been
    /// held before. `settleTab` tiles it after 250 ms if the tile's window is still there.
    func holdAsTab(_ window: Window, in key: UInt64) -> Bool {
        guard let tab = tab(replacedBy: window, in: key) else { return false }
        if departingTabs[tab] != nil {
            replaceTab(tab, with: window.id, in: key)
            return true
        }
        guard !notTabs.contains(window.id) else { return false }
        heldTabs[window.id] = tab
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tabWait) { [weak self] in self?.settleTab(window.id) }
        return true
    }

    /// A tile a newly shown window may be taking over as the next tab of a native tab group: a window of the same
    /// app at exactly the tile's frame. AppKit shows a new tab by giving it the group's frame and ordering it in,
    /// then orders the previous tab out. But some apps (Ghostty, for one) open every new window at the previous
    /// window's frame, so the newcomer is held out of the tree until the tile's window is ordered out or
    /// `settleTab` gives up on it.
    private func tab(replacedBy window: Window, in key: UInt64) -> WindowID? {
        workspaces[key]?.windows.first { id in
            guard id != window.id, let other = model.windows[id] else { return false }
            return other.pid == window.pid && other.frame.isClose(to: window.frame, within: 1)
        }
    }

    /// When a tile's window is ordered out or closed just after a window of its app came in at its frame, that was
    /// a tab switch: the held new tab takes over the tile. False if no newcomer is held for this tile.
    func takeOverTile(of id: WindowID, in key: UInt64) -> Bool {
        guard let newcomer = heldTabs.first(where: { $0.value == id })?.key else { return false }
        heldTabs[newcomer] = nil
        replaceTab(id, with: newcomer, in: key)
        return true
    }

    private func replaceTab(_ id: WindowID, with newcomer: WindowID, in key: UInt64) {
        departingTabs.removeValue(forKey: id)?.cancel()
        edit(key) { $0.replace(id, with: newcomer) }
        placements[id]?.space = nil
        placements[newcomer]!.space = key
    }

    /// The tile's window stayed: the held newcomer was a window of its own, so it is tiled like any other.
    private func settleTab(_ id: WindowID) {
        guard heldTabs.removeValue(forKey: id) != nil, let window = model.windows[id] else { return }
        notTabs.insert(id)
        track(window)
        flush()
    }
}
