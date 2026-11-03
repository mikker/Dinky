import AppKit

// Whether Mission Control, App Exposé or Show Desktop is showing. On macOS 27 WindowManager draws them:
// it orders in a display-sized window at level 19 on entry and hides it on exit, which the window model
// sees like any other window. Layout writes pause, borders hide and hover focus stands down while it is up.
final class MissionControl {
    static let shared = MissionControl()

    private(set) var active = false

    /// Called with the window model after each of its events. True if `active` changed.
    func update(from model: WindowModel) -> Bool {
        let screens = NSScreen.screens.map { $0.frame.size }
        let showing = model.windows.values.contains { window in
            window.bundleID == "com.apple.WindowManager" && window.level == 19 && window.isOrderedIn
                && screens.contains { abs($0.width - window.frame.width) < 2 && abs($0.height - window.frame.height) < 2 }
        }
        guard showing != active else { return false }
        active = showing
        return true
    }
}
