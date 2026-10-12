import AppKit
import CoreText

/// Aligns the visible letter shapes rather than a font's invisible descent area.
final class BrandWordmark: NSView {
    private let line: CTLine
    private let glyphBounds: CGRect
    var inkBounds: NSRect { NSRect(origin: .zero, size: glyphBounds.size) }

    override init(frame frameRect: NSRect) {
        let font = NSFont(name: "SnellRoundhand-Bold", size: 26)
            ?? NSFont(name: "Baskerville-Italic", size: 26)
            ?? NSFontManager.shared.convert(AppWindow.font(26), toHaveTrait: .italicFontMask)
        let text = NSAttributedString(string: "Cat Run", attributes: [.font: font, .foregroundColor: AppPalette.foreground])
        line = CTLineCreateWithAttributedString(text)
        glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue("Cat Run")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -glyphBounds.minX, y: -glyphBounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
