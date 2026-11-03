import AppKit
import DinkyConfig
import Testing
@testable import dinky

// Exercises production SwipeFocus.update/handler/queued actions and AppState.setEnabled. No system event tap,
// event posting, global AppState, started models, config I/O, recovery journal or real-time timer is used.
private final class SwipeHarness {
    final class Events: SwipeEvents {
        var receive: ((CGEventType, CGEvent) -> Unmanaged<CGEvent>?)?
        var starts = 0
        var stops = 0
        var reenables = 0
        var listening: Bool { receive != nil }
        func start(_ receive: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) -> Bool {
            starts += 1
            self.receive = receive
            return true
        }
        func stop() { stops += 1; receive = nil }
        func reenable() { reenables += 1 }
        func send(_ event: CGEvent, type: CGEventType = .null) -> Bool {
            guard let receive else { return true } // With no tap, the system receives the event unchanged.
            return receive(type, event) != nil
        }
    }

    final class State {
        var snapshot: SwipeSession.Snapshot? = .init(display: "A", space: 10)
        var edge = false
        var claims = 0
        var focuses = 0
        var switches = 0
        var pending: [() -> Void] = []
        var time: TimeInterval = 0
        var deadlines: [(TimeInterval, () -> Void)] = []

        func flush() {
            let actions = pending
            pending.removeAll()
            actions.forEach { $0() }
        }

        func advance(_ interval: TimeInterval) {
            time += interval
            let due = deadlines.filter { $0.0 <= time }
            deadlines.removeAll { $0.0 <= time }
            due.forEach { $0.1() }
        }
    }

    let events = Events()
    let state = State()
    let focus: SwipeFocus
    var config = Swipe()

    init(mode: SpaceSwitch = .instant, canSuppress: Bool = true) {
        let state = self.state
        focus = SwipeFocus(events: events, context: .init(
            canSuppress: { canSuppress },
            begin: { _, _ in state.snapshot },
            snapshot: { _ in state.snapshot },
            focus: { _, _ in
                state.claims += 1
                return state.edge ? nil : { state.focuses += 1 }
            },
            switchToNeighbor: { _, _ in state.switches += 1 }
        ), enqueue: { state.pending.append($0) }, after: { delay, action in
            state.deadlines.append((state.time + delay, action))
        })
        config.enabled = true
        config.spaceSwitch = mode
        focus.update(config: config)
    }

    @discardableResult
    func send(_ phase: Int64, way: Double = 0) -> Bool {
        let event = CGEvent(source: nil)!
        for (field, value) in [(55, Int64(30)), (110, 23), (123, 1), (132, phase)] {
            event.setIntegerValueField(CGEventField(rawValue: UInt32(field))!, value: value)
        }
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        event.setDoubleValueField(CGEventField(rawValue: 124)!, value: way)
        return events.send(event)
    }

    func companion() -> Bool {
        let event = CGEvent(source: nil)!
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)
        return events.send(event)
    }
}

struct SwipeLifecycleTests {
    @Test(arguments: ["same", "native", "disabled"])
    func configReloadDrainsOwnedStreamAndNewGestureUsesNewConfig(change: String) {
        let h = SwipeHarness()
        #expect(h.send(1) == false)
        if change == "native" { h.config.spaceSwitch = .native }
        if change == "disabled" { h.config.enabled = false }
        h.focus.update(config: h.config)
        #expect(h.events.listening) // Even feature disable must keep the tap until the owned end.
        #expect(h.companion() == false)
        #expect(h.send(2, way: 1) == false)
        #expect(h.send(4, way: 1) == false)
        h.state.flush()
        #expect(h.state.claims == 0)
        #expect(h.state.focuses == 0 && h.state.switches == 0)
        #expect(h.events.listening == h.config.enabled)
        #expect(h.send(1) == (change != "same"))
        h.send(2, way: 1)
        h.send(4, way: 1)
        h.state.flush()
        #expect(h.state.focuses == (change == "disabled" ? 0 : 1))
    }

    @Test(arguments: [SpaceSwitch.instant, .native])
    func appDisableEnableBetweenCallbacksDoesNotReviveGesture(mode: SpaceSwitch) {
        let h = SwipeHarness(mode: mode)
        let app = AppState(swipeFocus: h.focus)
        h.send(1)
        app.setEnabled(false)
        app.setEnabled(true) // No callback or disabled snapshot occurs between these transitions.
        h.send(2, way: 1)
        h.send(4, way: 1)
        h.state.flush()
        #expect(h.state.claims == 0)
        #expect(h.state.focuses == 0 && h.state.switches == 0)
        h.send(1)
        h.send(2, way: 1)
        h.send(4, way: 1)
        h.state.flush()
        #expect(h.state.focuses == 1)
    }

    @Test(arguments: [SpaceSwitch.instant, .native])
    func appDisableEnableCancelsAlreadyQueuedFocus(mode: SpaceSwitch) {
        let h = SwipeHarness(mode: mode)
        let app = AppState(swipeFocus: h.focus)
        h.send(1)
        h.send(2, way: 1)
        #expect(h.state.pending.count == 1)
        app.setEnabled(false)
        app.setEnabled(true)
        h.state.flush() // State snapshot has stayed enabled and on Space 10 throughout the test.
        #expect(h.state.focuses == 0)
        #expect(h.send(4, way: 1) == (mode == .native))
    }

    @Test func appDisableEnableCancelsQueuedEdgeSwitch() {
        let h = SwipeHarness()
        let app = AppState(swipeFocus: h.focus)
        h.state.edge = true
        h.send(1)
        h.send(2, way: 1)
        h.send(4, way: 1)
        #expect(h.state.pending.count == 1)
        app.setEnabled(false)
        app.setEnabled(true)
        h.state.flush()
        #expect(h.state.switches == 0)
    }

    @Test func configReloadCancelsQueuedFocusAndEdgeSwitch() {
        let h = SwipeHarness()
        h.send(1)
        h.send(2, way: 1)
        h.focus.update(config: h.config)
        h.state.flush()
        #expect(h.state.focuses == 0)
        #expect(h.send(4, way: 1) == false)
        h.state.edge = true
        h.send(1)
        h.send(2, way: 1)
        h.send(4, way: 1)
        h.focus.update(config: h.config)
        h.state.flush()
        #expect(h.state.switches == 0)
    }

    @Test func disableWithoutEndRecoversAfterPhysicalStreamGoesQuiet() {
        let h = SwipeHarness()
        h.send(1)
        h.config.enabled = false
        h.focus.update(config: h.config)
        h.state.advance(1.9)
        #expect(h.events.listening)
        #expect(h.companion() == false) // Activity extends the missing-end deadline.
        h.state.advance(1.9)
        #expect(h.events.listening)
        h.state.advance(0.2)
        #expect(!h.events.listening)
        #expect(h.events.stops == 1)
        h.state.flush()
        #expect(h.state.focuses == 0 && h.state.switches == 0)
    }

    @Test func oldRecoveryCannotReleaseNewOwnedGesture() {
        let h = SwipeHarness()
        h.send(1)
        h.focus.update(config: h.config)
        h.send(4)
        h.send(1)
        h.state.advance(3)
        #expect(h.events.listening)
        #expect(h.companion() == false)
        #expect(h.send(2, way: 1) == false)
        #expect(h.send(4, way: 1) == false)
        h.state.flush()
        #expect(h.state.focuses == 1)
    }

    @Test func actualHandlerCancelsSpaceLandingAndPendingActions() {
        let h = SwipeHarness()
        h.send(1)
        h.state.snapshot = .init(display: "A", space: 11)
        #expect(h.send(2, way: 1) == false)
        #expect(h.send(4, way: 1) == false)
        h.state.flush()
        #expect(h.state.claims == 0)
        h.send(1)
        h.send(2, way: 1)
        h.state.snapshot?.missionControl = true
        h.state.flush()
        #expect(h.state.focuses == 0)
    }

    @Test func nativeFallbackNeverOwnsStreamAndCanStopImmediately() {
        let h = SwipeHarness(canSuppress: false)
        #expect(h.send(1))
        #expect(h.send(2, way: 1))
        #expect(h.companion())
        h.config.enabled = false
        h.focus.update(config: h.config)
        #expect(!h.events.listening)
        #expect(h.send(4, way: 1))
        h.state.flush()
        #expect(h.state.focuses == 0)
    }

    @Test func tapInterruptionCancelsQueuedFocus() {
        let h = SwipeHarness()
        h.send(1)
        h.send(2, way: 1)
        let event = CGEvent(source: nil)!
        #expect(h.events.send(event, type: .tapDisabledByTimeout))
        h.state.flush()
        #expect(h.state.focuses == 0)
        #expect(h.events.reenables == 1)
        #expect(h.send(1) == false)
    }
}
