import AppKit
import DinkyConfig
import DinkyPrivate

// Workspace numbers: which native Space each workspace is. Workspaces are numbered across displays and live
// where `[workspace-to-display]` puts them, else on the main display. `arrange()` makes the Spaces match: it
// runs `WorkspacePlan`'s steps (create a Space, move a Space's windows, remove an empty Space) until there are
// none left. It runs at launch, on config reload, and a moment after displays or Spaces come and go. Between
// runs a workspace stays on its Space by ID, wherever macOS moves that Space, unless `follow-space-order` is on:
// then reordering a display's Spaces renumbers its workspaces to match, and windows stay put.
// A display that goes away has macOS pour the windows of its Spaces onto another display's first Space, which
// is workspace 1's. So the workspace of every window is noted while the displays are settled, and once the
// Spaces are arranged after a display change, windows found off their workspace go back to it, unless dinky
// was disabled at the time (`DisplacedWindows`). Main thread only.
final class WorkspaceNumbers {
    /// Workspace number to Space.
    private(set) var binding: [Int: UInt64] = [:]
    private var observers: [() -> Void] = []
    /// Called at the end of every arrangement, once the coordinator has re-read the windows.
    var onArranged: (() -> Void)?
    /// Called when `follow-space-order` renumbers, before observers hear of it, with the UUIDs of the displays
    /// whose workspaces changed number.
    var onRenumbered: ((Set<String>) -> Void)?
    private var pending: DispatchWorkItem?
    private var arranging = false
    /// Spaces this removed, whose `spaceDestroyed` events are not news.
    private var removed: Set<UInt64> = []
    /// The workspace each window was on while the displays were settled. See `noteHomes()`.
    private var homes: [UInt32: Int] = [:]
    /// The last note of homes, kept only if the displays are still the same at the next one.
    private var pendingHomes: [UInt32: Int]?
    /// The displays as the last display change left them.
    private var knownDisplays: Set<String> = []
    /// Whether windows a display change moved go back after the next arrangement, and only then: returning
    /// them after a later run, such as a config reload long after, would undo whatever the user moved since.
    private var displaced = DisplacedWindows()

    var count: Int { AppState.shared.config.workspaces }

    func space(of n: Int) -> UInt64? { binding[n] }
    func number(of space: UInt64) -> Int? { binding.first { $0.value == space }?.key }
    /// The workspaces on a display, in number order.
    func workspaces(on display: Display) -> [Int] { binding.filter { display.userSpaces.contains($0.value) }.keys.sorted() }
    /// The display's current workspace, nil on a Space that is none (full-screen, or a display without any).
    func current(on display: Display) -> Int? { number(of: display.currentSpaceID) }
    /// "3", or "" off the numbered workspaces, as hooks and logs print it.
    func label(of space: UInt64) -> String { number(of: space).map { "\($0)" } ?? "" }

    /// Calls `handler` whenever the numbering changes.
    func observe(_ handler: @escaping () -> Void) { observers.append(handler) }

    /// Starts following display and Space changes. Call once, after the first `arrange()`.
    func start() {
        let model = AppState.shared.displays
        knownDisplays = Set(model.displays.map(\.uuid))
        var main = model.displays.first(where: \.isMain)?.uuid
        // A display coming or going, or another becoming main, moves workspaces. The same displays may have had
        // their Spaces reordered.
        model.observe { [weak self] model in
            guard let self else { return }
            let now = Set(model.displays.map(\.uuid))
            let nowMain = model.displays.first(where: \.isMain)?.uuid
            guard now != knownDisplays || nowMain != main else { return followSpaceOrder(model) }
            let (connected, disconnected) = (now.subtracting(knownDisplays), knownDisplays.subtracting(now))
            (knownDisplays, main) = (now, nowMain)
            if !connected.isEmpty { print("displays: connected \(connected.sorted())") }
            if !disconnected.isEmpty { print("displays: disconnected \(disconnected.sorted())") }
            fflush(stdout)
            if !connected.isEmpty || !disconnected.isEmpty { displaced.displaysChanged() }
            arrangeSoon()
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.noteHomes() }
        // A Space removed in Mission Control leaves its workspace without one.
        EventHub.shared.subscribe { [weak self] event in
            guard let self, event.kind == .spaceDestroyed, !arranging, removed.remove(event.spaceID) == nil else { return }
            arrangeSoon()
        }
    }

    /// Arranges once things have been quiet for `delay` seconds: the Spaces of a display that just came or went
    /// take a moment to settle in WindowServer, and docking changes several displays in a row.
    func arrangeSoon(after delay: Double = 1) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.arrange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Runs the plan's steps until the Spaces match the config. Blocks the main thread while it works; each step
    /// waits for WindowServer to show its result, normally within a poll or two. While dinky is disabled it only
    /// numbers the Spaces as they are, leaving Spaces and windows alone; enabling arranges.
    func arrange() {
        guard AppState.shared.enabled else {
            // Windows stay where macOS put them, and homes are noted again from here.
            if displaced.arranged(enabled: false, completed: false) == .leaveThem {
                print("workspaces: windows a display change moved while dinky was disabled stay where they are")
            }
            return numberInPlace()
        }
        guard !arranging else { return }
        // A swipe in flight would land on a Space this may remove.
        guard !SpaceSwitcher.shared.switching else { return arrangeSoon(after: 0.3) }
        arranging = true
        defer { arranging = false }
        let model = AppState.shared.displays
        let plan = WorkspacePlan(AppState.shared.config)
        let start = binding
        // The plan forgets a workspace whose Space is not listed. One that is only between displays, listed by
        // WindowServer while CoreGraphics already calls its display offline, gets a moment to reappear.
        func unlisted() -> Bool {
            model.reconcile()
            return !Set(binding.values).isSubset(of: model.displays.flatMap(\.userSpaces))
        }
        if unlisted() { _ = waitUntil(2) { !unlisted() } }
        // Following the Space order, Spaces reordered since the last run are renumbered rather than put back.
        if AppState.shared.config.followSpaceOrder { binding = plan.renumbered(planDisplays(), binding: binding) }
        var completed = false
        for _ in 0..<50 {
            let displays = planDisplays()
            guard !displays.isEmpty else { break }
            let occupied = occupiedSpaces(among: displays.flatMap(\.spaces))
            let before = binding
            let step = plan.step(displays, binding: binding, occupied: occupied)
            binding = step.binding
            guard let action = step.action else {
                completed = true
                break
            }
            guard perform(action) else {
                // A workspace whose windows did not all move stays where they are, so the next run moves it again.
                if case .move = action { binding = before }
                print("workspaces: stopped; the next display change or config reload tries again")
                break
            }
        }
        switch displaced.arranged(enabled: true, completed: completed) {
        case .returnThem: returnDisplaced()
        case .leaveThem: print("workspaces: windows a display change moved off their workspace stay where they are")
        case .nothing: break
        }
        // Observers hear the result once, not every step on the way.
        announce(since: start)
        fflush(stdout)
        AppState.shared.coordinator?.reconcile()
        onArranged?()
    }

    /// Numbers the Spaces as they stand, taking one plan step without carrying it out, so `workspace <n>`, the
    /// status item and hooks have a numbering while disabled: after a display change the old binding names Spaces
    /// that are gone, and started disabled there is none. A workspace the step would move stays on the Space its
    /// windows are on; one it would create stays unbound until enabling creates it.
    private func numberInPlace() {
        let displays = planDisplays()
        let start = binding
        let plan = WorkspacePlan(AppState.shared.config)
        if AppState.shared.config.followSpaceOrder { binding = plan.renumbered(displays, binding: binding) }
        let step = plan.step(displays, binding: binding, occupied: occupiedSpaces(among: displays.flatMap(\.spaces)))
        binding = step.binding
        if case .move(let from, let to) = step.action, let n = binding.first(where: { $0.value == to })?.key {
            binding[n] = from
        }
        announce(since: start)
        fflush(stdout)
        onArranged?()
    }

    /// With `follow-space-order`, renumbers the workspaces to the order their Spaces now have, after a drag in
    /// Mission Control or macOS rearranging them. Only the numbers change; windows stay on their Spaces.
    private func followSpaceOrder(_ model: DisplayModel) {
        guard AppState.shared.config.followSpaceOrder, !arranging else { return }
        let start = binding
        binding = WorkspacePlan(AppState.shared.config).renumbered(planDisplays(model), binding: binding)
        guard binding != start else { return }
        print("workspaces: renumbered to follow the Space order")
        let moved = Set(binding.filter { start[$0.key] != $0.value }.values)
        onRenumbered?(Set(model.displays.filter { $0.userSpaces.contains(where: moved.contains) }.map(\.uuid)))
        announce(since: start)
        fflush(stdout)
        // Layout settings go by workspace number, so each Space's are resolved again.
        if AppState.shared.enabled { AppState.shared.coordinator?.reconcile() }
    }

    /// The displays as the plan sees them, read afresh.
    private func planDisplays() -> [PlanDisplay] {
        let model = AppState.shared.displays
        model.reconcile()
        return planDisplays(model)
    }

    /// The displays as the model last read them.
    private func planDisplays(_ model: DisplayModel) -> [PlanDisplay] {
        model.displays.map {
            PlanDisplay(uuid: $0.uuid, monitor: model.monitor($0), spaces: $0.userSpaces, current: $0.currentSpaceID)
        }
    }

    /// Logs the numbering and tells observers, if it changed since `start`.
    private func announce(since start: [Int: UInt64]) {
        guard binding != start else { return }
        print("workspaces: " + binding.keys.sorted().map { "\($0)=\(binding[$0]!)" }.joined(separator: " "))
        observers.forEach { $0() }
    }

    /// The displays connected now, as WindowServer lists them. The display model hears of a change a moment
    /// after macOS has started moving windows for it.
    private var onlineDisplays: Set<String> {
        Set(dinky_displays().filter { $0.displayID != 0 && CGDisplayIsOnline($0.displayID) != 0 }.map(\.uuid))
    }

    /// Notes which workspace each window is on, once a second. A note is kept only when the displays are the
    /// same a second later, so windows macOS is pouring off a display that is going away are never noted there.
    private func noteHomes() {
        guard !displaced.pending, !arranging, onlineDisplays == knownDisplays, let model = AppState.shared.coordinator?.model else {
            pendingHomes = nil
            return
        }
        if let pendingHomes { homes = pendingHomes }
        var noted: [UInt32: Int] = [:]
        for window in model.windows.values where window.isNormal && !window.isMinimized {
            if let n = number(of: dinky_window_space_id(window.id)) { noted[window.id] = n }
        }
        pendingHomes = noted
    }

    /// Moves windows that a display change left off their workspace back onto it.
    private func returnDisplaced() {
        let model = AppState.shared.displays
        var targets: [UInt32: UInt64] = [:]
        for (id, n) in homes {
            let space = dinky_window_space_id(id)
            // A window on a full-screen Space, or gone, stays put.
            guard let target = binding[n], space != target,
                  model.display(containingSpace: space)?.userSpaces.contains(space) == true else { continue }
            targets[id] = target
        }
        guard !targets.isEmpty else { return }
        for (target, moving) in Dictionary(grouping: targets.keys, by: { targets[$0]! }) {
            var ids = moving
            _ = dinky_move_windows_to_space(&ids, Int32(ids.count), target)
        }
        let arrived = { targets.filter { dinky_window_space_id($0.key) == $0.value }.count }
        _ = waitUntil(1) { arrived() == targets.count }
        print("workspaces: returned \(arrived()) of \(targets.count) windows a display change moved off their workspace")
    }

    /// The Spaces among `spaces` with windows dinky would tile or restore there: helper windows some apps keep
    /// on every Space don't count. Without a window model to ask, any window counts.
    private func occupiedSpaces(among spaces: [UInt64]) -> Set<UInt64> {
        guard let model = AppState.shared.coordinator?.model, !model.windows.isEmpty else {
            return Set(spaces.filter { !dinky_space_window_ids($0, true).isEmpty })
        }
        let occupied = model.windows.values.filter { $0.isNormal || $0.isMinimized }.map { dinky_window_space_id($0.id) }
        return Set(occupied).intersection(spaces)
    }

    /// Whether a Space has windows dinky would tile or restore there.
    private func occupied(_ space: UInt64) -> Bool { !occupiedSpaces(among: [space]).isEmpty }

    private func perform(_ action: PlanAction) -> Bool {
        let model = AppState.shared.displays
        switch action {
        case .create(let uuid):
            let name = model.displays.first { $0.uuid == uuid }.map(displayName) ?? uuid
            let space = dinky_create_space(uuid as CFString)
            guard space != 0, waitUntil(2, { model.reconcile(); return model.display(containingSpace: space) != nil }) else {
                print("workspaces: could not create a Space on \(name)")
                return false
            }
            print("workspaces: created Space \(space) on \(name)")
            return true

        case .move(let from, let to):
            // Every window goes, helper windows included; only the ones `occupied` counts must arrive.
            var ids = dinky_space_window_ids(from, true).map(\.uint32Value)
            AppState.shared.coordinator?.moveTree(from: from, to: to)
            if !ids.isEmpty, dinky_move_windows_to_space(&ids, Int32(ids.count), to) {
                _ = waitUntil(1) { !occupied(from) }
            }
            guard !occupied(from) else {
                AppState.shared.coordinator?.moveTree(from: to, to: from)
                print("workspaces: windows stayed on Space \(from) instead of moving to \(to)")
                return false
            }
            print("workspaces: moved the windows of Space \(from) to \(to)")
            return true

        case .remove(let space):
            // Removing the Space a display shows drops it to its first Space; leave for a workspace first.
            if let display = model.displays.first(where: { $0.currentSpaceID == space }) {
                let previous = model.previousSpace(on: display).flatMap { display.userSpaces.contains($0) && number(of: $0) != nil ? $0 : nil }
                if let target = previous ?? workspaces(on: display).first.flatMap(space(of:)), target != space,
                   switchSpace(toSpaceID: target, on: display) {
                    _ = waitUntil(1.5) { dinky_current_space_id(display.uuid as CFString) == target }
                }
            }
            guard dinky_destroy_space(space),
                  waitUntil(2, { model.reconcile(); return model.display(containingSpace: space) == nil }) else {
                print("workspaces: could not remove Space \(space)")
                return false
            }
            removed.insert(space)
            print("workspaces: removed Space \(space)")
            return true
        }
    }

    private func displayName(_ display: Display) -> String {
        display.name.isEmpty ? "display \(display.id)" : display.name
    }
}
