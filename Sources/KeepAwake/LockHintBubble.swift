import AppKit

/// An in-window hint so its position stays directly above the lock at every window size.
final class LockHintBubble: FlippedView {
    private let text = NSTextField(labelWithString: LockHintView.hintText)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        text.font = AppWindow.font(13)
        text.textColor = AppPalette.foreground
        text.identifier = NSUserInterfaceItemIdentifier("lock-hint-text")
        addSubview(text)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(text.intrinsicContentSize.width) + 20, height: 29)
    }
    override func layout() {
        super.layout()
        let height = text.intrinsicContentSize.height
        text.frame = NSRect(x: 10, y: (bounds.height - height) / 2, width: bounds.width - 20, height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        AppPalette.background.setFill()
        shape.fill()
        AppPalette.foreground.withAlphaComponent(0.7).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
