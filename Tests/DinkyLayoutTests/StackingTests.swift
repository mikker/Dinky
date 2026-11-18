import CoreGraphics
import Testing
@testable import DinkyLayout

struct StackingTests {
    @Test func `Each disjoint foreground window must be above its own background`() {
        let layout = Layout(frames: [1: rect(0, 0, 100, 100), 2: rect(200, 0, 100, 100),
                                     3: rect(0, 0, 100, 100), 4: rect(200, 0, 100, 100)],
                            order: [1, 2, 3, 4])
        #expect(layout.raises(current: [1, 4, 3, 2]) == [2, 1])
        #expect(layout.raises(current: [2, 1, 4, 3]).isEmpty,
                "disjoint foreground windows need not match each other's order")
    }

    @Test func `A background overlap does not become a separate foreground window`() {
        let layout = Layout(frames: [1: rect(0, 0, 100, 100), 2: rect(50, 0, 100, 100),
                                     3: rect(100, 0, 100, 100)], order: [1, 2, 3])
        #expect(layout.raises(current: [1, 3, 2]).isEmpty,
                "3 overlaps the earlier background window 2; their peeks do not justify a flash")
    }
}
