import AppKit
import Testing
import DinkyConfig
import DinkyLayout
import DinkyPrivate
@testable import dinky

struct SwipeTrackerTests {
    @Test func instantClaimsOnceAndSuppressesWholeStream() {
        var tracker = SwipeTracker(), claims = 0
        for phase: DinkySwipePhase in [.began, .changed, .changed, .ended] {
            let step = tracker.handle(phase, 1, start: { .instant }, claim: { _ in claims += 1; return true })
            #expect(step.verdict == .swallow)
            #expect(step.switchSpace == nil)
        }
        #expect(claims == 1)
        #expect(tracker.passesGestureEvents)
    }

    @Test func nativeNeverSuppressesEvenAfterClaim() {
        var tracker = SwipeTracker(), claims = 0
        for phase: DinkySwipePhase in [.began, .changed, .changed, .ended] {
            let step = tracker.handle(phase, -1, start: { .native }, claim: { _ in claims += 1; return true })
            #expect(step.verdict == .pass)
            #expect(step.switchSpace == nil)
            #expect(tracker.passesGestureEvents)
        }
        #expect(claims == 1)
    }

    @Test func pastEdgeSwitchesOnlyOnEnd() {
        var tracker = SwipeTracker()
        #expect(tracker.handle(.began, 0, start: { .instant }, claim: { _ in false }).switchSpace == nil)
        #expect(tracker.handle(.changed, -1, start: { nil }, claim: { _ in false }).switchSpace == nil)
        #expect(tracker.handle(.ended, 1, start: { nil }, claim: { _ in false }).switchSpace == -1)
    }

    @Test func cancelledFlickDoesNotClaim() {
        var tracker = SwipeTracker(), claims = 0
        _ = tracker.handle(.began, 0, start: { .instant }, claim: { _ in true })
        let step = tracker.handle(.cancelled, 1, start: { nil }, claim: { _ in claims += 1; return true })
        #expect(claims == 0)
        #expect(step.switchSpace == nil)
    }

    @Test func staleGestureCannotClaimOrSwitchEvenIfValidityReturns() {
        var tracker = SwipeTracker(), claims = 0
        _ = tracker.handle(.began, 0, start: { .instant }, claim: { _ in true })
        _ = tracker.handle(.changed, 1, valid: false, start: { nil }, claim: { _ in claims += 1; return false })
        let step = tracker.handle(.ended, 1, start: { nil }, claim: { _ in claims += 1; return false })
        #expect(claims == 0)
        #expect(step.switchSpace == nil)
        #expect(step.verdict == .swallow) // Do not leak half an instant gesture to the Dock.
    }

    @Test func transitionAfterPastEdgeCancelsSwitch() {
        var tracker = SwipeTracker()
        _ = tracker.handle(.began, 0, start: { .instant }, claim: { _ in false })
        _ = tracker.handle(.changed, 1, start: { nil }, claim: { _ in false })
        #expect(tracker.handle(.ended, 1, valid: false, start: { nil }, claim: { _ in false }).switchSpace == nil)
    }

    @Test func missedBeginAndIneligibleWorkspacePassThrough() {
        var tracker = SwipeTracker()
        for phase: DinkySwipePhase in [.changed, .ended, .began, .changed, .ended] {
            let step = tracker.handle(phase, 1, start: { nil }, claim: { _ in Issue.record("must not claim"); return true })
            #expect(step.verdict == .pass)
        }
    }

    @Test func endOnlyVelocityCanClaimAndNewBeginResetsOwnership() {
        var tracker = SwipeTracker(), claims = 0
        _ = tracker.handle(.began, 0, start: { .instant }, claim: { _ in false })
        _ = tracker.handle(.ended, 1, start: { nil }, claim: { _ in claims += 1; return true })
        #expect(claims == 1)
        #expect(tracker.handle(.began, 0, start: { nil }, claim: { _ in false }).verdict == .pass)
    }
}

struct SwipeSessionTests {
    @Test func spaceLandingBetweenEventsInvalidatesCapturedDisplay() throws {
        var session = SwipeSession()
        session.begin(display: "A", space: 10)
        let queued = try #require(session.token)
        let before = session.validate(.init(display: "A", space: 10))
        let after = session.validate(.init(display: "A", space: 11))
        #expect(before)
        #expect(!after)
        let accepts = session.accepts(queued, .init(display: "A", space: 10))
        #expect(!accepts)
    }

    @Test func deferredActionRechecksEnabledMissionControlAndDisplayRemoval() throws {
        var session = SwipeSession()
        session.begin(display: "A", space: 10)
        let queued = try #require(session.token)
        // The runtime supplies live enabled/Mission Control state, or nil when the display disappears.
        let results = [
            session.accepts(queued, nil),
            session.accepts(queued, .init(display: "B", space: 10)),
            session.accepts(queued, .init(display: "A", space: 11)),
            session.accepts(queued, .init(display: "A", space: 10, switching: true)),
            session.accepts(queued, .init(display: "A", space: 10, enabled: false)),
            session.accepts(queued, .init(display: "A", space: 10, missionControl: true)),
            session.accepts(queued, .init(display: "A", space: 10)),
        ]
        #expect(results == [false, false, false, false, false, false, true])
    }

    @Test func rapidGestureAndConfigReloadSupersedeQueuedActions() throws {
        var session = SwipeSession()
        session.begin(display: "A", space: 10)
        let old = try #require(session.token)
        session.begin(display: "A", space: 10)
        let new = try #require(session.token)
        let oldAccepted = session.accepts(old, .init(display: "A", space: 10))
        let newAccepted = session.accepts(new, .init(display: "A", space: 10))
        #expect(!oldAccepted)
        #expect(newAccepted)
        session.cancel()
        let afterCancel = session.accepts(new, .init(display: "A", space: 10))
        #expect(!afterCancel)
    }
}

struct SwipeCoordinatorTests {
    private func coordinator() -> Coordinator {
        // No start(), subscriptions, AX calls, frame writes or global AppState.
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("dinky-swipe-\(UUID())")
        let coordinator = Coordinator(displays: DisplayModel(), config: Config(), applier: FrameApplier(supportURL: support))
        var workspace = Workspace(bounds: CGRect(x: 0, y: 0, width: 1000, height: 600), algorithm: .scrolling)
        workspace.insert(1); workspace.insert(2); workspace.focus(1)
        coordinator.workspaces[10] = workspace
        coordinator.placements[1] = Placement(floating: false, space: 10)
        coordinator.placements[2] = Placement(floating: false, space: 10)
        return coordinator
    }

    @Test func queuedSwipeDoesNotFollowWindowToAnotherSpace() {
        let coordinator = coordinator()
        #expect(coordinator.swipeTarget(on: 10, from: 1, direction: .right) == 2)
        coordinator.placements[1]?.space = 11
        #expect(coordinator.swipeTarget(on: 10, from: 1, direction: .right) == nil)
        coordinator.placements[1]?.space = 10
        coordinator.placements[2]?.space = 11
        #expect(coordinator.swipeTarget(on: 10, from: 1, direction: .right) == nil)
    }

    @Test func queuedSwipeDoesNotOverrideNewFocusOrRemovedTile() {
        let coordinator = coordinator()
        coordinator.edit(10) { $0.focus(2) }
        #expect(coordinator.swipeTarget(on: 10, from: 1, direction: .right) == nil)
        coordinator.edit(10) { $0.focus(1); $0.remove(2) }
        #expect(coordinator.swipeTarget(on: 10, from: 1, direction: .right) == nil)
    }
}

struct SwipeEventReaderTests {
    private func event(motion: Int64 = 1, phase: Int64 = 2, progress: Double = 0) -> CGEvent {
        let event = CGEvent(source: nil)!
        for (field, value) in [(55, Int64(30)), (110, 23), (123, motion), (132, phase)] {
            event.setIntegerValueField(CGEventField(rawValue: UInt32(field))!, value: value)
        }
        event.setDoubleValueField(CGEventField(rawValue: 124)!, value: progress)
        return event
    }
    private func read(_ event: CGEvent) -> (Bool, DinkySwipePhase, Bool, Int32) {
        var phase = DinkySwipePhase.began, vertical = false, way: Int32 = 0
        let read = dinky_read_dock_swipe(event, &phase, &vertical, &way)
        return (read, phase, vertical, way)
    }

    @Test func validatesTypeMotionAndPhase() {
        #expect(read(event(motion: 3)).0 == false)
        #expect(read(event(phase: 0)).0 == false)
        #expect(read(event(phase: 16)).0 == false)
        let wrongType = event()
        wrongType.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)
        #expect(!read(wrongType).0)
        #expect(dinky_is_gesture_event(wrongType))
        for phase: Int64 in [1, 2, 4, 8] { #expect(read(event(phase: phase)).0) }
    }

    @Test func progressAndEndVelocityUseAxisAndOppositeSigns() {
        let positive = read(event(progress: 0.5))
        let negative = read(event(progress: -0.5))
        #expect(positive.3 != 0 && positive.3 == -negative.3)
        #expect(read(event(motion: 2, progress: 0.5)).3 == -positive.3)
        let flick = event(phase: 4)
        flick.setDoubleValueField(CGEventField(rawValue: 129)!, value: 500)
        #expect(read(flick).3 == positive.3)
        let vertical = event(motion: 2, phase: 4)
        vertical.setDoubleValueField(CGEventField(rawValue: 130)!, value: 500)
        #expect(read(vertical).3 == -positive.3)
        #expect(read(event()).3 == 0)
    }

    @Test func syntheticIdentityIsPerEventAndSurvivesSerialization() throws {
        let synthetic = event(progress: 1)
        synthetic.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        let tag = (Int64(0x44494E4B) << 32) | Int64(getpid())
        synthetic.setIntegerValueField(.eventSourceUserData, value: tag)
        let physical = event(progress: 1)
        physical.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        #expect(dinky_is_own_dock_swipe(synthetic))
        #expect(!dinky_is_own_dock_swipe(physical))
        #expect(dinky_is_own_dock_swipe(synthetic))
        let data = try #require(synthetic.data)
        let copy = try #require(CGEvent(withDataAllocator: nil, data: data))
        #expect(dinky_is_own_dock_swipe(copy))
        #expect(!dinky_is_own_dock_swipe(physical))
        synthetic.setIntegerValueField(.eventSourceUserData, value: 0)
        synthetic.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
        #expect(dinky_is_own_dock_swipe(synthetic)) // Source-PID fallback, independent of the tag.
    }

    @Test func suppressionIsUnavailableWithIOHIDPayload() {
        #expect(dinky_can_suppress_dock_swipe() == (ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27))
    }
}
