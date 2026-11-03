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
    SpaceSwitcher.shared.target(on: display.uuid) ?? display.currentSpaceID
}

// One switch in flight per display. A request while one is in flight only replaces its target: once the
// posted swipe lands, the display goes on to the newest target from wherever it is, so a burst of requests
// never replays obsolete swipes. Landing is observed with `dinky_current_space_id`, not assumed; a swipe
// that has not landed after `timeout` is posted once more, then reported and dropped.
final class SpaceSwitcher {
    static let shared = SpaceSwitcher()

    private struct Flight {
        var target: UInt64      // the newest request
        var posted: UInt64 = 0  // what the last swipe went for
        var postedAt: UInt64 = 0
        var retried = false
        var landed: (() -> Void)?
        let startedAt: UInt64
    }

    private let currentSpace: (String) -> UInt64
    private let spaceIDs: (String) -> [UInt64]
    private let swipe: (Int32, Int32, String) -> Bool
    private let clock: () -> UInt64
    private let pollAutomatically: Bool
    private var flights: [String: Flight] = [:]
    private var timer: Timer?
    // The mimi path pumps the run loop between steps; the poll and new requests must not post meanwhile.
    private var posting = false
    private let timeout: UInt64 = 1_000_000_000

    /// Called with the display UUID and the target when a switch starts, and when a new request retargets one.
    var onTarget: ((String, UInt64) -> Void)?
    /// Called after removing a finished flight, on success and every failure/cancellation path alike.
    var onSettled: ((String) -> Void)?

    init(currentSpace: @escaping (String) -> UInt64 = { dinky_current_space_id($0 as CFString) },
         spaceIDs: @escaping (String) -> [UInt64] = { uuid in
             dinky_displays().first { $0.uuid == uuid }?.spaces.map(\.spaceID) ?? []
         },
         swipe: @escaping (Int32, Int32, String) -> Bool = { from, to, uuid in
             noteOwnSwitch()
             return dinky_switch_to_space_index(from, to, uuid as CFString)
         },
         clock: @escaping () -> UInt64 = uptime, pollAutomatically: Bool = true) {
        self.currentSpace = currentSpace
        self.spaceIDs = spaceIDs
        self.swipe = swipe
        self.clock = clock
        self.pollAutomatically = pollAutomatically
    }

    func target(on uuid: String) -> UInt64? { flights[uuid]?.target }

    /// Whether any display has a switch in flight.
    var switching: Bool { !flights.isEmpty }

    func request(_ target: UInt64, on uuid: String, landed: (() -> Void)? = nil) -> Bool {
        if let flight = flights[uuid] {
            flights[uuid]!.target = target
            flights[uuid]!.retried = false
            flights[uuid]!.landed = landed
            if flight.target != target { onTarget?(uuid, target) }
            return true
        }
        guard currentSpace(uuid) != target else { return false }
        flights[uuid] = Flight(target: target, landed: landed, startedAt: clock())
        onTarget?(uuid, target)
        if !posting { post(on: uuid) }
        startPolling()
        return true
    }

    /// Posts a swipe from the display's observed Space to the flight's target. Drops the flight if it can't.
    private func post(on uuid: String) {
        guard var flight = flights[uuid] else { return }
        let spaces = spaceIDs(uuid)
        let current = currentSpace(uuid)
        guard let from = spaces.firstIndex(of: current), let to = spaces.firstIndex(of: flight.target) else {
            return finish(uuid, "switch: Space \(flight.target) is not on display \(uuid)")
        }
        flight.posted = flight.target
        flight.postedAt = clock()
        flights[uuid] = flight
        posting = true
        let ok = swipe(Int32(from + 1), Int32(to + 1), uuid)
        posting = false
        if !ok { finish(uuid, "switch: posting the swipe to Space \(to + 1) failed") }
    }

    func poll() {
        guard !posting else { return }
        // Posting a swipe can pump the run loop, where a request may retarget another display's flight, so
        // each flight is read afresh rather than from a copy taken before the loop.
        for uuid in Array(flights.keys) {
            guard let flight = flights[uuid] else { continue }
            let observed = currentSpace(uuid)
            let ms = Double(clock() - flight.startedAt) / 1_000_000
            if flight.posted == 0 {
                post(on: uuid)  // requested while another display's swipe was being posted
            } else if observed == flight.posted, observed == flight.target {
                finish(uuid, String(format: "switch: landed on Space %llu in %.0f ms", observed, ms), landed: true)
            } else if observed == flight.posted {
                post(on: uuid)  // landed on an older request; go on to the newest
            } else if clock() - flight.postedAt > timeout {
                // The posted swipe did not land. Waiting for it first means it can't land late, after this.
                if observed == flight.target {
                    finish(uuid, String(format: "switch: on Space %llu after %.0f ms", observed, ms), landed: true)
                } else if flight.retried {
                    finish(uuid, "switch: gave up on Space \(flight.target), display is on Space \(observed)", error: true)
                } else {
                    flights[uuid]!.retried = true
                    post(on: uuid)
                }
            }
        }
        if flights.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func finish(_ uuid: String, _ message: String, error: Bool = false, landed: Bool = false) {
        guard let flight = flights.removeValue(forKey: uuid) else { return }
        if error { fputs("\(stamp()) \(message)\n", stderr) } else { print("\(stamp()) \(message)") }
        fflush(stdout)
        onSettled?(uuid)
        if landed { flight.landed?() }
    }

    private func startPolling() {
        guard pollAutomatically, timer == nil, !flights.isEmpty else { return }
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
