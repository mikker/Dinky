import Foundation
import Testing
@testable import dinky

struct DebugFrameTests {
    @Test func preservesFiniteFrames() {
        #expect(debugFrame(CGRect(x: -100, y: 30, width: 800, height: 600)) == [-100, 30, 800, 600])
        #expect(debugFrame(.zero) == [0, 0, 0, 0])
    }

    @Test func unavailableFramesAreJSONSafe() throws {
        for rect in [CGRect.null, .infinite, CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)] {
            #expect(debugFrame(rect).isEmpty)
            #expect(throws: Never.self) { try JSONSerialization.data(withJSONObject: ["frame": debugFrame(rect)]) }
        }
    }
}
