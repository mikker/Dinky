import CoreGraphics

/// Event counts guard pending work; relative event order identifies a completed drag without a timeout.
/// Key-up is deliberately absent, since releasing Cmd-W must not cancel the close it requested.
struct RefocusInput: Equatable {
    let counts: [UInt32]
    var dragged = false

    static var current: Self {
        let drag = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDragged)
        let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let click = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        return Self(counts: [CGEventType.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                            .otherMouseDown, .otherMouseUp, .leftMouseDragged].map {
            CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
        }, dragged: drag < min(key, click))
    }
}

/// The keyboard window's provenance, read live rather than inferred from the frontmost document's stacking.
struct RefocusWindow: Equatable {
    let id: UInt32
    let pid: Int32
    let space: UInt64
    let display: String?
}

/// A removal can redirect the app's key window to its other display. Only that automatic continuation may be
/// replaced: another app, another window here, unknown AX focus, or newer input belongs to macOS/the user.
struct FocusRepair: Equatable {
    let leaving: RefocusWindow
    let removed: Bool
    let input: RefocusInput

    func allows(keyboard: RefocusWindow?, input current: RefocusInput) -> Bool {
        guard input == current, !input.dragged, let keyboard else { return false }
        if keyboard.id == 0 || keyboard.id == leaving.id { return true }
        // A late minimize notification cannot distinguish an automatic redirect from the user's click.
        return removed && leaving.pid > 0 && keyboard.pid == leaving.pid && keyboard.space != 0 && keyboard.space != leaving.space
            && keyboard.display != nil && leaving.display != nil && keyboard.display != leaving.display
    }
}

/// Departure provenance, not successor policy. WindowServer may report focus loss before removal.
/// Keep that observation only while its input is unchanged; otherwise use the actual departure notification.
struct FocusDeparture {
    private var loss: (id: UInt32, input: RefocusInput)?
    private var ignored: (id: UInt32, input: RefocusInput)?

    mutating func changed(from: UInt32, to: UInt32, input: RefocusInput, departed: Bool = false) {
        if from != 0 {
            loss = !isIgnored(from, input: input) && (to == 0 || departed) ? (from, input) : nil
        } else if loss?.input != input {
            loss = nil
        }
        if to != 0 { ignored = nil }
    }

    mutating func cancel(focused: UInt32, input: RefocusInput) {
        loss = nil
        ignored = (focused, input)
    }

    mutating func forget(_ id: UInt32) {
        if loss?.id == id { loss = nil }
    }

    func hadFocus(_ id: UInt32, focused: UInt32, input: RefocusInput) -> Bool {
        !input.dragged && !isIgnored(id, input: input)
            && (id == focused || (loss?.id == id && loss?.input == input))
    }

    private func isIgnored(_ id: UInt32, input: RefocusInput) -> Bool {
        ignored?.id == id && ignored?.input == input
    }
}
