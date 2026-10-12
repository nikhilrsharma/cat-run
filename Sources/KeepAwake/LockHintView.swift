import AppKit

/// The window owns the visible hint bubble; this image owns hover detection and native help.
final class LockHintView: NSImageView {
    static let hintText = "Keeps your Mac awake whenever you start a timer."

    var onHoverChange: ((Bool) -> Void)? {
        didSet { toolTip = onHoverChange == nil ? Self.hintText : nil }
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHelp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureHelp()
    }

    private func configureHelp() {
        toolTip = Self.hintText
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Locked setting")
        setAccessibilityHelp(Self.hintText)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        hoverTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHiddenOrHasHiddenAncestor else { return }
        setHovering(true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isHiddenOrHasHiddenAncestor else { return }
        setHovering(true)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isHiddenOrHasHiddenAncestor else { return }
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) { resetHover() }

    /// Synchronizes help with events delivered directly to this app's own window.
    func setPointerInside(_ inside: Bool) {
        setHovering(inside && !isHiddenOrHasHiddenAncestor)
    }

    /// Also use when the window dismisses a hint on resigning key or changing pages.
    func resetHover() { setHovering(false) }

    override func viewDidHide() {
        resetHover()
        super.viewDidHide()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        resetHover()
        super.viewWillMove(toWindow: newWindow)
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        onHoverChange?(hovering)
    }
}
