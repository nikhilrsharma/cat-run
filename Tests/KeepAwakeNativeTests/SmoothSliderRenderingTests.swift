import AppKit
import XCTest
@testable import KeepAwake

final class SmoothSliderRenderingTests: XCTestCase {
    func testRenderedEndpointThumbsMatchTheCompleteMiddleThumb() throws {
        try onMain {
            _ = NSApplication.shared
            let controller = AppWindow(persistWindowFrame: false)
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            let root = try XCTUnwrap(window.contentView)
            let slider = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSlider }.first)
            controller.applyBounds(visibleFrame: NSRect(x: 0, y: 25, width: 1440, height: 875))
            for size in [window.minSize, window.maxSize] {
                window.setFrame(NSRect(origin: .zero, size: size), display: false)
                root.layoutSubtreeIfNeeded()
                for active in [false, true] {
                    for scale in [1, 2] {
                        var samples: [ThumbPixels] = []
                        for minutes in [15, 180, 360] {
                            var state = WindowState()
                            state.duration = minutes; state.active = active
                            controller.render(state)
                            let pixels = try thumbPixels(of: slider, scale: scale, active: active)
                            let context = "duration \(minutes), active \(active), scale \(scale), window \(size)"
                            XCTAssertGreaterThanOrEqual(pixels.width, 16 * scale, context)
                            XCTAssertGreaterThanOrEqual(pixels.height, 16 * scale, context)
                            XCTAssertGreaterThanOrEqual(pixels.minX, 2 * scale, "Left edge clipped: \(context)")
                            XCTAssertLessThanOrEqual(pixels.maxX, pixels.canvasWidth - 1 - 2 * scale, "Right edge clipped: \(context)")
                            samples.append(pixels)
                        }
                        for endpoint in [samples[0], samples[2]] {
                            XCTAssertEqual(Double(endpoint.count), Double(samples[1].count), accuracy: Double(samples[1].count) * 0.08,
                                           "Endpoint must retain the round thumb's full area")
                            XCTAssertEqual(endpoint.width, samples[1].width, accuracy: scale)
                        }
                    }
                }
            }
        }
    }

    private struct ThumbPixels {
        let minX: Int, maxX: Int, minY: Int, maxY: Int, count: Int, canvasWidth: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    private func thumbPixels(of slider: NSSlider, scale: Int, active: Bool) throws -> ThumbPixels {
        let width = Int(slider.bounds.width.rounded(.up)) * scale
        let height = Int(slider.bounds.height.rounded(.up)) * scale
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
            pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        bitmap.size = slider.bounds.size
        // Exercise the real native view's drawing path, including any AppKit clipping.
        slider.cacheDisplay(in: slider.bounds, to: bitmap)
        var minX = width, maxX = -1, minY = height, maxY = -1, count = 0
        let threshold: CGFloat = active ? 0.42 : 0.84
        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.redComponent * color.alphaComponent > threshold else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y); count += 1
            }
        }
        XCTAssertGreaterThan(count, 0, "Native thumb must actually be rendered")
        return ThumbPixels(minX: minX, maxX: maxX, minY: minY, maxY: maxY, count: count, canvasWidth: width)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func onMain(_ body: () throws -> Void) rethrows {
        if Thread.isMainThread { try body() } else { try DispatchQueue.main.sync(execute: body) }
    }
}
