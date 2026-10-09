import AppKit
import DinkyConfig
import DinkyLayout

/// The NSScreen showing a display.
func screen(of id: CGDirectDisplayID) -> NSScreen? {
    let number = NSDeviceDescriptionKey("NSScreenNumber")
    return NSScreen.screens.first { ($0.deviceDescription[number] as? NSNumber)?.uint32Value == id }
}

// What the layout needs from a display: its NSScreen, name and visible area, and the config's gaps
// resolved for it.
extension Display {
    /// The name System Settings shows, such as "Built-in Retina Display".
    var name: String { screen(of: id)?.localizedName ?? "" }

    /// The frame minus menu bar and Dock, in CG coordinates (top-left origin at the primary display).
    var visibleArea: CGRect {
        guard let primary = NSScreen.screens.first, let screen = screen(of: id) else { return frame }
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: primary.frame.maxY - visible.maxY, width: visible.width, height: visible.height)
    }
}

extension DisplayModel {
    /// What `[display.<pattern>]` tables are matched against.
    func monitor(_ display: Display) -> Monitor {
        Monitor(name: display.name, isMain: display.isMain, count: displays.count)
    }
}

extension DinkyLayout.Gaps {
    init(_ gaps: DinkyConfig.Gaps) {
        self.init(horizontal: CGFloat(gaps.inner.horizontal), vertical: CGFloat(gaps.inner.vertical),
                  top: CGFloat(gaps.outer.top), bottom: CGFloat(gaps.outer.bottom),
                  left: CGFloat(gaps.outer.left), right: CGFloat(gaps.outer.right))
    }
}

extension DinkyLayout.TilingAlignment {
    init(_ alignment: DinkyConfig.TilingAlignment) {
        self = switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }
}
