import Darwin

// Other tiling window managers. Two tilers move the same windows back and forth, and to the user that looks like
// dinky cannot tile: frames snap back, workspaces fall back to another layout, and the readback teaches dinky
// minimum sizes that are not real. Snapping tools (Rectangle, Magnet) only move windows when asked and are left out;
// float the window or disable dinky before snapping it, since tiled frames are still recovered.

/// By lowercased process name, the tiler's display name. Process names cover apps and plain daemons (yabai) alike.
private let tilers = ["aerospace": "AeroSpace", "amethyst": "Amethyst", "yabai": "yabai", "kiwidesk": "KiwiDesk"]

/// The other tiling window managers running now, by name.
func runningOtherTilers() -> [String] {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var name = [CChar](repeating: 0, count: 64)
    var found: Set<String> = []
    for pid in pids.prefix(Int(max(count, 0))) where pid > 0 && proc_name(pid, &name, UInt32(name.count)) > 0 {
        if let tiler = tilers[String(cString: name).lowercased()] { found.insert(tiler) }
    }
    return found.sorted()
}

/// The warning for the menu, the log and `dinky doctor`.
func otherTilersWarning(_ names: [String]) -> String {
    "\(names.joined(separator: " and ")) \(names.count == 1 ? "is" : "are") also tiling windows; quit \(names.count == 1 ? "it" : "them") or dinky's layouts will be undone"
}
