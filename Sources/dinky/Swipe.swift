import AppKit
import DinkyConfig
import DinkyLayout
import DinkyPrivate

// Main thread only. Action identity can be cancelled without releasing an owned physical event stream.
final class SwipeFocus {
    struct Context {
        var canSuppress: () -> Bool
        var begin: (CGPoint, Bool) -> SwipeSession.Snapshot?
        var snapshot: (SwipeSession.Token) -> SwipeSession.Snapshot?
        var focus: (SwipeSession.Token, Direction) -> (() -> Void)?
        var switchToNeighbor: (SwipeSession.Token, Int) -> Void
    }

    private let events: SwipeEvents
    private let context: Context
    private let enqueue: (@escaping () -> Void) -> Void
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private var config = Swipe()
    private var enabled = true
    private var listening = false
    private var tracker = SwipeTracker()
    private var session = SwipeSession()
    private var vertical = false
    private var recoveryGeneration: UInt64 = 0

    init(events: SwipeEvents = DockSwipeEvents(), context: Context = .live,
         enqueue: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
         }) {
        self.events = events
        self.context = context
        self.enqueue = enqueue
        self.after = after
    }

    func update(config: Swipe) {
        self.config = config
        cancelActions()
        maintainStream()
    }

    /// Called synchronously at the app's enable boundary, before tiling/restoration can pump the run loop.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if !on { cancelActions() }
        maintainStream()
    }

    private func cancelActions() {
        session.cancel()
        tracker.cancel()
    }

    /// Keep an owned stream until its terminal event. If the end is lost, recover after two seconds without
    /// physical stream activity. A generation makes an old deadline harmless to a new/draining gesture.
    private func maintainStream() {
        recoveryGeneration &+= 1
        if tracker.isDraining {
            let generation = recoveryGeneration
            after(2) { [weak self] in
                guard let self, self.recoveryGeneration == generation, self.tracker.isDraining else { return }
                self.session.cancel()
                self.tracker = SwipeTracker()
                self.maintainStream()
            }
        }
        let needed = (config.enabled && enabled) || tracker.ownsStream
        if needed, !listening {
            listening = events.start { [weak self] type, event in
                guard let self else { return Unmanaged.passUnretained(event) }
                return self.handle(type, event)
            }
        } else if !needed, listening {
            events.stop()
            listening = false
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            session.cancel()
            tracker = SwipeTracker() // External tap loss is not a voluntary mid-stream reload.
            maintainStream()
            if listening { events.reenable() }
            return pass
        }
        if dinky_is_own_dock_swipe(event) { return pass }
        var phase = DinkySwipePhase.began, vertical = false, way: Int32 = 0
        guard dinky_read_dock_swipe(event, &phase, &vertical, &way) else {
            let swallow = dinky_is_gesture_event(event) && !tracker.passesGestureEvents
            if dinky_is_gesture_event(event) { maintainStream() }
            return swallow ? nil : pass
        }
        if phase == .cancelled { session.cancel() }
        let valid = phase == .began || session.validate(snapshot())
        let step = tracker.handle(phase, Int(way), valid: valid,
                                  start: { begin(at: event.location, vertical: vertical) },
                                  claim: { claim($0) })
        if let way = step.switchSpace, let token = session.token {
            deferAction(token) { [context] in context.switchToNeighbor(token, way) }
        }
        maintainStream()
        return step.verdict == .pass ? pass : nil
    }

    private func snapshot() -> SwipeSession.Snapshot? {
        guard config.enabled, enabled, let token = session.token else { return nil }
        return context.snapshot(token)
    }

    private func begin(at point: CGPoint, vertical: Bool) -> SpaceSwitch? {
        session.cancel()
        self.vertical = vertical
        guard config.enabled, enabled, !vertical || config.vertical,
              let snapshot = context.begin(point, vertical), snapshot.enabled,
              !snapshot.missionControl, !snapshot.switching else { return nil }
        session.begin(display: snapshot.display, space: snapshot.space)
        return vertical || !context.canSuppress() ? .native : config.spaceSwitch
    }

    private func claim(_ way: Int) -> Bool {
        guard session.validate(snapshot()), let token = session.token,
              let action = context.focus(token, swipeDirection(way, vertical: vertical)) else { return false }
        deferAction(token, action)
        return true
    }

    private func deferAction(_ token: SwipeSession.Token, _ action: @escaping () -> Void) {
        enqueue { [weak self] in
            guard let self, self.session.accepts(token, self.snapshot()) else { return }
            action()
        }
    }
}

private func swipeDirection(_ way: Int, vertical: Bool) -> Direction {
    vertical ? (way > 0 ? .down : .up) : (way > 0 ? .right : .left)
}

extension SwipeFocus.Context {
    static let live = Self(
        canSuppress: { dinky_can_suppress_dock_swipe() },
        begin: { point, vertical in
            guard AppState.shared.enabled, !MissionControl.shared.active,
                  let display = AppState.shared.displays.displays.first(where: { $0.frame.contains(point) }),
                  SpaceSwitcher.shared.target(on: display.uuid) == nil,
                  dinky_current_space_id(display.uuid as CFString) == display.currentSpaceID,
                  let workspace = AppState.shared.coordinator?.workspace(on: display),
                  [-1, 1].contains(where: { workspace.swipeTarget(swipeDirection($0, vertical: vertical)) != nil }) else { return nil }
            return .init(display: display.uuid, space: display.currentSpaceID)
        },
        snapshot: { token in
            guard AppState.shared.displays.displays.contains(where: { $0.uuid == token.display }) else { return nil }
            return .init(display: token.display, space: dinky_current_space_id(token.display as CFString),
                         switching: SpaceSwitcher.shared.target(on: token.display) != nil,
                         enabled: AppState.shared.enabled, missionControl: MissionControl.shared.active)
        },
        focus: { token, direction in
            guard let coordinator = AppState.shared.coordinator,
                  let from = coordinator.workspaces[token.space]?.focused,
                  coordinator.swipeTarget(on: token.space, from: from, direction: direction) != nil else { return nil }
            return { [weak coordinator] in
                guard let coordinator,
                      let id = coordinator.swipeTarget(on: token.space, from: from, direction: direction),
                      let focused = coordinator.command(on: from, { $0.focus(id); return $0.focused }) ?? nil else { return }
                coordinator.focus(focused)
            }
        },
        switchToNeighbor: { token, way in
            guard let display = AppState.shared.displays.displays.first(where: { $0.uuid == token.display }),
                  let index = display.spaces.firstIndex(of: token.space),
                  display.spaces.indices.contains(index + way) else { return }
            switchSpace(toSpaceID: display.spaces[index + way], on: display)
        }
    )
}

/// Transport only. Injection lets lifecycle tests use the actual handler without installing a system tap.
protocol SwipeEvents: AnyObject {
    func start(_ receive: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) -> Bool
    func stop()
    func reenable()
}

private final class DockSwipeEvents: SwipeEvents {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate var receive: ((CGEventType, CGEvent) -> Unmanaged<CGEvent>?)?

    deinit { stop() }

    func start(_ receive: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) -> Bool {
        self.receive = receive
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: dinky_dock_swipe_event_mask(), callback: swipeCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            fputs("swipe: could not create event tap (Accessibility?)\n", stderr)
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        reenable()
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
        (self.tap, source) = (nil, nil)
        receive = nil
    }

    func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

private func swipeCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                           refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon,
          let receive = Unmanaged<DockSwipeEvents>.fromOpaque(refcon).takeUnretainedValue().receive else {
        return Unmanaged.passUnretained(event)
    }
    return receive(type, event)
}

/// Identity and lifetime of a gesture, including its queued action. A new begin or config update supersedes it.
struct SwipeSession {
    struct Token: Equatable {
        let generation: UInt64
        let display: String
        let space: UInt64
    }
    struct Snapshot {
        let display: String
        let space: UInt64
        var switching = false
        var enabled = true
        var missionControl = false
    }
    private var generation: UInt64 = 0
    private(set) var token: Token?

    mutating func cancel() { generation &+= 1; token = nil }
    mutating func begin(display: String, space: UInt64) {
        cancel()
        token = Token(generation: generation, display: display, space: space)
    }
    mutating func validate(_ snapshot: Snapshot?) -> Bool {
        guard let token, accepts(token, snapshot) else { cancel(); return false }
        return true
    }
    func accepts(_ expected: Token, _ snapshot: Snapshot?) -> Bool {
        guard token == expected, let snapshot else { return false }
        return snapshot.display == expected.display && snapshot.space == expected.space
            && !snapshot.switching && snapshot.enabled && !snapshot.missionControl
    }
}

/// One claim per gesture. Instant mode owns the entire stream; native mode never suppresses any part of it.
struct SwipeTracker {
    enum Verdict: Equatable { case pass, swallow }
    private enum State { case idle, dock, undecided, claimed, pastEdge(Int), cancelled }
    private var state = State.idle
    private var native = true
    var passesGestureEvents: Bool { native || isIdle }
    var ownsStream: Bool { !native && !isIdle }
    var isDraining: Bool { if case .cancelled = state { return ownsStream }; return false }
    private var isIdle: Bool { if case .idle = state { return true }; return false }

    mutating func cancel() {
        if !isIdle { state = .cancelled }
    }

    mutating func handle(_ phase: DinkySwipePhase, _ way: Int, valid: Bool = true,
                         start: () -> SpaceSwitch?, claim: (Int) -> Bool) -> (verdict: Verdict, switchSpace: Int?) {
        if phase == .began {
            let mode = start()
            native = mode != .instant
            state = mode == nil ? .dock : .undecided
        } else if !valid || phase == .cancelled {
            state = isIdle ? .idle : .cancelled
        } else if case .undecided = state, way != 0 {
            state = claim(way) ? .claimed : native ? .dock : .pastEdge(way)
        }
        let verdict: Verdict = native || isIdle ? .pass : .swallow
        var switchSpace: Int?
        if phase == .ended, case .pastEdge(let way) = state { switchSpace = way }
        if phase == .ended || phase == .cancelled { state = .idle }
        return (verdict, switchSpace)
    }
}
