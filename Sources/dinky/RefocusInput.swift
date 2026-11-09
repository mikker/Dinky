import CoreGraphics

/// Counts rather than elapsed times: even a click that leaves AX focus unchanged supersedes a pending repair.
/// Key-up is deliberately absent, since releasing Cmd-W must not cancel the close it requested.
struct RefocusInput: Equatable {
    let counts: [UInt32]

    func allowsRepair(leaving: UInt32, keyboard: UInt32?, input: Self) -> Bool {
        self == input && (keyboard == 0 || keyboard == leaving)
    }

    static var current: Self {
        Self(counts: [CGEventType.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel].map {
            CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
        })
    }
}

/// WindowServer can publish the loss of focus before the removal. Attribute a loss to no window to its owner,
/// without a timing guess: another window, a focus command, or any intervening input ends that ownership.
struct FocusDeparture {
    private var loss: (id: UInt32, input: RefocusInput)?

    mutating func changed(from: UInt32, to: UInt32, input: RefocusInput) {
        if to != 0 { loss = nil }
        else if from != 0 { loss = (from, input) }
    }

    mutating func forget(_ id: UInt32) {
        if loss?.id == id { loss = nil }
    }

    func hadFocus(_ id: UInt32, focused: UInt32, input: RefocusInput) -> Bool {
        id == focused || (loss?.id == id && loss?.input == input)
    }
}
