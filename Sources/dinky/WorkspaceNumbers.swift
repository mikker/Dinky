import AppKit
import DinkyConfig
import DinkyPrivate

// Workspace numbers: which native Space each workspace is. Workspaces are numbered across displays and live
// where `[workspace-to-display]` puts them, else on the main display. `arrange()` makes the Spaces match: it
// runs `WorkspacePlan`'s steps (create a Space, move a Space's windows, remove an empty Space) until there are
// none left. It runs at launch, on config reload, and a moment after displays or Spaces come and go. Between
// runs a workspace stays on its Space by ID, wherever macOS moves that Space.
// A display that goes away has macOS pour the windows of its Spaces onto another display's first Space, which
// is workspace 1's. So the workspace of every window is noted while the displays are settled, and once the
// Spaces are arranged after a display change, windows found off their workspace go back to it. Main thread only.
final class WorkspaceNumbers {
    /// Workspace number to Space.
    private(set) var binding: [Int: UInt64] = [:]
    private var observers: [() -> Void] = []
    private var pending: DispatchWorkItem?
    private var arranging = false
    /// Spaces this removed, whose `spaceDestroyed` events are not news.
    private var removed: Set<UInt64> = []
    /// The workspace each window was on while the displays were settled. See `noteHomes()`.
    private var homes: [UInt32: WorkspaceWindowHome] = [:]
    /// The displays as the last display change left them.
    private var knownDisplays: Set<String> = []
    /// Set by a display coming or going, until an arrangement completes and windows are back on their workspaces.
    private var displaced = false
    private var recoveryStarted: Date?
    private var recoveryHomes: [UInt32: WorkspaceWindowHome] = [:]
    private var restorationHistory = WindowRestorationHistory()
    private var recoveryQueued = false
    private var cleanupNeeded = false
    private var recoveryState = WorkspaceRecoveryState()

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
        // A display coming or going, or another becoming main, moves workspaces.
        model.observe { [weak self] model in
            guard let self else { return }
            let now = Set(model.displays.map(\.uuid))
            let nowMain = model.displays.first(where: \.isMain)?.uuid
            guard now != knownDisplays || nowMain != main else { return }
            let (connected, disconnected) = (now.subtracting(knownDisplays), knownDisplays.subtracting(now))
            (knownDisplays, main) = (now, nowMain)
            if !connected.isEmpty { print("displays: connected \(connected.sorted())") }
            if !disconnected.isEmpty { print("displays: disconnected \(disconnected.sorted())") }
            fflush(stdout)
            if !connected.isEmpty || !disconnected.isEmpty {
                displaced = true
                recoveryStarted = Date()
                recoveryHomes = homes
                restorationHistory.beginDisplayChange()
                recoveryState.reset()
            }
            arrangeSoon()
        }
        noteHomes()
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
    /// waits for WindowServer to show its result, normally within a poll or two.
    func arrange() {
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
        var completed = false
        for _ in 0..<50 {
            model.reconcile()
            let displays = model.displays.map {
                PlanDisplay(uuid: $0.uuid, monitor: model.monitor($0), spaces: $0.userSpaces, current: $0.currentSpaceID)
            }
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
        if displaced, completed {
            returnDisplaced()
            displaced = false
        }
        // Observers hear the result once, not every step on the way.
        if binding != start {
            print("workspaces: " + binding.keys.sorted().map { "\($0)=\(binding[$0]!)" }.joined(separator: " "))
            observers.forEach { $0() }
        }
        fflush(stdout)
        AppState.shared.coordinator?.reconcile()
    }

    /// The displays connected now, as WindowServer lists them. The display model hears of a change a moment
    /// after macOS has started moving windows for it.
    private var onlineDisplays: Set<String> {
        Set(dinky_displays().filter { $0.displayID != 0 && CGDisplayIsOnline($0.displayID) != 0 }.map(\.uuid))
    }

    /// Seed homes once; later changes come from window events.
    private func noteHomes() {
        guard let model = AppState.shared.coordinator?.model else { return }
        for window in model.windows.values { noteHome(window, refreshTitle: true) }
    }

    private func noteHome(_ window: Window, refreshTitle: Bool) {
        guard !displaced, !arranging, onlineDisplays == knownDisplays, window.isWorkspaceWindow,
              let n = number(of: dinky_window_space_id(window.id)) else { return }
        let previous = homes[window.id].flatMap { $0.identity == window.identity ? $0.title : nil }
        let title = refreshTitle || previous == nil ? windowTitle(window) ?? previous : previous
        homes[window.id] = .init(identity: window.identity, workspace: n, title: title ?? "")
    }

    /// Moves windows that a display change left off their workspace back onto it.
    private func returnDisplaced() {
        let model = AppState.shared.displays
        var targets: [UInt32: UInt64] = [:]
        if let windows = AppState.shared.coordinator?.model.windows, recoveryStarted != nil {
            let candidates = replacementCandidates()
            let live = Set(windows.values.map(\.identity))
            for (old, replacement) in workspaceReplacements(homes: Array(recoveryHomes.values), candidates: candidates, live: live) {
                recoveryHomes.removeValue(forKey: old.identity.id)
                recoveryHomes[replacement.identity.id] = .init(identity: replacement.identity, workspace: old.workspace, title: old.title)
            }
        }
        if let windows = AppState.shared.coordinator?.model.windows {
            // A closed original without a replacement in this event batch must not claim a later new window.
            recoveryHomes = recoveryHomes.filter { windows[$0.key]?.identity == $0.value.identity }
            let destinations = Dictionary(uniqueKeysWithValues: recoveryHomes.values.compactMap { home in
                binding[home.workspace].map { (home.identity, $0) }
            })
            recoveryState.retain(live: Set(windows.values.map(\.identity)), destinations: destinations)
            if recoveryHomes.isEmpty {
                recoveryStarted = nil
                recoveryState.reset()
            }
        }
        for (id, home) in recoveryHomes {
            guard !restorationHistory.returnedDuringChange(home.identity),
                  AppState.shared.coordinator?.model.windows[id]?.identity == home.identity else { continue }
            let n = home.workspace
            let space = dinky_window_space_id(id)
            if let target = binding[n], space == target {
                restorationHistory.noteReturn(home.identity)
                if recoveryState.confirmMove(home.identity, on: space) {
                    AppState.shared.coordinator?.model.refresh(id)
                }
                continue
            }
            // A window on a full-screen Space, or gone, stays put.
            guard let target = binding[n], space != target,
                  model.display(containingSpace: space)?.userSpaces.contains(space) == true else { continue }
            guard recoveryState.beginMove(home.identity, to: target) else { continue }
            targets[id] = target
        }
        guard !targets.isEmpty else { return }
        for (target, moving) in Dictionary(grouping: targets.keys, by: { targets[$0]! }) {
            var ids = moving
            if !dinky_move_windows_to_space(&ids, Int32(ids.count), target) {
                for id in ids {
                    if let home = recoveryHomes[id] { recoveryState.rejectMove(home.identity) }
                }
            }
        }
        var arrived = 0
        for (id, target) in targets where dinky_window_space_id(id) == target {
            arrived += 1
            if let home = recoveryHomes[id] {
                _ = recoveryState.confirmMove(home.identity, on: target)
                restorationHistory.noteReturn(home.identity)
            }
            AppState.shared.coordinator?.model.refresh(id)
        }
        print("workspaces: requested return of \(targets.count) displaced windows; \(arrived) already on their workspace")
    }

    /// Keep displaced windows out of the arrival workspace's layout until their home is ready.
    func deferTiling(_ window: Window) -> Bool {
        guard window.isWorkspaceWindow, !restorationHistory.returnedDuringChange(window.identity) else { return false }
        let changing = onlineDisplays != knownDisplays
        guard changing || displaced || recoveryStarted != nil else { return false }
        if let home = recoveryHomes[window.id], home.identity == window.identity {
            return changing || binding[home.workspace] != dinky_window_space_id(window.id)
        }
        guard let started = recoveryStarted, window.identity.firstSeen >= started else { return false }
        guard let windows = AppState.shared.coordinator?.model.windows else { return false }
        let candidates = replacementCandidates()
        return workspaceReplacements(homes: Array(recoveryHomes.values), candidates: candidates, live: Set(windows.values.map(\.identity)))
            .contains { $0.1.identity == window.identity }
    }

    func wasRestored(_ window: Window) -> Bool { restorationHistory.wasRestored(window.identity) }

    /// Invalidate before tracking can consult replacement titles for tiling deferral.
    func invalidateRecoveryTitle(_ window: Window) { recoveryState.invalidateTitle(window.identity) }

    /// Coalesce window events after the model has applied their updates.
    func recoverAfterWindowEvent(_ event: WindowEvent) {
        guard event.window != nil || [.spaceChange, .spaceCreated, .spaceDestroyed].contains(event.kind) else { return }
        if let window = event.window {
            if event.change == .removed {
                homes.removeValue(forKey: window.id)
                recoveryState.remove(window.identity)
                if recoveryStarted != nil { cleanupNeeded = true }
            } else {
                noteHome(window, refreshTitle: event.kind == .windowTitle)
            }
        }
        if let model = AppState.shared.coordinator?.model {
            restorationHistory.retain(Set(model.windows.values.map(\.identity)))
        }
        guard !displaced, recoveryStarted != nil, !recoveryQueued else { return }
        recoveryQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            recoveryQueued = false
            guard !arranging, !displaced, recoveryStarted != nil, onlineDisplays == knownDisplays else { return }
            returnDisplaced()
            if cleanupNeeded {
                cleanupNeeded = false
                arrangeSoon(after: 0)
            }
        }
    }

    private func replacementTitle(_ window: Window) -> String? {
        if let title = recoveryState.titles[window.identity] { return title }
        guard let title = windowTitle(window) else { return nil }
        recoveryState.cacheTitle(title, for: window.identity)
        return title
    }

    private func replacementCandidates() -> [WorkspaceWindowHome] {
        guard let windows = AppState.shared.coordinator?.model.windows, let started = recoveryStarted else { return [] }
        let pids = Set(recoveryHomes.values.map { $0.identity.pid })
        return windows.values.filter {
            $0.isWorkspaceWindow && recoveryHomes[$0.id] == nil && $0.identity.firstSeen >= started && pids.contains($0.pid)
        }.compactMap { window in
            guard let title = replacementTitle(window) else { return nil }
            return .init(identity: window.identity, workspace: 0, title: title)
        }
    }

    private func windowTitle(_ window: Window) -> String? {
        guard let element = axWindow(pid: window.pid, wid: window.id, timeout: 0.1) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String, !title.isEmpty else { return nil }
        return title
    }

    /// The Spaces among `spaces` with windows dinky would tile or restore there: helper windows some apps keep
    /// on every Space don't count. Without a window model to ask, any window counts.
    private func occupiedSpaces(among spaces: [UInt64]) -> Set<UInt64> {
        guard let model = AppState.shared.coordinator?.model, !model.windows.isEmpty else {
            return Set(spaces.filter { !dinky_space_window_ids($0, true).isEmpty })
        }
        let occupied = model.windows.values.filter { $0.isWorkspaceWindow }.map { dinky_window_space_id($0.id) }
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
