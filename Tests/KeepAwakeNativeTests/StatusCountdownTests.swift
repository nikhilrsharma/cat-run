import AppKit
import CoreGraphics
import XCTest
@testable import KeepAwake

/// Exercises exactly the composed menu image without creating an NSStatusItem or opening a window.
final class StatusCountdownTests: XCTestCase {
    func testBothRowsArePaddedNumbersWithoutUnitSuffixes() {
        for (seconds, hours, minutes) in [
            (0.0, "00", "00"), (1, "00", "01"), (60, "00", "01"),
            (61, "00", "02"), (900, "00", "15"), (3_600, "01", "00"),
            (4_500, "01", "15"), (21_600, "06", "00")
        ] {
            let countdown = StatusCountdown(remaining: seconds)
            XCTAssertEqual(countdown.hoursLine, hours)
            XCTAssertEqual(countdown.minutesLine, minutes)
        }
    }

    func testInvalidTimesAreSafeAndAccessibilityKeepsFullWords() {
        for seconds in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(StatusCountdown(remaining: seconds), StatusCountdown(remaining: 0))
        }
        XCTAssertEqual(StatusCountdown(remaining: 4_500).accessibilityText, "1 hour, 15 minutes remaining")
        XCTAssertEqual(StatusCountdown(remaining: 61).accessibilityText, "0 hours, 2 minutes remaining")
        XCTAssertEqual(StatusCountdown(remaining: 1).accessibilityText, "0 hours, 1 minute remaining")
        XCTAssertEqual(StatusCountdown(remaining: .greatestFiniteMagnitude).hoursLine, "06")
        XCTAssertEqual(CatStatusItem.time(4_500), "01h 15m")
    }

    func testCountdownCannotOverlapCatAndBothRowsFitSmallTabularText() {
        onMain {
            let countdown = StatusCountdown(remaining: 4_500)
            let cat = NSSize(width: 24, height: 20)
            let bounds = StatusCountdown.contentRect(catSize: cat)
            XCTAssertFalse(bounds.intersects(NSRect(origin: .zero, size: cat)))
            XCTAssertEqual(bounds.minX - cat.width, 2)
            let layout = countdown.layout(in: bounds)
            XCTAssertLessThanOrEqual(layout.font.pointSize, 9)
            XCTAssertGreaterThanOrEqual(layout.font.pointSize, 7)
            XCTAssertTrue(bounds.contains(layout.hours))
            XCTAssertTrue(bounds.contains(layout.minutes))
            XCTAssertGreaterThanOrEqual(layout.hours.minY, layout.minutes.maxY)
            for text in [countdown.hoursLine, countdown.minutesLine] {
                XCTAssertLessThanOrEqual((text as NSString).size(withAttributes: [.font: layout.font]).width, bounds.width)
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: StatusCountdown.font()]
            let narrow = ("11" as NSString).size(withAttributes: attributes).width
            let wide = ("88" as NSString).size(withAttributes: attributes).width
            XCTAssertEqual(narrow, wide, accuracy: 0.01)
        }
    }

    func testNativeButtonFitsCompleteCompositeAtBothMenuHeights() throws {
        try onMain {
            let image = StatusCountdown(remaining: 4_500).image(cat: CatArtwork.image())
            let button = NSButton(frame: .zero)
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.isBordered = false
            button.sizeToFit()
            let cell = try XCTUnwrap(button.cell as? NSButtonCell)
            for height in [CGFloat(22), CGFloat(24)] {
                button.setFrameSize(NSSize(width: button.frame.width, height: height))
                let imageRect = cell.imageRect(forBounds: button.bounds)
                XCTAssertGreaterThanOrEqual(imageRect.width, image.size.width)
                XCTAssertGreaterThanOrEqual(imageRect.height, image.size.height)
                XCTAssertTrue(button.bounds.contains(imageRect))
            }
        }
    }

    func testCompositeContainsBothRowsAndRetainsTransparentGap() throws {
        try onMain {
            let cat = CatArtwork.image()
            let image = StatusCountdown(remaining: 4_500).image(cat: cat)
            let pixels = try pixels(image)
            let content = StatusCountdown.contentRect(catSize: cat.size)
            let left = Int(content.minX * 2)
            let right = Int(content.maxX * 2)
            for rows in [0..<(pixels.height / 2), (pixels.height / 2)..<pixels.height] {
                let ink = rows.reduce(0) { total, y in
                    total + (left..<right).filter { pixels.bytes[(y * pixels.width + $0) * 4 + 3] > 50 }.count
                }
                XCTAssertGreaterThan(ink, 20, "A countdown row was missing or clipped")
            }
            for y in 0..<pixels.height {
                for x in Int(cat.size.width * 2)..<left {
                    XCTAssertEqual(pixels.bytes[(y * pixels.width + x) * 4 + 3], 0)
                }
            }
            let different = try self.pixels(StatusCountdown(remaining: 900).image(cat: cat))
            XCTAssertNotEqual(pixels.bytes, different.bytes)
        }
    }

    func testTemplateCompositionPreservesSystemTintAndNativeImageSize() throws {
        try onMain {
            let cat = CatArtwork.image()
            let image = StatusCountdown(remaining: 4_500).image(cat: cat)
            XCTAssertTrue(image.isTemplate, "macOS must tint both rows and cat for the actual menu-bar appearance")
            XCTAssertEqual(image.size.height, 20)
            XCTAssertEqual(image.size.width, StatusCountdown.contentRect(catSize: cat.size).maxX)
            XCTAssertLessThanOrEqual(image.size.width, 40)
            let pixels = try pixels(image)
            XCTAssertEqual(pixels.height, 40)
            XCTAssertEqual(pixels.width, Int(image.size.width * 2))
            XCTAssertGreaterThan(pixels.bytes.enumerated().filter { $0.offset % 4 == 3 && $0.element > 50 }.count, 100)
        }
    }

    func testCompositionCacheReusesFramesAndOnlyRetainsCurrentMinute() {
        onMain {
            let cat = CatArtwork.image()
            let moving = CatArtwork.image(action: 3, phase: 0.5)
            let countdown = StatusCountdown(remaining: 4_500)
            var cache = StatusCountdownImageCache()
            let first = cache.image(cat: cat, countdown: countdown)
            XCTAssertTrue(first === cache.image(cat: cat, countdown: countdown))
            XCTAssertFalse(first === cache.image(cat: moving, countdown: countdown))
            let next = cache.image(cat: cat, countdown: StatusCountdown(remaining: 4_440))
            XCTAssertFalse(first === next)
            XCTAssertFalse(first === cache.image(cat: cat, countdown: countdown), "Returning to an old minute should not retain its old frame cache")
            cache.clear()
            XCTAssertFalse(next === cache.image(cat: cat, countdown: StatusCountdown(remaining: 4_440)))
        }
    }

    func testActivityCadenceIsFixedFiveSecondsAndIncludesItsTwoSecondAction() {
        XCTAssertEqual(CatAnimationTiming.repeatInterval, 5)
        XCTAssertEqual(CatAnimationTiming.duration, 2)
        XCTAssertEqual(CatAnimationTiming.repeatInterval - CatAnimationTiming.duration, 3)
    }

    func testCompositionCacheStaysBoundedAcrossEntireActionCatalog() {
        onMain {
            var cache = StatusCountdownImageCache()
            let countdown = StatusCountdown(remaining: 900)
            // Retain inputs so their identity cannot be recycled while probing the cache.
            let frames = CatAnimationAction.allCases.flatMap { action in
                (0..<CatAnimationTiming.frameCount).map { CatArtwork.image(action: action.rawValue, phase: Double($0) / 16) }
            }
            XCTAssertEqual(frames.count, 340)
            XCTAssertEqual(StatusCountdownImageCache.maximumEntries, 19)
            for frame in frames {
                _ = cache.image(cat: frame, countdown: countdown)
                XCTAssertLessThanOrEqual(cache.count, 19)
            }
            cache.clear()
            XCTAssertEqual(cache.count, 0)
        }
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private func pixels(_ image: NSImage) throws -> Pixels {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private func onMain(_ body: () throws -> Void) rethrows {
        if Thread.isMainThread { try body() }
        else { try DispatchQueue.main.sync(execute: body) }
    }
}
