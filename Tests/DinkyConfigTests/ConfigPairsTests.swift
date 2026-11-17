import Testing
@testable import DinkyConfig

struct ConfigPairsTests {
    /// Each pair as line, dotted path, key text and value text, which reads better in a failure than ranges.
    private func summary(_ text: String) -> [String]? {
        configPairs(in: text)?.map { pair in
            "\(pair.line) \(pair.path.joined(separator: ".")) [\(text[pair.keyRange])] [\(pair.valueRange.map { String(text[$0]) } ?? "-")]"
        }
    }

    @Test func `Pairs follow headers, dotted keys and inline tables`() {
        let text = """
        workspaces = 5 # five
        [gaps] # the gaps
        outer.top = -4
        inner = { horizontal = 8, vertical = -1 }
        [[ rules ]]
        'app-id' = "com.example" # "quoted"
        """
        #expect(summary(text) == [
            "1 workspaces [workspaces] [5]",
            "3 gaps.outer.top [top] [-4]",
            "4 gaps.inner.horizontal [horizontal] [8]",
            "4 gaps.inner.vertical [vertical] [-1]",
            "4 gaps.inner [inner] [-]",
            "6 rules.app-id [app-id] [com.example]"
        ])
    }

    @Test func `Arrays and multi-line strings keep the line count`() {
        let text = "a = [\r\n  { b = 'x' }, # one\r\n  'y',\r\n]\r\nc = '''\r\nline\r\n'''\r\nd = \"\"\"\\\r\n\"\"\"\"\r\ne = 1\r\n"
        #expect(summary(text) == [
            "2 a.b [b] [x]",
            "1 a [a] [-]",
            "5 c [c] [-]",
            "8 d [d] [-]",
            "10 e [e] [1]"
        ])
    }

    @Test func `Strings with escapes give no value to edit`() {
        #expect(summary(#"a = "x\"y""#) == ["1 a [a] [-]"])
        #expect(summary(#"a = 'x\'"#) == [#"1 a [a] [x\]"#])
    }

    @Test func `Text the scanner does not follow gives no pairs at all`() {
        #expect(summary("a = 1979-05-27 07:32:00\n") == nil)
        #expect(summary(#""a\tb" = 1"#) == nil)
        #expect(summary("a = 'open\n") == nil)
        #expect(summary("a = 1 b = 2\n") == nil)
    }
}
