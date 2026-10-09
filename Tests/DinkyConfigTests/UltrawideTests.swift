import Testing
@testable import DinkyConfig

struct UltrawideTests {
    @Test func `Defaults preserve existing configurations`() throws {
        let config = try Config.parse("")
        #expect(config.windowMaxAspectRatio == 0)
        #expect(config.ultrawideMinAspectRatio == 2.3)
        #expect(config.tilingAlignment == .center)
    }

    @Test func `Monitor overrides layer each setting independently`() throws {
        let config = try Config.parse("""
        window-max-aspect-ratio = 1.5
        ultrawide-min-aspect-ratio = 2.3
        tiling-alignment = 'center'
        [display.secondary]
        tiling-alignment = 'left'
        [display.samsung]
        window-max-aspect-ratio = 2
        [display."samsung g9"]
        tiling-alignment = 'right'
        ultrawide-min-aspect-ratio = 3
        """)
        let settings = config.ultrawideSettings(for: Monitor(name: "Samsung G9", isMain: false, count: 2))
        #expect(settings.threshold == 3)
        #expect(settings.ratio == 2)
        #expect(settings.alignment == .right)
        let other = config.ultrawideSettings(for: Monitor(name: "LG", isMain: false, count: 2))
        #expect(other.ratio == 1.5)
        #expect(other.alignment == .left)
        #expect(try Config.parse("window-max-aspect-ratio = 0").windowMaxAspectRatio == 0)
    }

    @Test func `Invalid ratios and alignments report their exact path`() {
        for key in ["window-max-aspect-ratio", "ultrawide-min-aspect-ratio"] {
            for value in ["-1", "nan", "inf", "'3:2'"] {
                assertError("\(key) = \(value)\n", path: key, line: 1, contains: value == "'3:2'" ? "expected a number" : "finite")
                assertError("[display.main]\n\(key) = \(value)\n", path: "display.main.\(key)", line: 2, contains: value == "'3:2'" ? "expected a number" : "finite")
            }
        }
        assertError("ultrawide-min-aspect-ratio = 0\n", path: "ultrawide-min-aspect-ratio", line: 1, contains: "positive")
        assertError("tiling-alignment = 'top'\n", path: "tiling-alignment", line: 1, contains: "not one of")
    }
}
