import AppKit
import DinkyPrivate

// Switching a display's Space with mimi's swipe. Shared by the app, the dispatcher and the activation follower.

/// Nanoseconds since boot, not counting sleep.
func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// The time of day to the millisecond, to prefix log lines whose timing matters.
func stamp() -> String {
    let now = Date()
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: now)
}

/// Swipes the display to one of its Spaces, full-screen ones included. False if it is already there.
/// Returns once the swipe is posted; `SpaceSwitcher` confirms it and coalesces rapid requests. `landed` runs
/// once the display is on the Space, unless a newer request replaced this one first.
@discardableResult
func switchSpace(toSpaceID target: UInt64, on display: Display, landed: (() -> Void)? = nil) -> Bool {
    SpaceSwitcher.shared.request(target, on: display.uuid, landed: landed)
}

/// The Space the display is on, or is switching to while a switch is in flight.
func targetSpaceID(on display: Display) -> UInt64 {
    SpaceSwitcher.shared.destination(on: display.uuid) ?? display.currentSpaceID
}

// Native movement is not cancellable. Keep its ownership until WindowServer acknowledges the posted
// destination, even after giving up the logical request. New requests only replace the queued target.
final class SpaceSwitcher {
    static let shared = SpaceSwitcher()

    private struct Request {
        let target: UInt64
        let landed: (() -> Void)?
        let startedAt: UInt64
    }

    private struct Flight {
        var request: Request?
        var posted: UInt64?
        var postedAt: UInt64 = 0
        var dockProcess: pid_t?
    }

    private let currentSpace: (String) -> UInt64
    private let dockProcess: () -> pid_t?
    private let spaceIDs: (String) -> [UInt64]
    private let swipe: (Int32, Int32, String) -> Bool
    private let clock: () -> UInt64
    private let pollAutomatically: Bool
    private let batchMovement: Bool
    private var flights: [String: Flight] = [:]
    private var timer: Timer?
    // Cursor warping pumps the run loop. Neither polls nor reentrant requests may post inside a post.
    private var posting = false
    // Preserve the old two-second give-up budget, without treating it as native cancellation.
    private let requestTimeout: UInt64 = 2_000_000_000

    /// Starts and retargets logical requests; intermediate native steps do not announce new targets.
    var onTarget: ((String, UInt64) -> Void)?
    /// Logical completion, including give-up. Outstanding native movement remains owned after give-up.
    var onSettled: ((String) -> Void)?

    init(currentSpace: @escaping (String) -> UInt64 = { dinky_current_space_id($0 as CFString) },
         spaceIDs: @escaping (String) -> [UInt64] = { uuid in
             dinky_displays().first { $0.uuid == uuid }?.spaces.map(\.spaceID) ?? []
         },
         swipe: @escaping (Int32, Int32, String) -> Bool = { from, to, uuid in
             noteOwnSwitch()
             return dinky_switch_to_space_index(from, to, uuid as CFString)
         },
         clock: @escaping () -> UInt64 = uptime, pollAutomatically: Bool = true,
         batchMovement: Bool = dinky_can_batch_space_swipes(),
         dockProcess: @escaping () -> pid_t? = {
             NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
         }) {
        self.currentSpace = currentSpace
        self.dockProcess = dockProcess
        self.spaceIDs = spaceIDs
        self.swipe = swipe
        self.clock = clock
        self.pollAutomatically = pollAutomatically
        self.batchMovement = batchMovement
    }

    /// The logical target; nil after give-up so workspace hooks can settle the failed request.
    func target(on uuid: String) -> UInt64? { flights[uuid]?.request?.target }

    /// Where the display is still headed, including a late native landing after logical give-up.
    /// Command resolution must not mistake the currently observed Space for a settled destination.
    func destination(on uuid: String) -> UInt64? { target(on: uuid) ?? flights[uuid]?.posted }

    /// Includes unacknowledged native movement whose logical request has timed out.
    var switching: Bool { !flights.isEmpty }

    func request(_ target: UInt64, on uuid: String, landed: (() -> Void)? = nil) -> Bool {
        let previous = flights[uuid]?.request?.target
        if flights[uuid] == nil {
            guard currentSpace(uuid) != target else { return false }
            flights[uuid] = Flight()
        }
        flights[uuid]!.request = Request(target: target, landed: landed, startedAt: clock())
        if previous != target { onTarget?(uuid, target) }
        if !posting, flights[uuid]?.posted == nil { post(on: uuid) }
        startPolling()
        return true
    }

    private func post(on uuid: String) {
        guard var flight = flights[uuid], flight.posted == nil, let request = flight.request else { return }
        let spaces = spaceIDs(uuid)
        let current = currentSpace(uuid)
        guard let from = spaces.firstIndex(of: current), let target = spaces.firstIndex(of: request.target) else {
            return finish(uuid, "switch: Space \(request.target) is not on display \(uuid)")
        }
        guard from != target else { return finish(uuid, "switch: display \(uuid) reached Space \(current)", landed: true) }
        // Augmented gestures retain their fast, final-only redraw. Legacy gestures acknowledge each
        // adjacent landing; neither form may replay or retarget its outstanding native movement.
        let to = batchMovement ? target : from + (target > from ? 1 : -1)
        flight.posted = spaces[to]
        flight.postedAt = clock()
        flight.dockProcess = dockProcess()
        flights[uuid] = flight
        posting = true
        let ok = swipe(Int32(from + 1), Int32(to + 1), uuid)
        posting = false
        if !ok { finish(uuid, "switch: posting the swipe to Space \(to + 1) failed") }
    }

    func poll() {
        guard !posting else { return }
        // A native post pumps the run loop, so read each flight afresh.
        let dock = dockProcess()
        for uuid in Array(flights.keys) {
            guard var flight = flights[uuid] else { continue }
            if let posted = flight.posted {
                // A native endpoint is meaningful only in the context it was posted into. Never carry
                // its relative intent over to replacement Spaces, a reconnected display or a new Dock.
                // This invalidates the request, rather than claiming the old movement succeeded.
                guard dock == flight.dockProcess, spaceIDs(uuid).contains(posted) else {
                    finish(uuid, "switch: native context changed while waiting for Space \(posted) on display \(uuid)")
                    continue
                }
            }
            if let posted = flight.posted, currentSpace(uuid) == posted {
                flight.posted = nil
                flights[uuid] = flight
            }
            if flight.posted == nil {
                if flight.request == nil {
                    flights.removeValue(forKey: uuid) // late acknowledgment of an abandoned request
                } else {
                    post(on: uuid)
                }
            } else if let posted = flight.posted, let request = flight.request,
                      clock() - max(flight.postedAt, request.startedAt) > requestTimeout {
                // A timeout cannot revoke an event already sent to Dock. Retire only the logical request;
                // keep the pending destination, so neither a new request nor a late landing can replay it.
                flights[uuid]!.request = nil
                fputs("\(stamp()) switch: gave up on Space \(request.target); waiting for pending Space \(posted) on display \(uuid)\n", stderr)
                onSettled?(uuid)
            }
        }
        if flights.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func finish(_ uuid: String, _ message: String, landed: Bool = false) {
        guard let flight = flights.removeValue(forKey: uuid) else { return }
        print("\(stamp()) \(message)")
        fflush(stdout)
        if flight.request != nil { onSettled?(uuid) }
        if landed { flight.request?.landed?() }
    }

    private func startPolling() {
        guard pollAutomatically, timer == nil, !flights.isEmpty else { return }
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
