import AppKit
import DinkyConfig

// The non-activating, always-on-top view of ConfigIssueList. AppState owns the reload truth; this panel only
// renders it and asks DinkyConfig to apply the selected edits.
final class ConfigIssuesWindow: NSPanel {
    static let shared = ConfigIssuesWindow()

    private var issueList = ConfigIssueList()
    private var currentIssues: [ConfigIssue] = []
    private var canPresent = false
    private var applicationError: String?
    private let panelWidth: CGFloat = 420

    private init() {
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "dinky config"
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    func allowPresentation() {
        canPresent = true
        refreshPresentation()
    }

    func update(error: ConfigError?, warnings: [ConfigWarning]) {
        currentIssues = ConfigIssues.issues(error: error, warnings: warnings)
        refreshPresentation()
    }

    private func refreshPresentation() {
        guard canPresent else { return }
        guard !currentIssues.isEmpty else {
            issueList = ConfigIssueList()
            close()
            return
        }
        if isVisible {
            issueList = issueList.updated(with: currentIssues) ?? ConfigIssueList()
        } else {
            issueList = ConfigIssueList(rows: currentIssues.map { .init(issue: $0, fixed: false) })
        }
        applicationError = nil
        rebuild()
        orderFrontRegardless()
    }

    private func rebuild() {
        let rows = issueList.rows.map(rowView)
        let issueStack = NSStackView(views: rows)
        issueStack.orientation = .vertical
        issueStack.alignment = .leading
        issueStack.spacing = 12

        let document = NSView()
        document.addSubview(issueStack)
        issueStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            issueStack.topAnchor.constraint(equalTo: document.topAnchor),
            issueStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            issueStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            issueStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        document.frame = NSRect(x: 0, y: 0, width: panelWidth - 40,
                                height: issueStack.fittingSize.height)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = issueStack.fittingSize.height > maximumIssueHeight
        scroll.drawsBackground = false
        scroll.documentView = document

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addView(NSButton(title: "Dismiss", target: self, action: #selector(dismiss)), in: .leading)
        switch issueList.action {
        case .applyAll:
            buttons.addView(NSButton(title: "Apply All", target: self, action: #selector(applyAll)), in: .trailing)
        case .applySuggestions:
            buttons.addView(NSButton(title: "Apply Suggestions", target: self, action: #selector(applySuggestions)), in: .trailing)
        case .dismissOnly:
            break
        }

        let main = NSStackView(views: [scroll, buttons])
        main.orientation = .vertical
        main.alignment = .width
        main.spacing = 12
        main.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        if let applicationError {
            let error = NSTextField(wrappingLabelWithString: applicationError)
            error.textColor = .systemRed
            main.insertArrangedSubview(error, at: 0)
        }

        let issueHeight = min(issueStack.fittingSize.height, maximumIssueHeight)
        scroll.heightAnchor.constraint(equalToConstant: max(issueHeight, 1)).isActive = true
        contentView = main
        setContentSize(NSSize(width: panelWidth, height: main.fittingSize.height))
        position()
    }

    private var maximumIssueHeight: CGFloat {
        let visibleHeight = AppState.shared.displays.focusedDisplay()?.visibleArea.height ?? 600
        return visibleHeight * 0.6
    }

    private func rowView(_ row: ConfigIssueList.Row) -> NSView {
        let title = row.issue.line.map { "Line \($0) — \(row.issue.path)" }
            ?? (row.issue.path.isEmpty ? "Configuration error" : "Configuration error — \(row.issue.path)")
        let titleLabel = NSTextField(wrappingLabelWithString: row.issue.isError ? "Error: \(title)" : title)
        titleLabel.preferredMaxLayoutWidth = panelWidth - 40
        let message = NSTextField(wrappingLabelWithString: row.issue.message)
        message.preferredMaxLayoutWidth = panelWidth - 40
        let stack = NSStackView(views: [titleLabel, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        if let fix = row.issue.fix {
            let suggestion = NSTextField(wrappingLabelWithString: "Suggestion: replace '\(fix.replace)' with '\(fix.with)'")
            suggestion.preferredMaxLayoutWidth = panelWidth - 40
            stack.addArrangedSubview(suggestion)
        } else {
            let reference = NSButton(title: "Configuration reference", target: self, action: #selector(openDocumentation))
            reference.isBordered = false
            reference.contentTintColor = .linkColor
            reference.alignment = .left
            stack.addArrangedSubview(reference)
        }
        if row.fixed {
            for view in stack.arrangedSubviews {
                view.alphaValue = 0.5
                if let field = view as? NSTextField {
                    field.attributedStringValue = NSAttributedString(string: field.stringValue, attributes: [
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue
                    ])
                }
            }
        }
        return stack
    }

    private func position() {
        guard let display = AppState.shared.displays.focusedDisplay(),
              let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let area = display.visibleArea
        let height = frame.height
        setFrameOrigin(NSPoint(x: area.maxX - panelWidth - 12,
                                y: primaryHeight - area.minY - height - 12))
    }

    @objc private func dismiss() {
        close()
    }

    @objc private func applyAll() {
        apply(issueList.rows.filter { !$0.fixed }.map(\.issue))
    }

    @objc private func applySuggestions() {
        apply(issueList.rows.filter { !$0.fixed && $0.issue.fix != nil }.map(\.issue))
    }

    private func apply(_ issues: [ConfigIssue]) {
        do {
            // On success the config watcher reloads the file, and that reload refreshes this window.
            let applied = try ConfigIssues.applyFixes(issues, at: Config.userConfigURL)
            applicationError = applied.isEmpty
                ? "No suggestion matched the file any more; it may have changed since it loaded. Edit it by hand."
                : nil
            rebuild()
        } catch {
            applicationError = error.localizedDescription
            rebuild()
            orderFrontRegardless()
        }
    }

    @objc private func openDocumentation() {
        NSWorkspace.shared.open(ConfigIssues.documentationURL)
    }
}
