import AppKit
import DinkyConfig
import DinkyLayout
import DinkyPrivate

// Trackpad swipes along a scrolling workspace, as in niri. macOS hands the horizontal swipe that switches Spaces
// to the Dock as private Dock control events; a tap ahead of the Dock reads which way each swipe heads and
// decides once who has it. While the scrolling workspace on the display under the pointer has a column that way,
// dinky focuses it and keeps the swipe from the Dock; past the last column the swipe switches Space, the way
// `[swipe] space-switch` says. Anywhere else, a single column or dinky disabled included, the swipe is left
// to macOS whole. The interception follows iss (github.com/joshuarli/iss). Main thread only.
final class SwipeFocus {
    private var config = Swipe()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tracker = SwipeTracker(mode: .instant)
    /// The display under the pointer when the swipe began. The Dock swipes that display too.
    private var display: Display?

    /// Starts or stops the tap for this config. Called once tiling has started and on every config load.
    func update(config: Swipe) {
        self.config = config
        tracker = SwipeTracker(mode: config.spaceSwitch)
        if config.enabled { start() } else { stop() }
    }

    private func start() {
        guard tap == nil else { return }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: dinky_dock_swipe_event_mask(), callback: swipeCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            fputs("swipe: could not create event tap (Accessibility?)\n", stderr)
            return
        }
        dinky_forget_own_dock_swipes()
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
    }

    private func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
        (self.tap, source) = (nil, nil)
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tracker = SwipeTracker(mode: config.spaceSwitch)
            dinky_forget_own_dock_swipes()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        var phase = DinkySwipePhase.began, direction: Int32 = 0
        guard dinky_read_dock_swipe(event, &phase, &direction) else {
            return dinky_is_gesture_event(event) && !tracker.passesGestureEvents ? nil : pass
        }
        if dinky_take_own_dock_swipe() { return pass }
        let step = tracker.handle(phase, Int(direction), needsPayload: dinky_dock_swipe_needs_payload(),
                                  start: { begin(at: event.location) },
                                  claim: { claim($0) })
        if let way = step.switchSpace, let display {
            // After the callback returns, so the switch's own swipe comes after this one's end.
            DispatchQueue.main.async { [weak self] in self?.swipeSpace(way, on: display) }
        }
        switch step.verdict {
        case .pass: return pass
        case .swallow: return nil
        case .neutralize:
            dinky_neutralize_dock_swipe(event)
            return pass
        }
    }

    /// Whether dinky may take the swipe beginning at `point`: a scrolling workspace with a column to go to.
    private func begin(at point: CGPoint) -> Bool {
        display = AppState.shared.displays.displays.first { $0.frame.contains(point) }
        guard AppState.shared.enabled, !MissionControl.shared.active, let display,
              let workspace = AppState.shared.coordinator?.workspace(on: display) else { return false }
        return workspace.swipeTarget(.left) != nil || workspace.swipeTarget(.right) != nil
    }

    /// Focuses the column the swipe heads for, if there is one; +1 is right, toward the next Space.
    private func claim(_ way: Int) -> Bool {
        let direction: Direction = way > 0 ? .right : .left
        guard let display, let coordinator = AppState.shared.coordinator,
              let workspace = coordinator.workspace(on: display), let from = workspace.focused,
              workspace.swipeTarget(direction) != nil else {
            log("swipe: no column \(direction), \(config.spaceSwitch == .native ? "macOS switches Space" : "switching Space")")
            return false
        }
        log("swipe: focus \(direction)")
        // After the callback returns: focusing raises windows, which must not hold up the tap.
        DispatchQueue.main.async {
            guard let id = coordinator.command(on: from, { $0.focus(direction) ? $0.focused : nil }) ?? nil else { return }
            coordinator.focus(id)
        }
        return true
    }

    /// Switches the display one Space the way the swipe went, as the Dock would have: full-screen Spaces count,
    /// and there is no wrapping around.
    private func swipeSpace(_ way: Int, on display: Display) {
        let model = AppState.shared.displays
        model.reconcile()
        guard let display = model.displays.first(where: { $0.uuid == display.uuid }),
              let index = display.spaces.firstIndex(of: targetSpaceID(on: display)),
              display.spaces.indices.contains(index + way) else { return }
        switchSpace(toSpaceID: display.spaces[index + way], on: display)
    }

    private func log(_ message: String) {
        print("\(stamp()) \(message)")
        fflush(stdout)
    }
}

private func swipeCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                           refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<SwipeFocus>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}

/// One swipe from began to ended, as the tap sees it, apart from the tap so the order of events can be followed.
/// `start` is asked at began whether dinky may take the swipe at all; if not, it is the Dock's whole. Otherwise
/// `claim` is asked once, as soon as the way is known (+1 right, -1 left), and takes the swipe by focusing that way.
/// A swipe dinky does not claim goes past the last column: in `native` mode the Dock has it, which has seen it
/// all along; in `instant` mode dinky has kept it from the Dock and switches Space itself once it ends.
struct SwipeTracker {
    enum Verdict: Equatable { case pass, swallow, neutralize }

    private enum State: Equatable {
        /// No swipe, or one that began before the tap saw it.
        case idle
        /// The Dock's whole.
        case dock
        /// Dinky may take it, once it is known which way it heads.
        case undecided
        /// Dinky focused a column.
        case claimed
        /// Heading past the last column, in `instant` mode.
        case pastEdge(Int)
    }

    let mode: SpaceSwitch
    private var state = State.idle

    init(mode: SpaceSwitch) {
        self.mode = mode
    }

    /// Whether the gesture events that come with a swipe go on: only once dinky has taken the swipe are they
    /// kept back, or all along while dinky keeps it from the Dock.
    var passesGestureEvents: Bool {
        switch state {
        case .idle, .dock: true
        case .claimed: false
        case .undecided, .pastEdge: mode == .native
        }
    }

    /// The verdict on one Dock swipe event, and the way to switch Space once it has gone, if any. `needsPayload`:
    /// on macOS 27 the end goes on to the Dock with its movement cleared, as iss lets it, rather than kept back.
    mutating func handle(_ phase: DinkySwipePhase, _ way: Int, needsPayload: Bool,
                         start: () -> Bool, claim: (Int) -> Bool) -> (verdict: Verdict, switchSpace: Int?) {
        let native = mode == .native
        if phase == .began {
            state = start() ? .undecided : .dock
            return (state == .dock || native ? .pass : .swallow, nil)
        }
        if state == .undecided, way != 0 {
            state = claim(way) ? .claimed : native ? .dock : .pastEdge(way)
        }
        let ending = phase == .ended || phase == .cancelled
        let verdict: Verdict
        var switchSpace: Int?
        switch state {
        case .idle, .dock:
            verdict = .pass
        case .undecided where native:
            verdict = .pass  // the Dock has seen it all, none of it moving
        case .undecided, .claimed, .pastEdge:
            // Dinky has kept it from the Dock. In native mode the Dock saw it begin, so it hears it end too.
            verdict = ending && (native || needsPayload) ? .neutralize : .swallow
            if case .pastEdge(let way) = state, phase == .ended { switchSpace = way }
        }
        if ending { state = .idle }
        return (verdict, switchSpace)
    }
}
