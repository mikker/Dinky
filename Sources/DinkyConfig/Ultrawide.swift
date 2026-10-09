/// Horizontal placement of the complete tiling area inside the outer gaps.
public enum TilingAlignment: String, CaseIterable {
    case left, center, right
}

/// Read a finite ratio. The window limit allows 0 to opt out; the display threshold must be positive.
func aspectRatio(_ table: Table, _ key: String, positive: Bool = false) throws -> Double? {
    guard let value = try table.number(key) else { return nil }
    guard value.isFinite, (positive ? value > 0 : value >= 0) else {
        throw ConfigError(path: table.path(key), positive
            ? "must be a finite positive number" : "must be a finite non-negative number (0 disables the limit)")
    }
    return value
}

extension Config {
    /// Resolve each setting independently, with the same precedence as display gaps.
    public func ultrawideSettings(for monitor: Monitor) -> (threshold: Double, ratio: Double, alignment: TilingAlignment) {
        var result = (threshold: ultrawideMinAspectRatio, ratio: windowMaxAspectRatio, alignment: tilingAlignment)
        for override in overrides(for: monitor) {
            result.threshold = override.ultrawideMinAspectRatio ?? result.threshold
            result.ratio = override.windowMaxAspectRatio ?? result.ratio
            result.alignment = override.tilingAlignment ?? result.alignment
        }
        return result
    }
}
