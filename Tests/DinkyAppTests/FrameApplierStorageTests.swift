import Foundation
import Testing
@testable import dinky

struct FrameApplierStorageTests {
    @Test func minimumSizesUseOnlyTheInjectedDirectory() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("dinky-pr59-storage-\(UUID())")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let legacy = support.appendingPathComponent("minimum-sizes.json")
        let current = support.appendingPathComponent("learned-minimum-sizes.json")
        try Data("{}".utf8).write(to: legacy)
        try Data(#"{"com.example.editor":[200,100]}"#.utf8).write(to: current)

        let applier = FrameApplier(supportURL: support)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(applier.minimumSize(of: 900_059, app: "com.example.editor") == CGSize(width: 200, height: 100))
        applier.forgetMinimums()
        #expect(applier.minimumSize(of: 900_059, app: "com.example.editor") == nil)
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }
}
