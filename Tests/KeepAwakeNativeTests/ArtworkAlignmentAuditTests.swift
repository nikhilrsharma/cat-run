import AppKit
import CoreGraphics
import XCTest
@testable import KeepAwake

/// Draw into an oversized canvas to detect real raster ink outside a view's frame.
/// Geometry-only checks miss antialiasing beyond a font's ideal glyph-path bounds.
final class ArtworkAlignmentAuditTests: XCTestCase {
    func testWordmarkPreservesItsCompleteRasterAtBothWindowLimitsAndBackingScales() throws {
        try onMain {
            _ = NSApplication.shared
            let controller = AppWindow(persistWindowFrame: false)
            defer { controller.close() }
            controller.applyBounds(visibleFrame: NSRect(x: 0, y: 0, width: 1728, height: 1080))
            let window = try XCTUnwrap(controller.window)
            let root = try XCTUnwrap(window.contentView)
            let wordmark = try XCTUnwrap(root.subviews.compactMap { $0 as? BrandWordmark }.first)
            for size in [window.minSize, window.maxSize] {
                window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
                root.layoutSubtreeIfNeeded()
                for scale in [CGFloat(1), CGFloat(2)] {
                    let pixels = try raster(wordmark, scale: scale, padding: 8)
                    var inkCount = 0
                    var clippedCount = 0
                    for y in 0..<pixels.height {
                        for x in 0..<pixels.width {
                            let alpha = pixels.bytes[(y * pixels.width + x) * 4 + 3]
                            guard alpha > 1 else { continue }
                            inkCount += 1
                            if !pixels.viewRect.contains(NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                                clippedCount += 1
                            }
                        }
                    }
                    XCTAssertGreaterThan(inkCount, 100)
                    XCTAssertEqual(clippedCount, 0,
                                   "The wordmark clips \(clippedCount) antialiased pixels at \(scale)x, window \(size)")
                }
            }
        }
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        let viewRect: NSRect
    }

    private func raster(_ view: NSView, scale: CGFloat, padding: CGFloat) throws -> Pixels {
        let width = Int(ceil((view.bounds.width + padding * 2) * scale))
        let height = Int(ceil((view.bounds.height + padding * 2) * scale))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                                                 width: width, height: height,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: padding, y: padding)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        // Bitmap rows run top to bottom; AppKit's unflipped wordmark runs bottom to top.
        let rect = NSRect(x: padding * scale,
                          y: CGFloat(height) - (padding + view.bounds.height) * scale,
                          width: view.bounds.width * scale, height: view.bounds.height * scale)
        return Pixels(width: width, height: height, bytes: bytes, viewRect: rect)
    }

    private func onMain(_ body: () throws -> Void) rethrows {
        if Thread.isMainThread { try body() }
        else { try DispatchQueue.main.sync(execute: body) }
    }
}
