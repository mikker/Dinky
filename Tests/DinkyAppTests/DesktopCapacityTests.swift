import Foundation
import Testing
import DinkyPrivate
@testable import dinky

struct DesktopCapacityTests {
    @Test func `Native lifecycle capability requires macOS 27`() {
        #expect(dinky_can_manage_spaces() == (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27))
    }

    @Test func `Missing manual desktops are actionable doctor errors`() {
        let status = desktopCapacityStatus(label: "display 1", spaces: 2, workspaces: [1, 2, 3], managesSpaces: false)
        #expect(status.error)
        #expect(status.message == "display 1 has 2 Spaces, but needs 3 for workspaces 1, 2, 3; add desktops in Mission Control")
    }

    @Test func `Automatic management does not require manually adding desktops`() {
        let status = desktopCapacityStatus(label: "display 1", spaces: 2, workspaces: [1, 2, 3], managesSpaces: true)
        #expect(!status.error)
    }

    @Test func `Enough manual desktops and extra desktops are both valid`() {
        for count in [3, 5] {
            let status = desktopCapacityStatus(label: "display 1", spaces: count, workspaces: [1, 2, 3], managesSpaces: false)
            #expect(!status.error)
        }
        let unassigned = desktopCapacityStatus(label: "display 2", spaces: 1, workspaces: [], managesSpaces: false)
        #expect(!unassigned.error)
        #expect(unassigned.message == "display 2 has 1 Space and no workspaces")
    }
}
