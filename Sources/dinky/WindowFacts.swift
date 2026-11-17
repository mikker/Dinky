import AppKit
import DinkyConfig

/// An AX snapshot, not placement: decorations may refresh this without running commands or touching trees.
struct WindowFacts: Equatable {
    var title: String
    var kind: WindowKind?
    var identifier: String?

    static func read(_ window: Window) -> WindowFacts? {
        guard let element = axWindow(pid: window.pid, wid: window.id, timeout: FrameApplier.timeout) else { return nil }
        return WindowFacts(title: axString(element, kAXTitleAttribute) ?? "",
                           kind: windowKind(subrole: axString(element, kAXSubroleAttribute)),
                           identifier: axString(element, "AXIdentifier").flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// Event-driven decoration facts. Opening AX windows get one bounded retry chain; unsupported identifiers
/// do not cause perpetual polling. No reads on move/resize frames, focus changes, queries or border drawing.
final class WindowFactsCache {
    private struct Entry {
        let identity: Window.Identity
        let facts: WindowFacts
    }
    private var entries: [UInt32: Entry] = [:]
    private struct Retry {
        let identity: Window.Identity
        let token = UUID()
    }
    private var retries: [UInt32: Retry] = [:]
    var onChange: ((UInt32) -> Void)?
    private let read: (Window) -> WindowFacts?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(read: @escaping (Window) -> WindowFacts? = WindowFacts.read,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.read = read
        self.schedule = schedule
    }

    /// ID-only diagnostic queries still use the cached snapshot, never a fresh AX lookup.
    func identifier(for id: UInt32) -> String? { entries[id]?.facts.identifier }

    func facts(for window: Window) -> WindowFacts? {
        guard entries[window.id]?.identity == window.identity else { return nil }
        return entries[window.id]?.facts
    }

    func record(_ window: Window, facts: WindowFacts) {
        let before = self.facts(for: window)
        entries[window.id] = Entry(identity: window.identity, facts: facts)
        if facts != before { onChange?(window.id) }
    }

    func forget(_ id: UInt32) {
        entries[id] = nil
        retries[id] = nil
    }

    /// A reload or fact-bearing event refreshes even established floating windows, never their placement.
    /// Failed AX reads retain a previous snapshot (e.g. a window on a hidden Space).
    func refresh(_ window: Window) {
        if let entry = entries[window.id], entry.identity != window.identity { forget(window.id) }
        if let pending = retries[window.id], pending.identity != window.identity { forget(window.id) }
        if readAndRecord(window) {
            retries[window.id] = nil
            return
        }
        guard retries[window.id] == nil else { return }
        let pending = Retry(identity: window.identity)
        retries[window.id] = pending
        retry(window, token: pending.token, remaining: 5)
    }

    /// Missing identifiers are common and harmless, but can also arrive a little after the AX window.
    private func readAndRecord(_ window: Window) -> Bool {
        guard let facts = read(window) else { return false }
        record(window, facts: facts)
        return facts.kind != nil && facts.identifier != nil
    }

    private func retry(_ window: Window, token: UUID, remaining: Int) {
        schedule(0.2) { [weak self] in
            guard let self, retries[window.id]?.token == token else { return }
            if readAndRecord(window) {
                retries[window.id] = nil
                return
            }
            if remaining > 1 { retry(window, token: token, remaining: remaining - 1) }
            else { retries[window.id] = nil }
        }
    }

    func decorates(_ window: Window, config: Borders) -> Bool {
        let facts = facts(for: window)
        return config.decorates(bundleID: window.bundleID, appName: window.appName, title: facts?.title ?? "",
                                kind: facts?.kind, identifier: facts?.identifier)
    }
}

/// Unknown AX facts stay unknown for decoration; placement retains its panel fallback.
func windowKind(subrole: String?) -> WindowKind? {
    switch subrole {
    case nil: nil
    case kAXStandardWindowSubrole: .normal
    case kAXDialogSubrole, kAXSystemDialogSubrole: .dialog
    case "AXSheet": .sheet
    default: .panel
    }
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}
