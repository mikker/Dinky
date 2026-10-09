import AppKit
import DinkyCommands
import DinkyConfig
import DinkyLayout
import DinkyPrivate

/// What the coordinator knows about a window it has classified. `space` is nil off the user Spaces
/// (on a native full-screen Space), where nothing is tiled.
struct Placement {
    let floating: Bool
    var space: UInt64?
}

// The serialized owner of layout state: one Workspace per Space, keyed by Space ID, fed by the window and
// display models, applied through the frame applier. Every change marks the trees it touched dirty; `flush` applies the
// dirty trees that are on screen. Main thread only.
final class Coordinator {
    let model = WindowModel()
    var enabled = true {
        didSet {
            if !enabled { applier.cancel(); animator.cancel() }
            if enabled, !oldValue { reconcile() }
        }
    }

    let displays: DisplayModel
    private(set) var config: Config
    let applier = FrameApplier()
    private lazy var animator = Animator(applier: applier)
    private var borders: BorderManager?
    func isBorderWindow(_ id: WindowID) -> Bool { borders?.isBorder(id) ?? false }
    private(set) var workspaces: [UInt64: Workspace] = [:]
    var placements: [WindowID: Placement] = [:]
    var dirty: Set<UInt64> = []
    /// Classification attempts for windows whose AX element has not appeared yet.
    var attempts: [WindowID: Int] = [:]
    /// Newly shown windows at the exact frame of a tile of their app, held out of the trees for a moment in case
    /// they are a tab switch: by newcomer, the tile's window. See Tabs.swift.
    var heldTabs: [WindowID: WindowID] = [:]
    /// Newcomers held once and not confirmed as tabs. They are tiled like any window from then on.
    var notTabs: Set<WindowID> = []
    /// New windows not yet classified, and the display that had focus when they first showed. See Adoption.swift.
    var adoptTargets: [WindowID: String] = [:]
    /// New windows on their way to the focused display, kept out of the trees until they arrive.
    var adopting: Set<WindowID> = []
    /// The tiled window being dragged with the mouse, until the button is released. See Drag.swift.
    var dragging: WindowID?
    lazy var placeholders = DragPlaceholders()
    /// Called when the focused window changes.
    var onFocusChange: (() -> Void)?
    private(set) var lastFocused: WindowID = 0
    /// The focused display just before `lastFocused` took focus.
    private(set) var displayBeforeFocus: String?
    /// A window dinky just focused, and until when focus reads that disagree are taken as stale.
    private var focusing: (id: WindowID, until: Date)?
    /// Trees to place without gliding the next time they are applied: after displays come or go, apps have
    /// moved the windows of Spaces that were not on screen to frames of their own, and a glide from there
    /// would only show the mess.
    private var snap: Set<UInt64> = []

    init(displays: DisplayModel, config: Config) {
        self.displays = displays
        self.config = config
    }

    func start() {
        model.observe { [weak self] event in self?.handle(event) }
        animator.onArrive = { [weak self] ids in self?.borders?.arrived(ids) }
        var known = Set(displays.displays.map(\.uuid))
        displays.observe { [weak self] displays in
            guard let self else { return }
            let now = Set(displays.displays.map(\.uuid))
            if now != known { snap.formUnion(workspaces.keys) }
            known = now
            reconcile()
        }
        // A hidden app's windows can read as shown when their hide event arrives; re-read them once it is hidden.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reconcile() }
        }
        guard model.start() else {
            fputs("coordinator: no WindowServer events\n", stderr)
            return
        }
        update(config: config)
        reconcile()
    }

    func update(config: Config) {
        self.config = config
        animator.setDuration(ms: config.animations.durationMs)
        if config.borders.enabled {
            borders = borders ?? BorderManager(config: config.borders, model: model,
                                               isAnimating: { [unowned self] id in animator.isAnimating(id) })
            borders?.update(config: config.borders)
        } else {
            borders = nil
        }
        configureWorkspaces()
        // A workspace switched to/from floating must release/acquire its existing windows too.
        for window in model.windows.values { track(window) }
        fitToDisplays()
        dirty.formUnion(workspaces.keys)
        flush()
    }

    // MARK: Events

    private func handle(_ event: WindowEvent) {
        // Detected here, not in the border manager, so hover focus stands down even with borders off.
        if MissionControl.shared.update(from: model) { borders?.missionControlChanged() }
        borders?.handle(event)
        if let window = event.window {
            event.change == .removed ? forget(window.id) : track(window)
            if [.windowMove, .windowResize].contains(event.kind) { noteFrameChange(of: window.id) }
        }
        if [.frontApp, .windowReorder, .windowCreate].contains(event.kind) { syncFocus() }
        if [.frontApp, .windowReorder].contains(event.kind) {
            // The front window settles a few ms after the event, as the border manager also knows: Cmd-` or a click
            // between one app's windows can report the previous window still in front.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
                self?.syncFocus()
                self?.flush()
            }
        }
        AppState.shared.numbers.recoverAfterWindowEvent()
        flush()
    }

    /// Re-reads every window and display, moves windows to the trees of the Spaces they are on now
    /// (so a window dragged to another Space stays there), and re-applies every tree on screen. The model
    /// publishes every window it re-reads, so `handle` tracks and forgets them. Empty trees of Spaces that
    /// no longer exist are dropped.
    func reconcile() {
        configureWorkspaces()
        model.reconcile()
        fitToDisplays()
        workspaces = workspaces.filter { displays.display(containingSpace: $0.key) != nil || !$0.value.windows.isEmpty }
        syncFocus()
        dirty.formUnion(workspaces.keys)
        flush()
    }

    /// Forgets every minimum size learned and re-applies every tree, so windows are asked for their tiles again.
    func clearMinimumSizes() {
        applier.forgetMinimums()
        dirty.formUnion(workspaces.keys)
        flush()
    }

    /// Bounds and gaps of every tree from the display its Space is on now, which can have moved, resized or become
    /// main, or be another display, as when macOS moves a disconnected display's Spaces. A tree whose Space is on
    /// no display is left as it is.
    private func fitToDisplays() {
        for key in workspaces.keys {
            guard let display = displays.display(containingSpace: key) else { continue }
            workspaces[key]!.bounds = display.visibleArea
            workspaces[key]!.gaps = gaps(on: display)
        }
    }

    /// Carries a Space's tree to another Space, before its windows are moved there, so they arrive in the layout
    /// they had. Kept when the other Space already has a tree with windows.
    func moveTree(from: UInt64, to: UInt64) {
        guard from != to, let display = displays.display(containingSpace: to), workspaces[to]?.windows.isEmpty != false,
              var tree = workspaces.removeValue(forKey: from) else { return }
        tree.bounds = display.visibleArea
        tree.gaps = gaps(on: display)
        workspaces[to] = tree
        for (id, placement) in placements where placement.space == from { placements[id]!.space = to }
    }

    /// Resolve layout settings by a Space's current numbered position, which can change when Spaces are reordered.
    private func configureWorkspaces() {
        for key in workspaces.keys {
            workspaces[key]!.accordionPadding = CGFloat(config.accordion.padding)
            workspaces[key]!.autoOrientAccordions = config.accordion.orientation == .auto
            workspaces[key]!.setAlgorithm(algorithm(settings(for: key)))
        }
    }

    private func gaps(on display: Display) -> DinkyLayout.Gaps {
        DinkyLayout.Gaps(config.gaps(for: displays.monitor(display)))
    }

    /// The settings of the Space's workspace, by its current number.
    private func settings(for space: UInt64) -> WorkspaceSettings {
        config.settings(forWorkspace: AppState.shared.numbers.number(of: space))
    }

    private func algorithm(_ settings: WorkspaceSettings) -> TilingAlgorithm {
        let expand: FixedExpansion = switch settings.expand {
        case .rows: .rows
        case .columns: .columns
        case .accordion: .accordion
        }
        return switch settings.layout {
        case .tiles, .dwindle: .dwindle(.tiles)
        case .accordion: .dwindle(.accordion)
        case .fixed: .fixed(rows: settings.rows, columns: settings.columns, expand: expand)
        }
    }

    /// Classifies a window the first time it is on screen, then keeps it in the tree of its current Space
    /// while it is shown: minimized windows, windows of hidden apps and inactive tabs read as minimized.
    func track(_ window: Window) {
        if AppState.shared.numbers.deferTiling(window) {
            // Release the old tile without classifying or adopting the window on its temporary Space.
            if let space = placements[window.id]?.space {
                edit(space) { $0.remove(window.id) }
                placements[window.id]?.space = nil
                animator.forget(window.id)
            }
            return
        }
        if placements[window.id] == nil {
            // AX only lists windows on a Space that is on screen; the rest are classified when theirs is.
            guard window.isNormal, isVisible(window.spaceID) else { return }
            // Once, on the first classification attempt, not again on its retries.
            if attempts[window.id] == nil { noteFirstShowing(window) }
            guard let classification = classify(window) else { return }
            placements[window.id] = Placement(floating: classification.floating, space: nil)
            if !classification.runsRules, adopt(window) { return }
        }
        guard !adopting.contains(window.id), !placements[window.id]!.floating else { return }
        let old = placements[window.id]!.space
        if let old, window.isMinimized || !window.isOrderedIn, takeOverTile(of: window.id, in: old) {
            placements[window.id]!.space = nil
            return
        }
        let new = window.isMinimized ? nil : key(of: window)
        guard old != new, heldTabs[window.id] == nil else { return }
        if let old { edit(old) { $0.remove(window.id) } }
        // A window coming from another Space's tree is moving, not switching tabs: tabs share a Space.
        if let new, old == nil, holdAsTab(window, in: new) { return }
        if let new { edit(new) { $0.insert(window.id) } }
        placements[window.id]!.space = new
    }

    private func forget(_ id: WindowID) {
        attempts[id] = nil
        adoptTargets[id] = nil
        adopting.remove(id)
        applier.forget(id)
        animator.forget(id)
        heldTabs[id] = nil
        notTabs.remove(id)
        guard let placement = placements.removeValue(forKey: id), let space = placement.space,
              !takeOverTile(of: id, in: space) else { return }
        edit(space) { $0.remove(id) }
    }

    /// The front app's frontmost document window on a current Space.
    var focusedWindow: WindowID { dinky_border_focused_window() }

    /// Focuses a window, raising it and activating its app. For a moment after, focus events that still
    /// report the previous window are ignored, so they do not pull the trees back to it.
    func focus(_ id: WindowID) {
        guard let window = model.windows[id] else { return }
        focusing = (id, Date() + 0.5)
        focusWindow(pid: window.pid, id: id)
    }

    /// Follows focus into the trees, so new windows land beside the focused one and accordions show it.
    private func syncFocus() {
        let id = focusedWindow
        if id != lastFocused {
            // Before the override goes: a new window can take focus before it shows. See Adoption.swift.
            displayBeforeFocus = displays.focusedDisplay(window: lastFocused)?.uuid
            lastFocused = id
            // Only a window takes focus from a display focused without one, not an app with no window here.
            if id != 0 { displays.focusOverride = nil }
            onFocusChange?()
        }
        if let focusing, focusing.id != id, Date() < focusing.until { return }
        focusing = nil
        guard let key = placements[id]?.space, workspaces[key]?.focused != id else { return }
        edit(key) { $0.focus(id) }
    }

    /// The tree of a user Space, numbered workspace or not, created on first use. Nil for full-screen Spaces.
    private func key(of window: Window) -> UInt64? {
        guard let display = displays.display(containingSpace: window.spaceID),
              display.userSpaces.contains(window.spaceID) else { return nil }
        let settings = settings(for: window.spaceID)
        guard settings.tiling else { return nil }
        let key = window.spaceID
        if workspaces[key] == nil {
            workspaces[key] = Workspace(bounds: display.visibleArea, gaps: gaps(on: display),
                                        accordionPadding: CGFloat(config.accordion.padding),
                                        autoOrientAccordions: config.accordion.orientation == .auto,
                                        algorithm: algorithm(settings))
        }
        return key
    }

    /// Runs `change` on a tree and marks it dirty if its layout changed. Returns what `change` returned.
    @discardableResult
    func edit<T>(_ key: UInt64, _ change: (inout Workspace) -> T) -> T? {
        guard var workspace = workspaces[key] else { return nil }
        let before = workspace.layout()
        let result = change(&workspace)
        workspaces[key] = workspace
        if workspace.layout() != before { dirty.insert(key) }
        return result
    }

    // MARK: Applying

    func flush() {
        let keys = dirty
        dirty = []
        guard enabled else { return }
        for key in keys where isVisible(key) { apply(key) }
    }

    /// Whether the Space is a display's current one.
    func isVisible(_ space: UInt64) -> Bool {
        displays.displays.contains { $0.currentSpaceID == space }
    }

    /// Writes the tree's frames around the minimum sizes windows have shown, then lets the applier raise
    /// overlapping windows (accordion, fullscreen) into the tree's stacking, with its focused window on top.
    /// Nothing is activated: the tree follows macOS's focus (`syncFocus`) and commands that choose a window
    /// focus it themselves, so a pass, which may have started before the latest focus change, must not.
    /// Minimum sizes found in a pass are laid out around all at once, when that moves anything.
    private func apply(_ key: UInt64) {
        guard var workspace = workspaces[key] else { return }
        workspace.minimumSizes = minimumSizes(in: workspace)
        workspaces[key] = workspace
        let layout = workspace.layout()
        let pids = Dictionary(uniqueKeysWithValues: layout.order.compactMap { id in model.windows[id].map { (id, $0.pid) } })
        let write = { [weak self] in
            guard let self else { return }
            applier.apply(layout, pids: pids, front: workspace.focused) { [weak self] results in
                DispatchQueue.main.async {
                    guard let self, self.enabled else { return }
                    self.animator.noteLanded(results)
                    self.edit(key) { $0.minimumSizes = self.minimumSizes(in: $0) }
                    self.flush()
                    // A refusal counts on the second pass; run it soon rather than on the next event.
                    if !self.applier.unconfirmedMinimums.isDisjoint(with: layout.order) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                            self?.dirty.insert(key)
                            self?.flush()
                        }
                    }
                }
            }
        }
        guard animates, snap.remove(key) == nil else { return write() }
        // Stacking first, so the window coming to the front of an accordion slides in on top.
        applier.raiseIntoOrder(layout, pids: pids, front: workspace.focused)
        let starts = Dictionary(uniqueKeysWithValues: layout.order.compactMap { id in
            id == dragging ? nil : model.windows[id].map { (id, $0.frame) }
        })
        animator.animate(key, from: starts, to: layout.frames, pids: pids, then: write)
    }

    /// Whether passes glide windows to their tiles.
    private var animates: Bool {
        config.animations.enabled && config.animations.durationMs > 0
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Whether dinky is gliding the window to its tile right now.
    func isAnimating(_ id: WindowID) -> Bool { animator.isAnimating(id) }

    /// The windows dinky is gliding to their tiles right now.
    var animatingWindows: [WindowID] { animator.animating }

    private func minimumSizes(in workspace: Workspace) -> [WindowID: CGSize] {
        var sizes: [WindowID: CGSize] = [:]
        for id in workspace.windows { sizes[id] = applier.minimumSize(of: id, app: model.windows[id]?.bundleID) }
        return sizes
    }
}
