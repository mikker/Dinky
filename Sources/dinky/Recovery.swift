import AppKit
import DinkyLayout
import DinkyPrivate

// Restore untiled frames and surviving original Spaces on disable, quit, and explicit recovery. Inaccessible or failed windows stay journaled for a later explicit attempt. Main thread only.
final class Recovery {
    struct Entry: Codable {
        let id: UInt32
        let pid: pid_t
        let bundleID: String?
        var firstSeen: Date
        let frame: CGRect
        let spaceID: UInt64
        var displayUUID: String? = nil
        var displayVisibleFrame: CGRect? = nil

        var identity: Window.Identity { .init(id: id, pid: pid, firstSeen: firstSeen) }
    }

    struct Journal: Codable {
        let pid: pid_t
        let launched: Date
        let windows: [Entry]
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/dinky/journal.json")

    /// Unfinished windows, including records carried from a previous session.
    var recoverable: Int { recording ? carried.filter { entries[$0] != nil }.count : entries.count }

    private let journalURL: URL
    init(url: URL = Recovery.url) { journalURL = url }

    private let launched = Date()
    private var entries: [UInt32: Entry] = [:]
    private var carried: Set<UInt32> = []
    private var model: WindowModel?
    private var recording = false
    private var saveScheduled = false
    private var applier: FrameApplier!

    /// Carries over unfinished records, then journals windows as the model sees them, so each frame is
    /// the one the model read before dinky wrote any. Restores write through the coordinator's applier, so the
    /// minimum sizes it learns have one owner.
    func start(model: WindowModel, applier: FrameApplier) {
        self.model = model
        self.applier = applier
        carryOver()
        model.observe { [weak self] _ in self?.record() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.record() }
        resume()
    }

    /// Journals windows from now on. Call before tiling (re)starts.
    func resume() {
        recording = true
        record()
    }

    /// Restores untiled frames and returns windows to surviving original Spaces without switching focus.
    /// Waits for the existing bounded frame batch; unfinished entries remain on disk.
    @discardableResult
    func restore() -> String {
        guard let model else { return "nothing to restore" }
        let displays = AppState.shared.displays
        displays.reconcile()
        return restore(windows: model.windows, displays: displays.displays.map(RecoveryDisplay.init),
                       read: readWindow, write: writeFrames, move: { id, space in
                           var ids = [id]
                           return dinky_move_windows_to_space(&ids, 1, space)
                       })
    }

    /// The same restore policy with window reads and frame writes supplied by the caller for testing.
    @discardableResult
    func restore(windows: [UInt32: Window], displays: [RecoveryDisplay],
                 read: (UInt32) -> RecoveryWindowState?, write: ([FrameJob]) -> [FrameResult],
                 move: (UInt32, UInt64) -> Bool = { _, _ in false }) -> String {
        recording = false
        guard !entries.isEmpty else { return "nothing to restore" }
        var problems: [UInt32: String] = [:]
        var targets: [UInt32: UInt64] = [:]
        var desiredFrames: [UInt32: CGRect] = [:]
        var jobs: [FrameJob] = []
        let total = entries.count
        var restored = 0
        var closed = 0
        for entry in entries.values.sorted(by: { $0.id < $1.id }) {
            guard windows[entry.id]?.identity == entry.identity,
                  let state = read(entry.id), state.pid == entry.pid else {
                entries.removeValue(forKey: entry.id)
                closed += 1
                continue
            }
            guard let display = displays.first(where: { $0.userSpaces.contains(state.space) }) else {
                problems[entry.id] = "not on an available user Space"
                continue
            }
            // A deleted original Space has no safe substitute: keep this window on its current Space.
            let destination = displays.first { $0.userSpaces.contains(entry.spaceID) }
            let targetSpace = destination == nil ? state.space : entry.spaceID
            guard let frame = recoveryFrame(entry.frame, from: entry.displayVisibleFrame,
                                            on: (destination ?? display).visibleFrame) else {
                problems[entry.id] = "invalid saved frame or display bounds"
                continue
            }
            targets[entry.id] = targetSpace
            desiredFrames[entry.id] = frame
            // Write while reachable, before returning a window to an inactive Space.
            if display.currentSpace == state.space, state.isOnScreen, !state.frame.isClose(to: frame, within: 2) {
                jobs.append(FrameJob(pid: entry.pid, id: entry.id, frame: frame))
            }
        }
        if !jobs.isEmpty { _ = write(jobs) }
        for entry in entries.values.sorted(by: { $0.id < $1.id }) {
            guard let target = targets[entry.id], let state = read(entry.id), state.pid == entry.pid,
                  state.space != target else { continue }
            if move(entry.id, target) != true {
                problems[entry.id] = "move to original Space failed; kept for explicit recovery"
            }
        }
        // No retry timer or Space switch. Events confirm asynchronous moves; unconfirmed work stays journaled.
        let written = Set(jobs.map(\.id))
        var arrivedJobs: [FrameJob] = []
        for entry in entries.values {
            guard let target = targets[entry.id], let frame = desiredFrames[entry.id],
                  let state = read(entry.id), state.pid == entry.pid, state.space == target,
                  displays.contains(where: { $0.currentSpace == target }), state.isOnScreen,
                  !state.frame.isClose(to: frame, within: 2),
                  !written.contains(entry.id) else { continue }
            arrivedJobs.append(FrameJob(pid: entry.pid, id: entry.id, frame: frame))
        }
        if !arrivedJobs.isEmpty { _ = write(arrivedJobs) }
        for entry in Array(entries.values) {
            guard let target = targets[entry.id], let frame = desiredFrames[entry.id] else { continue }
            guard problems[entry.id] == nil, let state = read(entry.id), state.pid == entry.pid,
                  state.space == target, state.frame.isClose(to: frame, within: 2) else {
                problems[entry.id] = problems[entry.id] ?? "frame or original Space not confirmed; kept for explicit recovery"
                continue
            }
            entries[entry.id] = nil
            restored += 1
        }
        carried = Set(entries.keys)
        save()
        for (id, problem) in problems.sorted(by: { $0.key < $1.key }) {
            fputs("recovery: window \(id): \(problem)\n", stderr)
        }
        let summary = "restored \(restored) of \(total) windows; \(entries.count) pending"
            + (closed == 0 ? "" : "; \(closed) closed")
        print("recovery: \(summary)")
        fflush(stdout)
        return summary
    }

    func returnSpaces(windows: [UInt32: Window], displays: [RecoveryDisplay]) -> [UInt32: UInt64] {
        let available = Set(displays.flatMap { $0.userSpaces })
        return entries.reduce(into: [:]) { result, pair in
            let entry = pair.value
            guard windows[entry.id]?.identity == entry.identity else { return }
            result[entry.id] = available.contains(entry.spaceID) ? entry.spaceID : windows[entry.id]?.spaceID
        }
    }

    // MARK: Journal

    /// Keeps a previous session's entries whose window still exists, owned by the same app, and first seen
    /// after that app launched. Anything else is a reused window ID and is never touched.
    private func carryOver() {
        guard let model, let data = try? Data(contentsOf: journalURL),
              let journal = try? decoder.decode(Journal.self, from: data), journal.pid != getpid() else { return }
        for var entry in journal.windows {
            guard let window = model.windows[entry.id] else { continue }
            let launched = NSRunningApplication(processIdentifier: entry.pid)?.launchDate ?? .distantPast
            guard window.pid == entry.pid, window.bundleID == entry.bundleID, launched <= entry.firstSeen else {
                fputs("recovery: window \(entry.id) is now another window, not restoring it\n", stderr)
                continue
            }
            // From here on the live model's identity is the one to match.
            entry.firstSeen = window.identity.firstSeen
            entries[entry.id] = entry
            carried.insert(entry.id)
        }
        print("recovery: \(carried.count) windows from the previous session (pid \(journal.pid)) can be restored")
        save()
    }

    /// Capture before classification, rules, or tiling can alter a new window.
    func recordBeforeManaging(_ window: Window) {
        guard recording, window.isNormal, entries[window.id]?.identity != window.identity else { return }
        let display = AppState.shared.displays.display(containingSpace: window.spaceID).map(RecoveryDisplay.init)
        capture(window, display: display)
    }

    func capture(_ window: Window, display: RecoveryDisplay?) {
        guard recording, window.isNormal, entries[window.id]?.identity != window.identity else { return }
        carried.remove(window.id)
        entries[window.id] = Entry(id: window.id, pid: window.pid, bundleID: window.bundleID,
                                  firstSeen: window.identity.firstSeen, frame: window.frame, spaceID: window.spaceID,
                                  displayUUID: display?.uuid, displayVisibleFrame: display?.visibleFrame)
        saveSoon()
    }

    /// Prune closed identities even while disabled. Frame restoration always needs an explicit command.
    private func record() {
        guard let model else { return }
        let before = entries.count
        entries = entries.filter { model.windows[$0.key]?.identity == $0.value.identity }
        carried.formIntersection(entries.keys)
        if entries.count != before { saveSoon() }
        guard recording else { return }
        for window in model.windows.values { recordBeforeManaging(window) }
    }

    private func saveSoon() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    /// Writes the journal, or removes the file when nothing is journaled.
    private func save() {
        guard !entries.isEmpty else {
            if FileManager.default.fileExists(atPath: journalURL.path) {
                do { try FileManager.default.removeItem(at: journalURL) }
                catch { fputs("recovery: could not remove completed journal: \(error.localizedDescription)\n", stderr) }
            }
            return
        }
        let journal = Journal(pid: getpid(), launched: launched, windows: entries.values.sorted { $0.id < $1.id })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(journal).write(to: journalURL, options: .atomic)
        } catch {
            fputs("recovery: could not save unfinished windows: \(error.localizedDescription)\n", stderr)
        }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    // MARK: Restoring

    private func readWindow(_ id: UInt32) -> RecoveryWindowState? {
        let info = dinky_window_info(id)
        guard info.exists else { return nil }
        let listed = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        let onScreen = listed.contains {
            ($0[kCGWindowNumber as String] as? UInt32) == id
                && ($0[kCGWindowOwnerPID as String] as? Int32) == info.pid
                && ($0[kCGWindowIsOnscreen as String] as? Bool) == true
        }
        return RecoveryWindowState(pid: info.pid, space: dinky_window_space_id(id), frame: info.frame,
                                   isOnScreen: info.level == 0 && info.isDocument && info.isVisible && !info.isMinimized && onScreen)
    }

    /// One frame batch in current stacking order, without raising or moving windows between Spaces.
    private func writeFrames(_ jobs: [FrameJob]) -> [FrameResult] {
        guard !jobs.isEmpty else { return [] }
        let stacking = Dictionary(onScreenOrder().enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let layout = Layout(frames: Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.frame) }),
                            order: jobs.map(\.id).sorted { (stacking[$0] ?? .max) < (stacking[$1] ?? .max) })
        let completion = RecoveryFrameCompletion()
        applier.apply(layout, pids: Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.pid) }), raiseWindows: false) {
            completion.complete($0)
        }
        return completion.wait(until: .now() + 3)
    }

}

/// `dinky recover`: restores unfinished untiled frames and surviving original Spaces.
func runRecover() -> Int32 { sendAndPrint("recover") }
