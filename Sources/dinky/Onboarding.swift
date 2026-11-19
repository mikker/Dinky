import AppKit
import DinkyPrivate
import ServiceManagement

// First-run flow. Step 1 waits for Accessibility, which dinky needs to move windows and to install its
// event tap. Then, each shown once, offers to turn off macOS's own "switch to a Space with open windows"
// and explains manual desktop setup on systems without automatic Space lifecycle support.
final class Onboarding: NSObject {
    private static let swooshAskedKey = "onboarding-asked-auto-swoosh"
    private static let manualSpacesExplainedKey = "onboarding-explained-manual-spaces"
    private var window: NSWindow?
    private var timer: Timer?
    private var onTrusted: () -> Void = {}

    // Calls `onTrusted` once Accessibility is granted, right away if it already is.
    func run(onTrusted: @escaping () -> Void) {
        self.onTrusted = onTrusted
        if isTrusted() { trusted() } else { showAccessibilityStep() }
    }

    private func isTrusted() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary)
    }

    private func trusted() {
        onTrusted()
        if shouldAskAboutSwoosh() { showSwooshStep() } else { finish() }
    }

    // MARK: Step 1, Accessibility

    private func showAccessibilityStep() {
        show(title: "dinky needs Accessibility",
             text: "dinky moves and tiles windows through the Accessibility API. Turn dinky on under "
                 + "Privacy & Security, Accessibility. This window moves on by itself once it is allowed.",
             buttons: [button("Open Accessibility Settings", #selector(openAccessibility))])
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isTrusted() else { return }
            self.timer?.invalidate()
            self.trusted()
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Step 2, switch to a Space with open windows

    private func shouldAskAboutSwoosh() -> Bool {
        (dockSetting("workspaces-auto-swoosh") ?? true) && !UserDefaults.standard.bool(forKey: Onboarding.swooshAskedKey)
    }

    private func showSwooshStep() {
        show(title: "Faster Cmd-Tab",
             text: "macOS's \"When switching to an application, switch to a Space with open windows\" setting "
                 + "slides slowly to the app's Space on Cmd-Tab. With it off, dinky can follow the switch instantly while enabled. "
                 + "This stays off after dinky quits. To switch Spaces without dinky, turn it back on in "
                 + "System Settings > Desktop & Dock > Mission Control. Turning it off restarts the Dock.",
             buttons: [button("Turn It Off", #selector(turnOffSwoosh)), button("Leave It", #selector(leaveSwoosh))])
    }

    @objc private func turnOffSwoosh() {
        shell("/usr/bin/defaults", "write", "com.apple.dock", "workspaces-auto-swoosh", "-bool", "false")
        shell("/usr/bin/killall", "Dock")
        leaveSwoosh()
    }

    @objc private func leaveSwoosh() {
        UserDefaults.standard.set(true, forKey: Onboarding.swooshAskedKey)
        finish()
    }

    // MARK: Manual desktop setup

    private func finish() {
        if !dinky_can_manage_spaces(), !UserDefaults.standard.bool(forKey: Onboarding.manualSpacesExplainedKey) {
            showSpaceManagementStep()
        } else {
            close()
        }
    }

    /// Also available from the menu after the first-run explanation has been dismissed.
    func showSpaceManagementStep() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        show(title: "Set up desktops in Mission Control",
             text: "On macOS \(major), dinky uses existing desktops instead of creating or removing them. "
                 + "Press Control–↑ and add enough on each display to match your workspace configuration.",
             buttons: [button("Got It", #selector(acknowledgeManualSpaces)),
                       button("Open Mission Control", #selector(openMissionControl))])
        // Closing the window with its title-bar button also counts as having seen the explanation.
        UserDefaults.standard.set(true, forKey: Onboarding.manualSpacesExplainedKey)
    }

    @objc private func acknowledgeManualSpaces() {
        close()
    }

    @objc private func openMissionControl() {
        acknowledgeManualSpaces()
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
    }

    private func shell(_ path: String, _ args: String...) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: Window

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func show(title: String, text: String, buttons: [NSButton]) {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 15)
        let body = NSTextField(wrappingLabelWithString: text)
        body.preferredMaxLayoutWidth = 380
        body.widthAnchor.constraint(equalToConstant: 380).isActive = true
        buttons.first?.keyEquivalent = "\r"
        let row = NSStackView(views: buttons)
        let stack = NSStackView(views: [heading, body, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "dinky"
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.contentView = stack
        window?.setContentSize(NSSize(width: 420, height: stack.fittingSize.height))
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
        window = nil
    }
}

// Registers or unregisters dinky as a login item to match `start-at-login`. Only for the app bundle:
// a bare binary run from a shell is not a login item.
func applyStartAtLogin(_ wanted: Bool) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let service = SMAppService.mainApp
    do {
        if wanted, service.status != .enabled { try service.register() }
        if !wanted, service.status == .enabled { try service.unregister() }
    } catch {
        fputs("login item: \(error)\n", stderr)
    }
}
