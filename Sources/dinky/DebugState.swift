import AppKit
import DinkyLayout
import DinkyPrivate

// `debug-state`: the coordinator's view of the world as JSON, for the fuzzer (scripts/fuzz.py) and bug
// reports. Frames are [x, y, width, height] in global coordinates, top-left origin. `live-frame` and
// `live-space` are read from WindowServer now; `frame` and `space` are what the model last saw. `hidden` is
// whether the window's app is hidden now.
extension Coordinator {
    func debugState() -> String {
        let displays = AppState.shared.displays
        displays.reconcile()
        let numbers = AppState.shared.numbers.binding
        var hidden: [pid_t: Bool] = [:]
        func isHidden(_ pid: pid_t) -> Bool {
            if let known = hidden[pid] { return known }
            let value = NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
            hidden[pid] = value
            return value
        }
        let state: [String: Any] = [
            "enabled": enabled,
            "focused": focusedWindow,
            "displays": displays.displays.map { d in
                ["uuid": d.uuid, "current-space": d.currentSpaceID, "spaces": d.spaces, "user-spaces": d.userSpaces,
                 "visible-area": json(d.visibleArea)] as [String: Any]
            },
            "workspaces": Dictionary(uniqueKeysWithValues: numbers.map { ("\($0.key)", $0.value) }),
            "trees": workspaces.map { key, workspace in
                let layout = workspace.layout()
                return [
                    "display": displays.display(containingSpace: key)?.uuid ?? "", "space": key,
                    "mode": workspace.root.mode == .accordion ? "accordion" : "tiles",
                    "windows": workspace.windows,
                    "focused": workspace.focused ?? 0,
                    "fullscreen": workspace.fullscreen ?? 0,
                    "expected": Dictionary(uniqueKeysWithValues: layout.frames.map { ("\($0.key)", json($0.value)) }),
                ] as [String: Any]
            },
            "placements": placements.map { id, placement in
                ["id": id, "floating": placement.floating,
                 "display": placement.space.flatMap { displays.display(containingSpace: $0)?.uuid } ?? "",
                 "space": placement.space ?? 0] as [String: Any]
            },
            "animating": animatingWindows.sorted(),
            "dragging": dragging ?? 0,
            "minimum-sizes": Dictionary(uniqueKeysWithValues: applier.minimumSizes.map { ("\($0.key)", [$0.value.width, $0.value.height]) }),
            "windows": model.windows.values.sorted { $0.id < $1.id }.map { w in
                let live = dinky_window_info(w.id)
                return [
                    "id": w.id, "pid": w.pid, "app": w.appName ?? "", "bundle-id": w.bundleID ?? "",
                    "window-identifier": windowIdentifiers[w.id].map { $0 as Any } ?? NSNull(),
                    "frame": json(w.frame), "space": w.spaceID, "normal": w.isNormal, "minimized": w.isMinimized,
                    "hidden": isHidden(w.pid),
                    "live-frame": live.exists ? json(live.frame) : [], "live-space": dinky_window_space_id(w.id),
                ] as [String: Any]
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private func json(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
