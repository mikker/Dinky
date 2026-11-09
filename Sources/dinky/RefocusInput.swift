import CoreGraphics

/// Event counts guard pending work; relative event order identifies a completed drag without a timeout.
/// Key-up is deliberately absent, since releasing Cmd-W must not cancel the close it requested.
struct RefocusInput: Equatable {
    let counts: [UInt32]
    var dragged = false

    static func isDepartureKey(_ event: CGEvent) -> Bool {
        // Cmd-H, Q, W and M. Observe only commands the key tap passes through to the app.
        event.flags.contains(.maskCommand) && [4, 12, 13, 46].contains(Int(event.getIntegerValueField(.keyboardEventKeycode)))
    }

    /// The head-insert tap precedes this key's session counter update. Include the initiating key in the
    /// eventual check, and let a fresh keyboard command supersede an earlier drag.
    var afterKeyDown: Self {
        var counts = counts
        counts[0] &+= 1
        return Self(counts: counts, dragged: false)
    }

    static var current: Self {
        let drag = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDragged)
        let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let click = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        return Self(counts: [CGEventType.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                            .otherMouseDown, .otherMouseUp, .scrollWheel, .leftMouseDragged, .mouseMoved].map {
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
    let input: RefocusInput

    func allows(keyboard: RefocusWindow?, input current: RefocusInput) -> Bool {
        guard input == current, !input.dragged, let keyboard else { return false }
        if keyboard.id == 0 || keyboard.id == leaving.id { return true }
        return leaving.pid > 0 && keyboard.pid == leaving.pid && keyboard.space != 0 && keyboard.space != leaving.space
            && keyboard.display != nil && leaving.display != nil && keyboard.display != leaving.display
    }
}

/// Departure provenance, not successor policy. WindowServer may report focus loss before removal, or native
/// minimization after the animation. Preserve the originating input across either ordering, never restamping
/// a native command with input that arrived while its notification was delayed.
struct FocusDeparture {
    private var loss: (id: UInt32, input: RefocusInput)?
    private var ignored: (id: UInt32, input: RefocusInput)?
    private var nativeCommands: [UInt32: (before: RefocusInput, after: RefocusInput, cancelled: Bool)] = [:]

    /// Native minimize can publish its WindowServer transition after the animation. Preserve the input at
    /// the initiating command, not at that late notification. It authorizes nothing until a real departure.
    mutating func prepare(_ id: UInt32, input: RefocusInput) {
        nativeCommands[id] = (input, input.afterKeyDown, false)
        ignored = nil
    }

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
        for id in nativeCommands.keys { nativeCommands[id]?.cancelled = true }
    }

    mutating func forget(_ id: UInt32) {
        if loss?.id == id { loss = nil }
        nativeCommands[id] = nil
    }

    func repairInput(for id: UInt32, focused: UInt32, current input: RefocusInput) -> RefocusInput? {
        if let command = nativeCommands[id] {
            return !command.cancelled && (input == command.before || input == command.after) ? command.after : nil
        }
        guard !input.dragged, !isIgnored(id, input: input),
              id == focused || (loss?.id == id && loss?.input == input) else { return nil }
        return input
    }

    private func isIgnored(_ id: UInt32, input: RefocusInput) -> Bool {
        ignored?.id == id && ignored?.input == input
    }
}
