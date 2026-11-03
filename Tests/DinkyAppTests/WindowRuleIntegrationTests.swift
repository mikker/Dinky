import Foundation
import Testing
import DinkyCommands
import DinkyConfig
@testable import dinky

/// No model subscriptions, AX reads, dispatcher execution or app singleton: only classification facts and
/// captured queued commands. IDs and PIDs are synthetic; the coordinator never starts.
struct WindowRuleIntegrationTests {
    private let window = Window(identity: .init(id: 900_059, pid: -1, firstSeen: .distantPast),
                                appName: "Editor", bundleID: "com.example.editor")

    private func coordinator(_ extra: String = "") throws -> Coordinator {
        let config = try Config.parse("""
        [[rules]]
        app-id = 'com.example.editor'
        exclude-window-identifier = '^Settings$'
        run = ['layout tiling', 'move-window-to-workspace 4 --follow', 'exec-and-forget echo document']
        [[rules]]
        app-id = 'com.example.editor'
        window-identifier = '^Settings$'
        run = 'layout floating'
        \(extra)
        """)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("dinky-pr59-\(UUID())")
        return Coordinator(displays: DisplayModel(), config: config, applier: FrameApplier(supportURL: support))
    }

    @Test func auxiliaryExclusionSkipsAllCommandsInTheRule() throws {
        let owner = try coordinator()
        var queued: [Command] = []
        let result = owner.classify(window, kind: .normal, resizable: true, title: "Untitled",
                                    identifier: "sEtTiNgS", lacksFullscreen: false) { command, _ in
            queued.append(command)
        }
        #expect(result.floating)
        #expect(!result.runsRules)
        #expect(queued.isEmpty) // Neither workspace move nor exec; not just the layout command.
        #expect(owner.windowIdentifiers[window.id] == "sEtTiNgS")
    }

    @Test func documentQueuesCommandsInOrderForTheClassifiedWindow() throws {
        let owner = try coordinator()
        var queued: [Command] = []
        var targets: [UInt32] = []
        let result = owner.classify(window, kind: .normal, resizable: true, title: "Untitled",
                                    identifier: "Document", lacksFullscreen: true) { command, id in
            queued.append(command)
            targets.append(id)
        }
        #expect(!result.floating) // Explicit tiling wins over the fullscreen heuristic.
        #expect(result.runsRules)
        #expect(queued == [try Command.parse("move-window-to-workspace 4 --follow"),
                           try Command.parse("exec-and-forget echo document")])
        #expect(targets == [window.id, window.id])
        #expect(owner.windowIdentifiers[window.id] == "Document")
    }

    @Test(arguments: [nil, "Unknown"] as [String?])
    func unknownIdentifierKeepsBroadRulesButNotPositiveSelectors(_ identifier: String?) throws {
        let owner = try coordinator("""
        [[rules]]
        window-identifier = '^Document$'
        run = 'move-window-to-workspace 8'
        """)
        var queued: [Command] = []
        let result = owner.classify(window, kind: .normal, resizable: true, title: "Untitled",
                                    identifier: identifier, lacksFullscreen: false) { command, _ in
            queued.append(command)
        }
        #expect(!result.floating)
        #expect(result.runsRules)
        #expect(queued == [try Command.parse("move-window-to-workspace 4 --follow"),
                           try Command.parse("exec-and-forget echo document")])
        #expect(owner.windowIdentifiers[window.id] == identifier)
    }

    @Test(arguments: [WindowKind.dialog, .sheet, .panel])
    func identifierTilingCannotOverrideWindowKind(_ kind: WindowKind) throws {
        let owner = try coordinator()
        let result = owner.classify(window, kind: kind, resizable: true, title: "Untitled",
                                    identifier: "Document", lacksFullscreen: false) { _, _ in }
        #expect(result.floating)
    }

    @Test func identifierTilingCannotOverrideFixedSize() throws {
        let owner = try coordinator()
        let result = owner.classify(window, kind: .normal, resizable: false, title: "Untitled",
                                    identifier: "Document", lacksFullscreen: false) { _, _ in }
        #expect(result.floating)
    }

    @Test func lastMatchingLayoutWinsWithoutQueuingLayoutCommands() throws {
        let owner = try coordinator("""
        [[rules]]
        window-identifier = '^Document$'
        run = ['layout floating', 'layout tiling', 'layout floating']
        """)
        var queued: [Command] = []
        let result = owner.classify(window, kind: .normal, resizable: true, title: "Untitled",
                                    identifier: "Document", lacksFullscreen: false) { command, _ in
            queued.append(command)
        }
        #expect(result.floating)
        #expect(result.runsRules)
        #expect(queued.count == 2)
    }

    @Test func forgettingRemovesIdentifierEvenWithoutPlacement() throws {
        let owner = try coordinator()
        _ = owner.classify(window, kind: .normal, resizable: true, title: "Untitled",
                           identifier: "Settings", lacksFullscreen: false) { _, _ in }
        #expect(owner.placements[window.id] == nil)
        #expect(owner.windowIdentifiers[window.id] == "Settings")
        owner.forget(window.id)
        #expect(owner.windowIdentifiers[window.id] == nil)
        owner.forget(window.id) // Forgetting an already-forgotten window is harmless.
        #expect(owner.windowIdentifiers.isEmpty)
    }

    @Test func missingIdentifierClearsPreviouslyCachedValue() throws {
        let owner = try coordinator()
        for identifier in ["Settings", nil] as [String?] {
            _ = owner.classify(window, kind: .normal, resizable: true, title: "Untitled",
                               identifier: identifier, lacksFullscreen: false) { _, _ in }
            #expect(owner.windowIdentifiers[window.id] == identifier)
        }
    }
}
