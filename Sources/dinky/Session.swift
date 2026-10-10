import AppKit
import DinkyLayout

/// Saves the last managed arrangement, separately from Recovery's original untiled frames.
/// Main thread only. Saves follow events; restarting never moves windows between native Spaces.
final class Session {
    struct Entry: Codable, Equatable {
        let id: WindowID
        let pid: pid_t
        let bundleID: String?
        var firstSeen: Date
        let appLaunched: Date
        let spaceID: UInt64
        let frame: CGRect?
        let displayVisibleFrame: CGRect?
        let floating: Bool
        let floatingOverride: Bool?

        var identity: Window.Identity { .init(id: id, pid: pid, firstSeen: firstSeen) }
    }

    struct Space: Codable, Equatable {
        let id: UInt64
        let layout: WorkspaceSnapshot
    }

    struct Journal: Codable, Equatable {
        var version = 1
        let windows: [Entry]
        let spaces: [Space]
    }

    enum Restoration { case none, waiting, restored }

    static let url = Recovery.url.deletingLastPathComponent().appendingPathComponent("session.json")
    private let url: URL
    private var readState: (() -> Journal?)?
    private var recording = false
    private var saveScheduled = false
    private var lastSaved: Journal?
    private(set) var pendingWindows: [WindowID: Entry] = [:]
    private(set) var pendingSpaces: [UInt64: WorkspaceSnapshot] = [:]
    private var writingFrames: [WindowID: Entry] = [:]

    init(url: URL = Session.url) { self.url = url }

    func start(coordinator: Coordinator) {
        if let journal = load() {
            prepare(journal, windows: coordinator.model.windows,
                    spaces: Set(coordinator.displays.displays.flatMap(\.userSpaces)), launchDate: Self.launchDate)
        }
        startSaving { [weak self, weak coordinator] in
            guard let self, let coordinator else { return nil }
            return snapshot(workspaces: coordinator.workspaces, windows: coordinator.model.windows,
                            placements: coordinator.placements,
                            displays: coordinator.displays.displays.map(RecoveryDisplay.init),
                            untiledSpaces: coordinator.untiledSpaces, launchDate: Self.launchDate)
        }
    }

    func startSaving(_ readState: @escaping () -> Journal?) {
        self.readState = readState
        recording = true
    }

    /// Bind saved records to this model only if the same app process still owns the same document window.
    /// A window moved while dinky was off keeps its new Space and gets the current default layout.
    func prepare(_ journal: Journal, windows: [WindowID: Window], spaces: Set<UInt64>,
                 launchDate: (pid_t) -> Date?) {
        pendingWindows = [:]
        pendingSpaces = [:]
        writingFrames = [:]
        guard journal.version == 1, Set(journal.windows.map(\.id)).count == journal.windows.count,
              Set(journal.spaces.map(\.id)).count == journal.spaces.count else { return }
        var launches: [pid_t: Date] = [:]
        for var entry in journal.windows {
            guard let window = windows[entry.id], window.level == 0, window.isDocument,
                  window.pid == entry.pid, window.bundleID == entry.bundleID,
                  window.spaceID == entry.spaceID, spaces.contains(entry.spaceID),
                  entry.firstSeen >= entry.appLaunched else { continue }
            let launched = launches[entry.pid] ?? launchDate(entry.pid)
            // JSON dates and NSRunningApplication dates can differ below a millisecond after conversion.
            guard let launched, abs(launched.timeIntervalSince(entry.appLaunched)) < 0.001 else { continue }
            launches[entry.pid] = launched
            entry.firstSeen = window.identity.firstSeen
            pendingWindows[entry.id] = entry
        }
        for space in journal.spaces where spaces.contains(space.id) && space.layout.isValid {
            guard space.layout.windows.contains(where: { pendingWindows[$0]?.spaceID == space.id }) else { continue }
            pendingSpaces[space.id] = space.layout
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

    func discardLayout(on space: UInt64) { pendingSpaces[space] = nil }

    func prune(windows: [WindowID: Window], spaces: Set<UInt64>) {
        pendingWindows = pendingWindows.filter { id, entry in
            guard let window = windows[id] else { return false }
            return window.identity == entry.identity && window.spaceID == entry.spaceID && spaces.contains(entry.spaceID)
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
        guard recording, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            saveScheduled = false
            if recording { saveCurrent() }
        }
    }

    /// Save before Recovery changes frames. Subsequent disable/quit events cannot overwrite the managed state.
    func pause() {
        guard recording else { return }
        saveCurrent()
        recording = false
    }

    func resume() { recording = true; saveSoon() }

    private func saveCurrent() {
        guard let journal = readState?() else { return }
        save(journal)
    }

    /// Pending inactive-Space state remains in the next journal instead of being replaced by untiled startup frames.
    func snapshot(workspaces: [UInt64: Workspace], windows: [WindowID: Window], placements: [WindowID: Placement],
                  displays: [RecoveryDisplay], untiledSpaces: Set<UInt64> = [], launchDate: (pid_t) -> Date?) -> Journal {
        var entries: [WindowID: Entry] = [:]
        var launches: [pid_t: Date] = [:]
        for window in windows.values where window.level == 0 && window.isDocument {
            if let pending = pendingWindows[window.id] ?? writingFrames[window.id], pending.identity == window.identity,
               pending.spaceID == window.spaceID {
                entries[window.id] = pending
                continue
            }
            guard let placement = placements[window.id],
                  let display = displays.first(where: { $0.userSpaces.contains(window.spaceID) }),
                  let launched = launches[window.pid] ?? launchDate(window.pid) else { continue }
            launches[window.pid] = launched
            let floating = placement.floating || untiledSpaces.contains(window.spaceID)
            entries[window.id] = Entry(id: window.id, pid: window.pid, bundleID: window.bundleID,
                                      firstSeen: window.identity.firstSeen, appLaunched: launched,
                                      spaceID: window.spaceID, frame: floating ? window.frame : nil,
                                      displayVisibleFrame: floating ? display.visibleFrame : nil,
                                      floating: floating, floatingOverride: placement.floatingOverride)
        }
        var layouts = workspaces.mapValues(WorkspaceSnapshot.init)
        for (space, saved) in pendingSpaces { layouts[space] = saved }
        // Closed or moved windows cannot keep stale leaves or a Space's snapshot alive.
        let spaces = layouts.keys.sorted().compactMap { space -> Space? in
            guard let layout = layouts[space], layout.isValid else { return nil }
            let retained = Set(layout.windows.filter { entries[$0]?.spaceID == space })
            guard !retained.isEmpty else { return nil }
            // Preserve a pending snapshot exactly when every leaf still matches.
            if retained.count == layout.windows.count { return Space(id: space, layout: layout) }
            var workspace = Workspace(bounds: .zero, algorithm: layout.algorithm)
            guard workspace.restore(layout, retaining: retained) else { return nil }
            return Space(id: space, layout: WorkspaceSnapshot(workspace))
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
