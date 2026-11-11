import AppKit
import DinkyConfig
import DinkyPrivate

// The border of one window: dinky-owned SkyLight windows, one per edge, kept directly below or above its target.
// Redraws only when the look or size changes; a plain move just re-places it.
final class BorderWindow {
    struct Look: Equatable {
        var size: CGSize
        var cornerRadius: Int
        var color: DinkyConfig.Color
        var width: Double

        /// The same shape in another colour.
        func with(color: DinkyConfig.Color) -> Look {
            var look = self
            look.color = color
            return look
        }
    }

    private let target: UInt32
    /// The edge windows; all 0 until created.
    private var border = DinkyBorder()
    private var created = false
    private var scale = 0.0
    private var spaceID: UInt64 = 0
    private var drawn: Look?
    private var isShown = false

    init(target: UInt32) {
        self.target = target
    }

    deinit {
        dinky_border_destroy(&border)
    }

    /// Whether `id` is one of this border's own windows.
    func owns(_ id: UInt32) -> Bool { dinky_border_owns(&border, id) }

    /// Place and draw the border around `window`. With `moveOnly`, a border whose shape would change hides instead,
    /// as redrawing it at every size of a resize costs more than a frame; a new colour alone is drawn, once.
    func update(_ window: Window, color: DinkyConfig.Color, config: Borders, moveOnly: Bool = false) {
        let look = Look(size: window.frame.size, cornerRadius: window.cornerRadius,
                        color: color, width: config.width)
        if moveOnly, drawn?.with(color: color) != look { return hide() }
        let scale = backingScale(of: window.frame)
        if scale != self.scale { recreate(scale: scale) }
        guard created else { return }

        if spaceID != window.spaceID, window.spaceID != 0 {
            dinky_border_move_to_space(&border, window.spaceID)
            spaceID = window.spaceID
        }
        let order: DinkyBorderOrder = config.order == .above ? .above : .below
        if look == drawn {
            dinky_border_move(&border, target, window.frame, config.width, order)
        } else {
            let rgba = DinkyBorderColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
            dinky_border_update(&border, target, window.frame, Int32(window.cornerRadius), rgba, config.width, order)
            drawn = look
        }
        isShown = true
    }

    /// Follows a window that only moved: the border keeps its shape, Space and place in the stacking, so it is moved
    /// without being redrawn or re-ordered. False if it needs `update` instead: it is hidden, or the window has a new
    /// size or reached a display of another scale.
    func follow(_ window: Window) -> Bool {
        guard isShown, let drawn, drawn.size == window.frame.size,
              backingScale(of: window.frame) == scale else { return false }
        dinky_border_follow(&border, window.frame, drawn.width)
        return true
    }

    func hide() {
        guard isShown else { return }
        dinky_border_hide(&border)
        isShown = false
    }

    // JankyBorders sets the resolution once, at creation; a display change gets a new window.
    // Widths and radii stay in points; the resolution alone decides the pixels.
    private func recreate(scale: Double) {
        dinky_border_destroy(&border)
        created = dinky_border_create(&border, scale)
        self.scale = scale
        spaceID = 0
        drawn = nil
    }
}

// The backing scale of the screen under the frame's centre. Frames are top-left global,
// NSScreen frames bottom-left, flipped around the primary screen.
private func backingScale(of frame: CGRect) -> Double {
    let screens = NSScreen.screens
    guard let primary = screens.first else { return 2 }
    let center = CGPoint(x: frame.midX, y: primary.frame.maxY - frame.midY)
    let screen = screens.first { $0.frame.contains(center) } ?? primary
    return screen.backingScaleFactor
}
