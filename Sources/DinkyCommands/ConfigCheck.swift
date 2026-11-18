import DinkyConfig

/// A problem `dinky doctor` found in a config that still parsed.
public struct ConfigFinding: Equatable, CustomStringConvertible {
    public enum Level: String { case error, warning }
    public let level: Level
    public let message: String

    public var description: String { "\(level.rawValue): \(message)" }
}

/// Checks a parsed config beyond what parsing guarantees: parser warnings, every binding and rule command in the
/// vocabulary, every `mode X` names a mode, a main mode, and no `[workspace.N]` table past the last workspace.
public func checkConfig(_ config: Config) -> [ConfigFinding] {
    var findings = config.warnings.map { ConfigFinding(level: .warning, message: $0.description) }
    func check(_ commands: [String], at place: String) {
        for text in commands {
            do {
                if case .mode(let name) = try Command.parse(text), config.modes[name] == nil {
                    findings.append(.init(level: .error, message: "\(place): '\(text)' names a mode that is not in the config"))
                }
            } catch {
                findings.append(.init(level: .error, message: "\(place): \(error)"))
            }
        }
    }
    if config.modes["main"] == nil {
        findings.append(.init(level: .warning, message: "no [mode.main]: no key bindings are active"))
    }
    // Harmless, so parsing accepts it; but a typo or a lowered `workspaces` leaves settings that never apply.
    for number in config.workspaceLayouts.keys.sorted() where number > config.workspaces {
        findings.append(.init(level: .warning, message: "workspace.\(number): past the last workspace (\(config.workspaces)), so it does nothing"))
    }
    for (name, mode) in config.modes.sorted(by: { $0.key < $1.key }) {
        for (combo, binding) in mode.bindings.sorted(by: { $0.key.description < $1.key.description }) {
            check(binding.commands, at: "mode.\(name).\(combo)")
        }
    }
    for (i, rule) in config.rules.enumerated() {
        check(rule.run, at: "rules[\(i)].run")
    }
    check(config.hooks.startup, at: "hooks.startup")
    check(config.hooks.workspaceChanging, at: "hooks.workspace-changing")
    check(config.hooks.workspaceChanged, at: "hooks.workspace-changed")
    check(config.hooks.focusChanged, at: "hooks.focus-changed")
    check(config.hooks.modeChanged, at: "hooks.mode-changed")
    check(config.hooks.displayChanged, at: "hooks.display-changed")
    return findings
}
