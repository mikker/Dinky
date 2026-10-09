import Foundation
import Testing
@testable import dinky

struct WorkspaceReplacementTests {
    private func home(_ id: UInt32, pid: Int32 = 10, title: String = "Session") -> WorkspaceWindowHome {
        .init(identity: .init(id: id, pid: pid, firstSeen: Date(timeIntervalSince1970: Double(id))), workspace: 5, title: title)
    }

    @Test func `Replacement inherits the missing window home`() {
        let old = home(1), new = home(2)
        let matches = workspaceReplacements(homes: [old], candidates: [new], live: [new.identity])
        #expect(matches.count == 1)
        #expect(matches.first?.0.workspace == 5)
        #expect(matches.first?.1.identity == new.identity)
    }

    @Test func `Overlapping old and new windows wait for the old one to close`() {
        let old = home(1), new = home(2)
        #expect(workspaceReplacements(homes: [old], candidates: [new], live: [old.identity, new.identity]).isEmpty)
    }

    @Test func `Process and title must match`() {
        #expect(workspaceReplacements(homes: [home(1)], candidates: [home(2, pid: 11)], live: []).isEmpty)
        #expect(workspaceReplacements(homes: [home(1)], candidates: [home(2, title: "Other")], live: []).isEmpty)
        #expect(workspaceReplacements(homes: [home(1, title: "")], candidates: [home(2, title: "")], live: []).isEmpty)
    }

    @Test func `Duplicate titles cannot identify a replacement`() {
        #expect(workspaceReplacements(homes: [home(1), home(3)], candidates: [home(2)], live: []).isEmpty)
        #expect(workspaceReplacements(homes: [home(1)], candidates: [home(2), home(3)], live: []).isEmpty)
    }

    @Test func `Hidden and minimized documents remain workspace contents`() {
        var window = Window(identity: home(1).identity, appName: "Test", bundleID: "test.app")
        window.isDocument = true
        #expect(window.isWorkspaceWindow)
        window.isMinimized = true
        #expect(window.isWorkspaceWindow)
        #expect(!window.isNormal)
    }

    @Test func `Helper windows do not occupy workspaces`() {
        var window = Window(identity: home(1).identity, appName: "Test", bundleID: "test.app")
        #expect(!window.isWorkspaceWindow)
        window.isDocument = true
        window.level = 1
        #expect(!window.isWorkspaceWindow)
    }

}
