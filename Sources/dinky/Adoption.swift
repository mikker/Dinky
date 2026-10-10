import AppKit
import DinkyLayout
import DinkyPrivate

// A new window opens on the display that had focus when it first showed, whatever display the app picked: a
// saved frame, or the app's key window on another display. AeroSpace does the same.

extension Coordinator {
    /// Records the display that had focus as a new window's, the first time it shows: the focused display, or the
    /// one focused before the window if it already took focus. Windows open before dinky started stay where they are.
    func noteFirstShowing(_ window: Window) {
        guard window.identity.firstSeen > model.seededAt else { return }
        adoptTargets[window.id] = lastFocused == window.id ? displayBeforeFocus : displays.focusedDisplay(window: lastFocused)?.uuid
    }

    /// Starts moving a just-classified new window to the display that had focus when it first showed, holding it
    /// out of the trees meanwhile. False if it stays where the app put it.
    func adopt(_ window: Window) -> Bool {
        guard let target = adoptTargets.removeValue(forKey: window.id),
              !AppState.shared.numbers.wasRestored(window),
              let display = displays.displays.first(where: { $0.uuid == target }),
              let current = displays.display(containingSpace: window.spaceID), current.uuid != display.uuid,
              current.userSpaces.contains(window.spaceID), display.userSpaces.contains(display.currentSpaceID)
        else { return false }
        adopting.insert(window.id)
        // Out of the event handler: the move waits for the window to arrive, and its events re-enter `track`.
        DispatchQueue.main.async { [weak self] in
            guard let self, adopting.contains(window.id) else { return }
            let error = Dispatcher.adopt(window.id, onto: display)
            adopting.remove(window.id)
            if let error {
                print("\(stamp()) adopt: window \(window.id) stays put, \(error.text)")
            } else {
                print("\(stamp()) adopt: moved new window \(window.id) of \(window.appName ?? "?") from display \(current.id) to the focused display \(display.id)")
            }
            fflush(stdout)
            // Re-reads its Space and tracks it there, or where it was if the move failed.
            windowMoved(window.id, refocus: false)
            if error == nil { focus(window.id) }
        }
        return true
    }
}
