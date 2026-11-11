import Foundation
import Testing
import DinkyConfig
import DinkyLayout
@testable import dinky

struct PresentationTests {
	@Test func presentationRequiresInDesignFullDisplayAndMissingButtons() {
		let display = CGRect(x: 2560, y: -200, width: 1920, height: 1080)
		#expect(isInDesignPresentation(bundleID: "com.adobe.InDesign", frame: display,
			displays: [.zero, display], buttonsAbsent: true))
		#expect(!isInDesignPresentation(bundleID: "com.example.editor", frame: display,
			displays: [display], buttonsAbsent: true))
		#expect(!isInDesignPresentation(bundleID: "com.adobe.InDesign", frame: display,
			displays: [display], buttonsAbsent: false))
		#expect(!isInDesignPresentation(bundleID: "com.adobe.InDesign", frame: display.insetBy(dx: 4, dy: 34),
			displays: [display], buttonsAbsent: true))
	}

	@Test func transitionsInvalidateOldWritesAndPreservePlacement() throws {
		let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: support) }
		let applier = FrameApplier(supportURL: support)
		let owner = Coordinator(displays: DisplayModel(), config: Config(), applier: applier)
		owner.placements[2063] = Placement(floating: false, space: 7)
		let layout = Layout(frames: [2063: CGRect(x: 0, y: 0, width: 500, height: 800),
			2064: CGRect(x: 500, y: 0, width: 500, height: 800)], order: [2063, 2064])
		let before = try #require(applier.permit)
		owner.setPresenting(2063, true)
		#expect(owner.presenting.contains(2063))
		let writing = owner.presentationLayout(layout)
		#expect(writing.order == [2064])
		#expect(writing.frames[2063] == nil)
		#expect(writing.frames[2064] == layout.frames[2064])
		#expect(!applier.allows(before))
		#expect(owner.placements[2063]?.space == 7)
		#expect(owner.placements[2063]?.floating == false)
		let during = try #require(applier.permit)
		owner.setPresenting(2063, true)
		#expect(applier.allows(during))
		owner.setPresenting(2063, false)
		#expect(owner.presenting.isEmpty)
		#expect(!applier.allows(during))
		#expect(owner.presentationLayout(layout) == layout)
		#expect(owner.placements[2063]?.space == 7)
		owner.setPresenting(2063, true)
		owner.forget(2063)
		#expect(owner.presenting.isEmpty)
	}
}
