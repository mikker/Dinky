import AppKit
import DinkyLayout
import DinkyPrivate

/// Saves the last managed arrangement, separately from Recovery's original untiled frames.
/// Main thread only. Saves follow events; known undo moves can be reversed at startup.
final class Session {
    struct Entry: Codable, Equatable {
        let id: WindowID
        let pid: pid_t
        let bundleID: String?
        var firstSeen: Date
        let appLaunched: Date
        var spaceID: UInt64
        let frame: CGRect?
        let displayVisibleFrame: CGRect?
        let floating: Bool
        let floatingOverride: Bool?
        var returnSpaceID: UInt64? = nil
        var workspaceNumber: Int? = nil

        var identity: Window.Identity { .init(id: id, pid: pid, firstSeen: firstSeen) }
    }

    struct Space: Codable, Equatable {
        let id: UInt64
        let layout: WorkspaceSnapshot
        var workspaceNumber: Int? = nil
    }

    struct Journal: Codable, Equatable {
        var version = 1
        let windows: [Entry]
        let spaces: [Space]
    }

    enum Restoration { case none, waiting, restored }

    struct SpaceMove: Equatable {
        let source: UInt64
        let target: UInt64
    }

    struct RestorationPlan {
        var windows: [WindowID: Entry] = [:]
        var spaces: [UInt64: WorkspaceSnapshot] = [:]
        var moves: [WindowID: SpaceMove] = [:]
    }

    static let url = Recovery.url.deletingLastPathComponent().appendingPathComponent("session.json")
    private let url: URL
    private var readState: (() -> Journal?)?
    private var recording = false
    private var saveScheduled = false
    private var lastSaved: Journal?
    private(set) var pendingWindows: [WindowID: Entry] = [:]
    private(set) var pendingSpaces: [UInt64: WorkspaceSnapshot] = [:]
    private(set) var awaitingStartup = false
    private var pendingMoves: [WindowID: SpaceMove] = [:]
    private var writingFrames: [WindowID: Entry] = [:]

    init(url: URL = Session.url) { self.url = url }

    func start(coordinator: Coordinator) {
        awaitingStartup = true
        startSaving { [weak self, weak coordinator] in
            guard let self, let coordinator else { return nil }
            return snapshot(workspaces: coordinator.workspaces, windows: coordinator.model.windows,
                            placements: coordinator.placements,
                            displays: coordinator.displays.displays.map(RecoveryDisplay.init),
                            untiledSpaces: coordinator.untiledSpaces, binding: AppState.shared.numbers.binding,
                            launchDate: Self.launchDate)
        }
    }

    /// Number bindings exist only after the initial Space arrangement completes.
    func finishStartup(coordinator: Coordinator) {
        guard awaitingStartup else { return }
        if let journal = load() {
            prepare(journal, windows: coordinator.model.windows,
                    spaces: Set(coordinator.displays.displays.flatMap(\.userSpaces)),
                    launchDate: Self.launchDate, binding: AppState.shared.numbers.binding,
                    move: { id, space in
                        guard dinky_window_info(id).pid == coordinator.model.windows[id]?.pid else { return false }
                        if let window = coordinator.model.windows[id] {
                            coordinator.prepareRestorationMove(window, to: space)
                        }
                        var ids = [id]
                        return dinky_move_windows_to_space(&ids, 1, space)
                    })
        }
        awaitingStartup = false
        coordinator.reconcile()
        saveSoon()
    }

    func startSaving(_ readState: @escaping () -> Journal?) {
        self.readState = readState
        recording = true
    }

    /// Bind saved records to this model only if the same app process still owns the same document window.
    /// A window moved while dinky was off keeps its new Space and gets the current default layout.
    func prepare(_ journal: Journal, windows: [WindowID: Window], spaces: Set<UInt64>,
                 launchDate: (pid_t) -> Date?, binding: [Int: UInt64] = [:],
                 move: ((WindowID, UInt64) -> Bool)? = nil) {
        let plan = restorationPlan(journal, windows: windows, spaces: spaces, launchDate: launchDate, binding: binding)
        pendingWindows = plan.windows
        pendingSpaces = plan.spaces
        pendingMoves = plan.moves
        writingFrames = [:]
        requestMoves(move)
    }

    /// Computes identity checks and destinations without writing frames or moving native windows.
    func restorationPlan(_ journal: Journal, windows: [WindowID: Window], spaces: Set<UInt64>,
                         launchDate: (pid_t) -> Date?, binding: [Int: UInt64] = [:]) -> RestorationPlan {
        var plan = RestorationPlan()
        guard journal.version == 1, Set(journal.windows.map(\.id)).count == journal.windows.count,
              Set(journal.spaces.map(\.id)).count == journal.spaces.count else { return plan }
        var destinations: [UInt64: UInt64] = [:]
        for saved in journal.spaces {
            if spaces.contains(saved.id) { destinations[saved.id] = saved.id }
            else if let number = saved.workspaceNumber, let replacement = binding[number], spaces.contains(replacement) {
                destinations[saved.id] = replacement
            }
        }
        var launches: [pid_t: Date] = [:]
        for var entry in journal.windows {
            guard let window = windows[entry.id], window.level == 0, window.isDocument,
                  window.pid == entry.pid, window.bundleID == entry.bundleID, spaces.contains(window.spaceID),
                  entry.firstSeen >= entry.appLaunched else { continue }
            let launched = launches[entry.pid] ?? launchDate(entry.pid)
            // JSON dates and NSRunningApplication dates can differ below a millisecond after conversion.
            guard let launched, abs(launched.timeIntervalSince(entry.appLaunched)) < 0.001 else { continue }
            let savedSpace = entry.spaceID
            let replacement = entry.workspaceNumber.flatMap { binding[$0] }
            let target = destinations[savedSpace] ?? (spaces.contains(savedSpace) ? savedSpace : replacement)
            guard let target, spaces.contains(target) else { continue }
            if window.spaceID != target {
                // Preserve a manual move while disabled. Only undo or deletion authorizes a startup move.
                guard window.spaceID == entry.returnSpaceID || !spaces.contains(savedSpace) else { continue }
                plan.moves[entry.id] = SpaceMove(source: window.spaceID, target: target)
            }
            entry.spaceID = target
            entry.returnSpaceID = plan.moves[entry.id]?.source
            entry.workspaceNumber = binding.first { $0.value == target }?.key ?? entry.workspaceNumber
            launches[entry.pid] = launched
            entry.firstSeen = window.identity.firstSeen
            plan.windows[entry.id] = entry
        }
        for space in journal.spaces where space.layout.isValid {
            guard let target = destinations[space.id],
                  space.layout.windows.contains(where: { plan.windows[$0]?.spaceID == target }) else { continue }
            plan.spaces[target] = space.layout
        }
        return plan
    }

    /// Issue each move once. Accepted moves wait for normal events; rejected moves release their saved state.
    private func requestMoves(_ move: ((WindowID, UInt64) -> Bool)?) {
        for (id, request) in pendingMoves.sorted(by: { $0.key < $1.key }) {
            guard move?(id, request.target) != true else { continue }
            fputs("session: window \(id): move to saved workspace rejected; keeping current Space\n", stderr)
            pendingMoves[id] = nil
            pendingWindows[id] = nil
        }
        pendingSpaces = pendingSpaces.filter { space, layout in
            layout.windows.contains { pendingWindows[$0]?.spaceID == space }
        }
    }

    func floatingOverride(for window: Window) -> Bool? {
        guard let entry = pendingWindows[window.id], entry.identity == window.identity,
              entry.spaceID == window.spaceID else { return nil }
        return entry.floatingOverride
    }

    /// Delay the first layout until the existing classification/tab events resolve its visible saved members.
    /// Inactive Spaces keep their snapshots until their first visit; no Space switch or retry timer is needed.
    func restore(_ space: UInt64, workspace: inout Workspace, windows: [WindowID: Window],
                 placements: [WindowID: Placement], held: Set<WindowID>) -> Restoration {
        guard let saved = pendingSpaces[space] else { return .none }
        guard !saved.windows.contains(where: { pendingMoves[$0] != nil }) else { return .waiting }
        let members = saved.windows.filter { id in
            guard let entry = pendingWindows[id], let window = windows[id] else { return false }
            return entry.identity == window.identity && window.spaceID == space && Self.isShown(window)
        }
        guard members.allSatisfy({ placements[$0] != nil && !held.contains($0) }) else { return .waiting }
        pendingSpaces[space] = nil
        let tiled = Set(members.filter { placements[$0]?.space == space && placements[$0]?.floating == false })
        let newcomers = workspace.windows.filter { !tiled.contains($0) }
        guard !tiled.isEmpty, workspace.restore(saved, retaining: tiled) else { return .none }
        for id in newcomers { workspace.insert(id) }
        return .restored
    }

    func deferTiling(_ window: Window) -> Bool {
        awaitingStartup || (pendingMoves[window.id] != nil && window.spaceID != pendingWindows[window.id]?.spaceID)
    }

    func isRestoring(on space: UInt64) -> Bool {
        guard let layout = pendingSpaces[space] else { return false }
        // A delayed native move must not block unrelated windows already on the destination Space.
        return !layout.windows.contains { pendingMoves[$0] != nil }
    }

    func discardLayout(on space: UInt64) { pendingSpaces[space] = nil }

    func prune(windows: [WindowID: Window], spaces: Set<UInt64>) {
        for (id, request) in Array(pendingMoves) {
            guard let entry = pendingWindows[id], let window = windows[id], window.identity == entry.identity,
                  window.spaceID == request.source || window.spaceID == request.target else {
                pendingMoves[id] = nil
                pendingWindows[id] = nil
                continue
            }
            if window.spaceID == entry.spaceID {
                pendingMoves[id] = nil
                pendingWindows[id]?.returnSpaceID = nil
            }
        }
        pendingWindows = pendingWindows.filter { id, entry in
            guard let window = windows[id] else { return false }
            return window.identity == entry.identity
                && (window.spaceID == entry.spaceID || pendingMoves[id]?.source == window.spaceID)
                && spaces.contains(entry.spaceID)
        }
        pendingSpaces = pendingSpaces.filter { space, layout in
            spaces.contains(space) && layout.windows.contains { pendingWindows[$0]?.spaceID == space }
        }
        writingFrames = writingFrames.filter { id, entry in windows[id]?.identity == entry.identity }
    }

    /// Floating frames are applied once, when their current native Space is visible and classification is known.
    /// Tiled frames come from restored trees. Hidden/minimized windows wait for their ordinary show events.
    func floatingJobs(windows: [WindowID: Window], placements: [WindowID: Placement],
                      displays: [RecoveryDisplay], untiledSpaces: Set<UInt64> = []) -> [FrameJob] {
        var jobs: [FrameJob] = []
        for entry in Array(pendingWindows.values) {
            if pendingMoves[entry.id] != nil { continue }
            guard let window = windows[entry.id], window.identity == entry.identity,
                  window.spaceID == entry.spaceID else {
                pendingWindows[entry.id] = nil
                continue
            }
            guard Self.isShown(window), let placement = placements[entry.id],
                  let display = displays.first(where: { $0.currentSpace == entry.spaceID }) else { continue }
            // Leave records for a layout whose classification is still in progress.
            let floating = placement.floating || untiledSpaces.contains(entry.spaceID)
            guard pendingSpaces[entry.spaceID] == nil || floating else { continue }
            pendingWindows[entry.id] = nil
            guard entry.floating, floating, let savedFrame = entry.frame,
                  let frame = recoveryFrame(savedFrame, from: entry.displayVisibleFrame, on: display.visibleFrame),
                  !window.frame.isClose(to: frame, within: 2) else { continue }
            writingFrames[entry.id] = entry
            jobs.append(FrameJob(pid: entry.pid, id: entry.id, frame: frame))
        }
        return jobs
    }

    /// Keep the saved target in the journal if shutdown happens before an asynchronous frame write finishes.
    func finished(_ jobs: [FrameJob], results: [FrameResult]) {
        for job in jobs {
            guard writingFrames[job.id]?.pid == job.pid else { continue }
            writingFrames[job.id] = nil
            if !results.contains(where: { $0.job == job && $0.got?.isClose(to: job.frame, within: 2) == true }) {
                fputs("session: window \(job.id): saved floating frame was not confirmed\n", stderr)
            }
        }
        saveSoon()
    }

    /// Capture semantic state after events settle, at most once per half-second burst. Identical state is not written.
    func saveSoon() {
        guard recording, !awaitingStartup, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            saveScheduled = false
            if recording { saveCurrent() }
        }
    }

    /// Save before Recovery changes frames. Subsequent disable/quit events cannot overwrite the managed state.
    func pause(returnSpaces: [WindowID: UInt64] = [:]) {
        guard recording else { return }
        if let current = readState?() {
            let journal = Journal(windows: current.windows.map { entry in
                var entry = entry
                entry.returnSpaceID = returnSpaces[entry.id]
                return entry
            }, spaces: current.spaces)
            save(journal)
        }
        recording = false
    }

    func resume() {
        recording = true
        guard let coordinator = AppState.shared.coordinator else { saveSoon(); return }
        awaitingStartup = true
        finishStartup(coordinator: coordinator)
    }

    private func saveCurrent() {
        guard let journal = readState?() else { return }
        save(journal)
    }

    /// Pending inactive-Space state remains in the next journal instead of being replaced by untiled startup frames.
    func snapshot(workspaces: [UInt64: Workspace], windows: [WindowID: Window], placements: [WindowID: Placement],
                  displays: [RecoveryDisplay], untiledSpaces: Set<UInt64> = [],
                  binding: [Int: UInt64] = [:], launchDate: (pid_t) -> Date?) -> Journal {
        var entries: [WindowID: Entry] = [:]
        var launches: [pid_t: Date] = [:]
        for window in windows.values where window.level == 0 && window.isDocument {
            if let pending = pendingWindows[window.id] ?? writingFrames[window.id], pending.identity == window.identity,
               (pending.spaceID == window.spaceID || pendingMoves[window.id]?.source == window.spaceID) {
                entries[window.id] = pending
                continue
            }
            let placement = placements[window.id]
            guard let display = displays.first(where: { $0.userSpaces.contains(window.spaceID) }),
                  let launched = launches[window.pid] ?? launchDate(window.pid) else { continue }
            launches[window.pid] = launched
            let floating = (placement?.floating ?? false) || untiledSpaces.contains(window.spaceID)
            entries[window.id] = Entry(id: window.id, pid: window.pid, bundleID: window.bundleID,
                                      firstSeen: window.identity.firstSeen, appLaunched: launched,
                                      spaceID: window.spaceID, frame: floating ? window.frame : nil,
                                      displayVisibleFrame: floating ? display.visibleFrame : nil,
                                      floating: floating, floatingOverride: placement?.floatingOverride,
                                      workspaceNumber: binding.first { $0.value == window.spaceID }?.key)
        }
        var layouts = workspaces.mapValues(WorkspaceSnapshot.init)
        for (space, saved) in pendingSpaces { layouts[space] = saved }
        // Closed or moved windows cannot keep stale leaves or a Space's snapshot alive.
        let spaces = layouts.keys.sorted().compactMap { space -> Space? in
            guard let layout = layouts[space], layout.isValid else { return nil }
            let retained = Set(layout.windows.filter { entries[$0]?.spaceID == space })
            guard !retained.isEmpty else { return nil }
            // Preserve a pending snapshot exactly when every leaf still matches.
            if retained.count == layout.windows.count {
                return Space(id: space, layout: layout, workspaceNumber: binding.first { $0.value == space }?.key)
            }
            var workspace = Workspace(bounds: .zero, algorithm: layout.algorithm)
            guard workspace.restore(layout, retaining: retained) else { return nil }
            return Space(id: space, layout: WorkspaceSnapshot(workspace), workspaceNumber: binding.first { $0.value == space }?.key)
        }
        return Journal(windows: entries.values.sorted { $0.id < $1.id }, spaces: spaces)
    }

    @discardableResult
    func save(_ journal: Journal) -> Bool {
        guard journal != lastSaved else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(journal)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            lastSaved = journal
            return true
        } catch {
            fputs("session: could not save arrangement: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    func load() -> Journal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(Journal.self, from: data)
        } catch {
            fputs("session: could not load arrangement: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    private static func isShown(_ window: Window) -> Bool {
        window.isNormal && !window.isMinimized && NSRunningApplication(processIdentifier: window.pid)?.isHidden != true
    }

    private static func launchDate(_ pid: pid_t) -> Date? {
        NSRunningApplication(processIdentifier: pid)?.launchDate
    }
}
