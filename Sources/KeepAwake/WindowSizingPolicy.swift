import AppKit

/// Frame sizes include the caller's actual title-bar height. No display or window is accessed here.
struct WindowSizingPolicy {
    static let referenceContentSize = NSSize(width: 420, height: 400)
    static let referenceVisibleSize = NSSize(width: 1_440, height: 875)

    let referenceFrameSize: NSSize
    let defaultFrameSize: NSSize
    let minimumFrameSize: NSSize
    let maximumFrameSize: NSSize
    let minimumFitsVisibleSize: Bool

    var frameAspectRatio: CGFloat { referenceFrameSize.width / referenceFrameSize.height }

    private let maximumScale: CGFloat

    init(visibleSize: NSSize, chromeHeight: CGFloat) {
        let chrome = chromeHeight.isFinite ? max(0, chromeHeight) : 28
        let visible = NSSize(
            width: Self.validDimension(visibleSize.width, fallback: Self.referenceVisibleSize.width),
            height: Self.validDimension(visibleSize.height, fallback: Self.referenceVisibleSize.height)
        )
        let reference = NSSize(width: Self.referenceContentSize.width, height: Self.referenceContentSize.height + chrome)
        let physicalFitScale = min(visible.width / reference.width, visible.height / reference.height)
        let displayScale = min(visible.width / Self.referenceVisibleSize.width, visible.height / Self.referenceVisibleSize.height)
        let defaultScale = max(1, min(1.15, displayScale, physicalFitScale))
        maximumScale = max(1, min(defaultScale * 1.25, physicalFitScale))
        referenceFrameSize = reference
        minimumFrameSize = reference
        defaultFrameSize = Self.scaled(reference, by: defaultScale)
        maximumFrameSize = Self.scaled(reference, by: maximumScale)
        // If the display cannot contain the usable minimum, keep controls readable instead of
        // shrinking below 420 × 400 content. The caller can keep the title bar on the display.
        minimumFitsVisibleSize = physicalFitScale >= 1
    }

    /// A width-only or height-only drag drives that dimension; diagonal drags follow the larger
    /// normalized change. One common scale preserves the frame ratio through every clamp.
    func constrain(_ proposed: NSSize, relativeTo current: NSSize? = nil) -> NSSize {
        let current = NSSize(
            width: Self.validDimension(current?.width ?? defaultFrameSize.width, fallback: defaultFrameSize.width),
            height: Self.validDimension(current?.height ?? defaultFrameSize.height, fallback: defaultFrameSize.height)
        )
        let proposed = NSSize(
            width: proposed.width.isFinite ? max(0, proposed.width) : current.width,
            height: proposed.height.isFinite ? max(0, proposed.height) : current.height
        )
        let widthChange = abs(proposed.width - current.width) / referenceFrameSize.width
        let heightChange = abs(proposed.height - current.height) / referenceFrameSize.height
        let scale = widthChange >= heightChange
            ? proposed.width / referenceFrameSize.width
            : proposed.height / referenceFrameSize.height
        return Self.scaled(referenceFrameSize, by: max(1, min(maximumScale, scale)))
    }

    private static func validDimension(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : fallback
    }

    private static func scaled(_ size: NSSize, by scale: CGFloat) -> NSSize {
        NSSize(width: size.width * scale, height: size.height * scale)
    }
}
