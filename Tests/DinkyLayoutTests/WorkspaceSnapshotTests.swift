import Foundation
import Testing
@testable import DinkyLayout

struct WorkspaceSnapshotTests {
    private func workspace() -> Workspace {
        var workspace = Workspace(bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440))
        for id in UInt32(1)...3 { workspace.insert(id) }
        workspace.focus(1)
        workspace.setOrientation(.vertical)
        workspace.resize(by: 100, along: .vertical)
        return workspace
    }

    @Test func `A JSON round trip preserves nested trees ratios and order`() throws {
        let original = workspace()
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(WorkspaceSnapshot(original)))
        var restored = original
        restored.flatten()
        #expect(snapshot.isValid)
        let didRestore1 = restored.restore(snapshot, retaining: Set(original.windows))
        #expect(didRestore1)
        #expect(restored.root == original.root)
        #expect(restored.focused == original.focused)
        #expect(restored.layout() == original.layout())
    }

    @Test func `Closed leaves are removed while the surviving order is preserved`() {
        let original = workspace()
        var restored = original
        let didRestore2 = restored.restore(WorkspaceSnapshot(original), retaining: [1, 3])
        #expect(didRestore2)
        #expect(restored.windows == original.windows.filter { $0 != 2 })
        #expect(restored.layout().frames.count == 2)
    }

    @Test func `Current monitor bounds gaps and learned minimums survive restoration`() {
        let original = workspace()
        var restored = original
        restored.bounds = CGRect(x: -1600, y: -900, width: 1600, height: 900)
        restored.gaps = Gaps(all: 12)
        restored.minimumSizes = [1: CGSize(width: 300, height: 200)]
        let bounds = restored.bounds, gaps = restored.gaps, minimums = restored.minimumSizes
        let didRestore3 = restored.restore(WorkspaceSnapshot(original), retaining: Set(original.windows))
        #expect(didRestore3)
        #expect(restored.bounds == bounds)
        #expect(restored.gaps == gaps)
        #expect(restored.minimumSizes == minimums)
        #expect(restored.layout().frames.values.allSatisfy { bounds.contains($0) })
    }

    @Test func `A changed algorithm takes precedence over the saved tree`() {
        let original = workspace()
        var restored = Workspace(bounds: original.bounds, algorithm: .fixed(rows: 2, columns: 2, expand: .rows))
        restored.insert(1)
        let before = restored
        let didRestore5 = restored.restore(WorkspaceSnapshot(original), retaining: Set(original.windows))
        #expect(!didRestore5)
        #expect(restored == before)
    }

    @Test func `Fixed cells and accordion focus survive a round trip`() throws {
        var original = Workspace(bounds: CGRect(x: 0, y: 0, width: 1600, height: 900),
                                 algorithm: .fixed(rows: 1, columns: 2, expand: .accordion))
        for id in UInt32(1)...4 { original.insert(id) }
        original.focus(3)
        original.toggleFullscreen()
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(WorkspaceSnapshot(original)))
        var restored = Workspace(bounds: original.bounds, algorithm: original.algorithm)
        let didRestore6 = restored.restore(snapshot, retaining: Set(original.windows))
        #expect(didRestore6)
        #expect(restored.layout() == original.layout())
        #expect(restored.fullscreen == 3)
        #expect(restored.root == original.root)
    }

    @Test func `Removing a fixed leaf retains its reserved cell`() {
        var original = Workspace(bounds: CGRect(x: 0, y: 0, width: 1600, height: 900),
                                 algorithm: .fixed(rows: 2, columns: 2, expand: .rows))
        for id in UInt32(1)...3 { original.insert(id) }
        var restored = original
        let didRestore7 = restored.restore(WorkspaceSnapshot(original), retaining: [1, 3])
        #expect(didRestore7)
        #expect(restored.isFixedTree)
        #expect(restored.root.node(at: [1, 0]).windows.isEmpty)
        #expect(restored.windows == [1, 3])
    }

    @Test func `Invalid fixed template dimensions are rejected before allocating cells`() throws {
        let original = workspace()
        let data = try JSONEncoder().encode(WorkspaceSnapshot(original))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["algorithm"] = ["fixed": ["rows": Int.max, "columns": 1, "expand": ["rows": [:]]]]
        let malformed = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!malformed.isValid)
    }

    @Test func `Invalid ratios duplicate leaves and negative active indices are rejected`() throws {
        let original = workspace()
        let data = try JSONEncoder().encode(WorkspaceSnapshot(original))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for invalid in ["ratios", "duplicates", "active"] {
            var changed = json
            var root = try #require(changed["root"] as? [String: Any])
            switch invalid {
            case "ratios": root["ratios"] = [1.0]
            case "duplicates":
                root["children"] = [["window": ["_0": 1]], ["window": ["_0": 1]]]
                root["ratios"] = [0.5, 0.5]
            default: root["active"] = -1
            }
            changed["root"] = root
            let malformed = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: changed))
            var restored = original
            #expect(!malformed.isValid)
            let didRestore8 = restored.restore(malformed, retaining: Set(original.windows))
            #expect(!didRestore8)
            #expect(restored == original)
        }
    }
}
