import AppKit
import DinkyLayout

/// InDesign presents the existing standard document window on its current Space. Its frame covers the
/// display and its window buttons disappear; neither its AX subrole nor its WindowServer kind changes.
func isInDesignPresentation(bundleID: String?, frame: CGRect, displays: [CGRect], buttonsAbsent: Bool) -> Bool {
	bundleID == "com.adobe.InDesign" && buttonsAbsent && displays.contains { frame.isClose(to: $0, within: 1) }
}

extension Coordinator {
	func presentationLayout(_ layout: Layout) -> Layout {
		presenting.reduce(layout) { $0.excluding($1) }
	}

	func updatePresentation(_ window: Window) {
		guard window.bundleID == "com.adobe.InDesign" else { return }
		let frames = displays.displays.map(\.frame)
		var active = false
		if isInDesignPresentation(bundleID: window.bundleID, frame: window.frame, displays: frames, buttonsAbsent: true) {
			// Failed AX reads are not evidence of a mode change. Keep the last state until an event can read it.
			guard let element = axWindow(pid: window.pid, wid: window.id, timeout: FrameApplier.timeout) else { return }
			for attribute in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute] {
				var value: CFTypeRef?
				let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
				guard error == .success || error == .noValue || error == .attributeUnsupported else { return }
				if value != nil { setPresenting(window.id, false); return }
			}
			active = true
		}
		setPresenting(window.id, active)
	}

	/// Keep placement and tree membership, but retire every pass that could still hold its old frame.
	func setPresenting(_ id: UInt32, _ active: Bool) {
		guard presenting.contains(id) != active else { return }
		if active { presenting.insert(id) } else { presenting.remove(id) }
		applier.cancelPending()
		cancelPresentationAnimations()
	}
}
