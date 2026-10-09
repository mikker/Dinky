import Foundation
import Testing
import DinkyConfig
import TOMLDecoder
@testable import DinkyCommands

/// docs/schemas/dinky.json is written by hand; these keep it from drifting away from the code.
struct SchemaTests {
    private static let schema: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/schemas/dinky.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    private var definitions: [String: [String: Any]] { Self.schema["definitions"] as! [String: [String: Any]] }

    @Test func `Command pattern lists every command`() throws {
        let pattern = definitions["command"]!["pattern"] as! String
        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ text: String) -> Bool { regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        for doc in Command.all {
            #expect(matches(doc.name), "\(doc.name)")
            #expect(matches(doc.syntax), "\(doc.syntax)")
        }
        for bad in ["", "fly left", "workspaces 3", "layouts", "modes main"] {
            #expect(!matches(bad), "\(bad)")
        }
        // The alternation names exactly the commands, no more.
        let listed = pattern.split(separator: "(")[1].split(separator: ")")[0].split(separator: "|").map(String.init)
        #expect(Set(listed) == Set(Command.all.map(\.name)))
        #expect(listed.count == Command.all.count, "a command is listed twice")
    }

    @Test func `Key combo pattern matches every key name`() throws {
        let pattern = definitions["keyCombo"]!["pattern"] as! String
        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ text: String) -> Bool { regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        for name in KeyCombo.keyCodes.keys {
            #expect(matches(name), "\(name)")
            #expect(matches("alt-shift-\(name)"), "\(name)")
        }
        for bad in ["", "alt-", "hyper-a", "alt-hh", "pageUp", "f21", "keypad-", "alt--", "A"] {
            #expect(!matches(bad), "\(bad)")
        }
    }

    /// One value for every key the schema knows, table forms where a key takes a scalar or a table.
    private static let everyKey = """
        start-at-login = false
        workspaces = 4
        default-layout = 'accordion'
        default-tiling = true
        follow-app-activation = false
        float-windows-without-fullscreen = false
        window-max-aspect-ratio = 1.5
        ultrawide-min-aspect-ratio = 2.3
        tiling-alignment = 'center'

        [workspace-to-display]
        1 = 'main'
        2 = ['secondary', 'main']

        [workspace.2]
        tiling = true
        layout = 'fixed'
        columns = 2
        rows = 2
        expand = 'rows'

        [accordion]
        padding = 20
        orientation = 'keep'

        [gaps]
        inner.horizontal = 4
        inner.vertical = 6
        outer.top = 1
        outer.bottom = 2
        outer.left = 3
        outer.right = 4

        [display.main]
        window-max-aspect-ratio = 1.5
        ultrawide-min-aspect-ratio = 2.3
        tiling-alignment = 'right'
        gaps.inner = 2
        gaps.outer.top = 30
        gaps.outer.bottom = 0
        gaps.outer.left = 0
        gaps.outer.right = 0

        [display.secondary]
        window-max-aspect-ratio = 0.0
        ultrawide-min-aspect-ratio = 3.0
        tiling-alignment = 'left'
        gaps.inner.horizontal = 1
        gaps.inner.vertical = 1
        gaps.outer = 8

        [borders]
        enabled = true
        width = 2.5
        active-color = '#ff0000'
        inactive-color = '#00ff0080'
        order = 'above'
        exclude-apps = ['com.apple.finder']

        [focus-follows-mouse]
        enabled = true
        delay-ms = 50
        accordion-edges = false

        [animations]
        enabled = true
        duration-ms = 100

        [drag]
        placeholders = false

        [hooks]
        startup = 'exec-and-forget true'
        workspace-changing = ['exec-and-forget true']
        workspace-changed = []
        focus-changed = 'exec-and-forget true'
        mode-changed = 'exec-and-forget true'

        [[rules]]
        app-id = 'com.apple.Safari'
        app-name = 'safari'
        title = 'settings'
        kind = 'dialog'
        run = ['layout floating', 'move-window-to-workspace 2']

        [mode.main]
        alt-1 = 'workspace 1'
        alt-r = 'mode resize'

        [mode.resize]
        esc = ['mode main']
        h = 'resize width -50'
        """

    /// The scalar forms of the top-level gaps.
    private static let scalarGaps = """
        [gaps]
        inner = 5
        outer = 10
        """

    @Test func `Schema and config know every key`() throws {
        #expect(Config.defaultTOML.hasPrefix("#:schema \(Self.schema["$id"] as! String)\n"))
        for fixture in [Self.everyKey, Self.scalarGaps] {
            #expect(throws: Never.self) { try Config.parse(fixture) }
            try check(TOMLTable(source: fixture), Self.schema, at: "")
        }
        try check(TOMLTable(source: Config.defaultTOML), Self.schema, at: "")
        try covers(TOMLTable(source: Self.everyKey), Self.schema, at: "")
    }

    /// Every key in `table` is in the schema, at the same path.
    private func check(_ table: TOMLTable, _ schema: [String: Any], at path: String) {
        let schema = object(schema)
        let known = schema["properties"] as? [String: Any] ?? [:]
        for key in table.keys {
            let here = path.isEmpty ? key : "\(path).\(key)"
            guard let child = known[key] as? [String: Any] ?? schema["additionalProperties"] as? [String: Any] else {
                Issue.record("\(here) is not in the schema")
                continue
            }
            each(table, key, child, at: here, check)
        }
    }

    /// Every key in the schema is in `table`, at the same path, and every open-ended table has an entry.
    private func covers(_ table: TOMLTable, _ schema: [String: Any], at path: String) {
        let schema = object(schema)
        for (key, child) in schema["properties"] as? [String: [String: Any]] ?? [:] {
            let here = path.isEmpty ? key : "\(path).\(key)"
            guard table.contains(key: key) else {
                Issue.record("\(here) is in the schema but not the fixture")
                continue
            }
            each(table, key, child, at: here, covers)
        }
        if let child = schema["additionalProperties"] as? [String: Any] {
            #expect(!table.keys.isEmpty, "\(path) has no entries in the fixture")
            for key in table.keys { each(table, key, child, at: "\(path).\(key)", covers) }
        }
    }

    /// Calls `walk` on `table[key]` when it is a table, or on each table in it when it is an array of tables.
    private func each(_ table: TOMLTable, _ key: String, _ schema: [String: Any], at path: String,
                      _ walk: (TOMLTable, [String: Any], String) -> Void) {
        if let nested = try? table.table(forKey: key) {
            walk(nested, schema, path)
        } else if let items = object(schema)["items"] as? [String: Any], let array = try? table.array(forKey: key) {
            for i in 0..<array.count {
                if let item = try? array.table(atIndex: i) { walk(item, items, "\(path)[\(i)]") }
            }
        }
    }

    /// The object form of a schema node: follows a `$ref`, and of a `oneOf` of a scalar and a table, takes the table.
    private func object(_ schema: [String: Any]) -> [String: Any] {
        let schema = resolve(schema)
        let options = schema["oneOf"] as? [[String: Any]] ?? []
        return options.first { $0["properties"] != nil } ?? schema
    }

    /// Follows a local `$ref`.
    private func resolve(_ schema: [String: Any]) -> [String: Any] {
        guard let ref = schema["$ref"] as? String, ref.hasPrefix("#/definitions/") else { return schema }
        return definitions[String(ref.dropFirst("#/definitions/".count))]!
    }
}
