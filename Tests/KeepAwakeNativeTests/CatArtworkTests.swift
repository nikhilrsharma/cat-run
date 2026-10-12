import AppKit
import CoreGraphics
import XCTest
@testable import KeepAwake

/// Raster and scheduling checks only: these tests never create a live menu-bar item.
final class CatArtworkTests: XCTestCase {
    func testTwentyNamedActivitiesHaveDistinctCompleteFrameSequences() throws {
        XCTAssertEqual(CatAnimationAction.allCases.count, 20)
        XCTAssertEqual(Set(CatAnimationAction.allCases.map(\.name)).count, 20)
        XCTAssertEqual(CatAnimationAction.allCases.map(\.rawValue), Array(1...20))
        var sequences = Set<Data>()
        for action in CatAnimationAction.allCases {
            var sequence = Data()
            for frame in 1..<(CatAnimationTiming.frameCount - 1) {
                sequence.append(contentsOf: try raster(CatArtwork.image(action: action.rawValue, phase: Double(frame) / 16)).alpha)
            }
            XCTAssertTrue(sequences.insert(sequence).inserted, "\(action.name) duplicates another activity")
        }
    }

    func testSelectionNeverRepeatsPreviousActionAndCanChooseAllTwenty() {
        struct Generator: RandomNumberGenerator {
            var state: UInt64 = 0x43_61_74
            mutating func next() -> UInt64 {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return state
            }
        }
        for previous in CatAnimationAction.allCases {
            let candidates = CatAnimationAction.candidates(excluding: previous)
            XCTAssertEqual(candidates.count, 19)
            XCTAssertFalse(candidates.contains(previous))
        }
        var generator = Generator()
        var previous: CatAnimationAction?
        var observed = Set<CatAnimationAction>()
        for _ in 0..<2_000 {
            let selected = CatAnimationAction.choose(excluding: previous, using: &generator)
            XCTAssertNotEqual(selected, previous)
            observed.insert(selected)
            previous = selected
        }
        XCTAssertEqual(observed, Set(CatAnimationAction.allCases))
    }

    func testMenuImageIsRetinaTemplateWithTransparentExteriorAndInterior() throws {
        let image = CatArtwork.image()
        XCTAssertEqual(image.size, NSSize(width: 24, height: 20))
        XCTAssertTrue(image.isTemplate)
        let pixels = try raster(image)
        XCTAssertEqual(pixels.width, 48)
        XCTAssertEqual(pixels.height, 40)
        assertTransparentEdges(pixels)
        // The forehead and body centre remain clear; the cat is an outline, not a silhouette.
        XCTAssertLessThanOrEqual(pixels.alphaAtCanvas(x: 13.5, y: 16.8), 8)
        XCTAssertLessThanOrEqual(pixels.alphaAtCanvas(x: 13.5, y: 6), 8)
        XCTAssertGreaterThan(pixels.alpha.filter { $0 > 128 }.count, 40)
        XCTAssertLessThan(pixels.alpha.filter { $0 > 0 }.count, pixels.alpha.count / 2)
    }

    func testAllCachedFramesRemainNonemptyAndInsideTheirTransparentCanvas() throws {
        for activity in CatAnimationAction.allCases {
            let action = activity.rawValue
            for index in 0..<CatAnimationTiming.frameCount {
                let image = CatArtwork.image(action: action, phase: Double(index) / 16)
                let pixels = try raster(image)
                let context = "action \(action), frame \(index)"
                assertTransparentEdges(pixels, context: context)
                XCTAssertGreaterThan(pixels.alpha.filter { $0 > 128 }.count, 40, context)
                XCTAssertLessThan(pixels.alpha.filter { $0 > 0 }.count, pixels.alpha.count * 3 / 5, context)
            }
        }
    }

    func testEveryActionActuallyChangesPixelsAndReturnsToIdle() throws {
        let idle = try raster(CatArtwork.image()).alpha
        for activity in CatAnimationAction.allCases {
            let action = activity.rawValue
            var frames = Set<Data>()
            for index in 0..<CatAnimationTiming.frameCount {
                frames.insert(Data(try raster(CatArtwork.image(action: action, phase: Double(index) / 16)).alpha))
            }
            XCTAssertGreaterThanOrEqual(frames.count, 3, "Action \(action) did not visibly vary")
            XCTAssertTrue(frames.contains(Data(idle)))
            XCTAssertEqual(try raster(CatArtwork.image(action: action, phase: 1)).alpha, idle)
        }
        XCTAssertNotEqual(try raster(CatArtwork.image(action: 3, phase: 0.5)).alpha, idle,
                          "The Reduce Motion active pose must differ from the inactive cat")
    }

    func testLowPowerSubsampleStillShowsEveryAction() throws {
        for activity in CatAnimationAction.allCases {
            let action = activity.rawValue
            let frames = try [0, 4, 8, 12, 16].map {
                Data(try raster(CatArtwork.image(action: action, phase: Double($0) / 16)).alpha)
            }
            XCTAssertGreaterThanOrEqual(Set(frames).count, 3, "Low Power action \(action) became static")
        }
    }

    func testUntintedArtworkHasRequestedSizeBlackInkAndNoTemplateTint() throws {
        let image = CatArtwork.image(size: NSSize(width: 44, height: 32), template: false)
        XCTAssertEqual(image.size, NSSize(width: 44, height: 32))
        XCTAssertFalse(image.isTemplate)
        let pixels = try raster(image)
        XCTAssertEqual(pixels.width, 88)
        XCTAssertEqual(pixels.height, 64)
        assertTransparentEdges(pixels)
        var opaquePixels = 0
        for index in stride(from: 0, to: pixels.bytes.count, by: 4) where pixels.bytes[index + 3] > 200 {
            opaquePixels += 1
            for component in 0...2 {
                XCTAssertLessThanOrEqual(Int(pixels.bytes[index + component]), 2,
                                        "Header ink should be black in premultiplied RGBA")
            }
        }
        XCTAssertGreaterThan(opaquePixels, 100)
    }

    func testHeaderUsesExactlyTheCroppedIdleMenuAlphaAtEverySize() throws {
        let foreground = NSColor(srgbRed: 251.0 / 255, green: 193.0 / 255, blue: 147.0 / 255, alpha: 1)
        for size in [NSSize(width: 24, height: 20), NSSize(width: 44, height: 32), NSSize(width: 52, height: 32)] {
            let idle = try rawRaster(CatArtwork.image(action: 0, phase: 0, size: size))
            let image = CatArtwork.headerImage(size: size, foreground: foreground)
            let header = try rawRaster(image)
            var visible: [(x: Int, y: Int)] = []
            for y in 0..<idle.height {
                for x in 0..<idle.width where idle.bytes[(y * idle.width + x) * 4 + 3] > 0 {
                    visible.append((x: x, y: y))
                }
            }
            let left = try XCTUnwrap(visible.map(\.x).min()), right = try XCTUnwrap(visible.map(\.x).max())
            let top = try XCTUnwrap(visible.map(\.y).min()), bottom = try XCTUnwrap(visible.map(\.y).max())
            XCTAssertEqual(header.width, right - left + 1)
            XCTAssertEqual(header.height, bottom - top + 1)
            XCTAssertEqual(image.size, NSSize(width: CGFloat(header.width) / 2, height: CGFloat(header.height) / 2))
            XCTAssertFalse(image.isTemplate)
            for y in 0..<header.height {
                for x in 0..<header.width {
                    XCTAssertEqual(header.bytes[(y * header.width + x) * 4 + 3],
                                   idle.bytes[((y + top) * idle.width + x + left) * 4 + 3])
                }
            }
        }
    }

    func testHeaderPreservesEveryAlphaByteAndExactPeachForeground() throws {
        let size = NSSize(width: 52, height: 32)
        let foreground = NSColor(srgbRed: 251.0 / 255, green: 193.0 / 255, blue: 147.0 / 255, alpha: 1)
        let headerImage = CatArtwork.headerImage(size: size, foreground: foreground)
        let header = try rawRaster(headerImage)
        let croppedIdle = try rawRaster(CatArtwork.croppedInkImage(size: size))
        XCTAssertEqual(header.alpha, croppedIdle.alpha)
        let bitmap = try XCTUnwrap(headerImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(bitmap.colorSpace?.name, CGColorSpace.sRGB)
        var opaquePixels = 0
        for index in stride(from: 0, to: header.bytes.count, by: 4) {
            let alpha = header.bytes[index + 3]
            if alpha == 255 { opaquePixels += 1 }
            for (component, channel) in [251.0, 193.0, 147.0].enumerated() {
                XCTAssertEqual(header.bytes[index + component], UInt8((channel * Double(alpha) / 255).rounded()))
            }
        }
        XCTAssertGreaterThan(opaquePixels, 50)
    }

    func testHeaderTintCannotAlterTheOriginalMenuTemplate() throws {
        let before = try rawRaster(CatArtwork.image()).bytes
        _ = CatArtwork.headerImage(size: NSSize(width: 44, height: 32), foreground: .red)
        let after = CatArtwork.image()
        XCTAssertTrue(after.isTemplate)
        XCTAssertEqual(try rawRaster(after).bytes, before)
    }

    func testTimingBoundsLimitWorkAndDelayedCallbacksDoNotStretchActions() {
        XCTAssertEqual(CatAnimationTiming.duration, 2)
        XCTAssertEqual(CatAnimationTiming.frameCount, 17)
        XCTAssertEqual(CatAnimationTiming.interval(lowPower: false), 0.125)
        XCTAssertEqual(CatAnimationTiming.interval(lowPower: true), 0.5)
        XCTAssertEqual(CatAnimationTiming.repeatInterval, 5)
        XCTAssertEqual(CatAnimationTiming.frameIndex(elapsed: 0, lowPower: false), 0)
        XCTAssertEqual(CatAnimationTiming.frameIndex(elapsed: 0.125, lowPower: false), 1)
        XCTAssertEqual(CatAnimationTiming.frameIndex(elapsed: 0.5, lowPower: true), 4)
        for lowPower in [false, true] {
            XCTAssertEqual(CatAnimationTiming.frameIndex(elapsed: 2, lowPower: lowPower), 16)
            XCTAssertEqual(CatAnimationTiming.frameIndex(elapsed: 8, lowPower: lowPower), 16,
                           "A delayed callback must finish, not replay all skipped frames")
            XCTAssertEqual(CatAnimationTiming.frameIndex(elapsed: -1, lowPower: lowPower), 0)
            XCTAssertEqual(CatAnimationTiming.frameIndex(elapsed: .infinity, lowPower: lowPower), 16)
        }
        let lowPowerFrames = (0...16).map { CatAnimationTiming.frameIndex(elapsed: Double($0) / 8, lowPower: true) }
        XCTAssertEqual(Set(lowPowerFrames), Set([0, 4, 8, 12, 16]))
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        var alpha: [UInt8] { stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] } }
        func alphaAtCanvas(x: Double, y: Double) -> UInt8 {
            let scale = min(Double(width) / 28, Double(height) / 24)
            let pixelX = Int(((Double(width) - 28 * scale) / 2 + x * scale).rounded(.down))
            let pixelY = Int(((Double(height) - 24 * scale) / 2 + y * scale).rounded(.down))
            return bytes[(pixelY * width + pixelX) * 4 + 3]
        }
    }

    private func raster(_ image: NSImage) throws -> Pixels {
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var bytes = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: bitmap.width, height: bitmap.height,
                                                 bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: CGFloat(bitmap.width), height: CGFloat(bitmap.height)))
        }
        return Pixels(width: bitmap.width, height: bitmap.height, bytes: bytes)
    }

    /// Inspect stored RGBA directly, without a color-space conversion in the test renderer.
    private func rawRaster(_ image: NSImage) throws -> Pixels {
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try XCTUnwrap(bitmap.dataProvider?.data)
        let source = try XCTUnwrap(CFDataGetBytePtr(data))
        var bytes = [UInt8]()
        bytes.reserveCapacity(bitmap.width * bitmap.height * 4)
        for y in 0..<bitmap.height {
            bytes.append(contentsOf: UnsafeBufferPointer(start: source + y * bitmap.bytesPerRow, count: bitmap.width * 4))
        }
        return Pixels(width: bitmap.width, height: bitmap.height, bytes: bytes)
    }

    private func assertTransparentEdges(_ pixels: Pixels, context: String = "",
                                        file: StaticString = #filePath, line: UInt = #line) {
        for x in 0..<pixels.width {
            XCTAssertEqual(pixels.bytes[x * 4 + 3], 0, "Bottom edge clipped: \(context)", file: file, line: line)
            XCTAssertEqual(pixels.bytes[((pixels.height - 1) * pixels.width + x) * 4 + 3], 0,
                           "Top edge clipped: \(context)", file: file, line: line)
        }
        for y in 0..<pixels.height {
            XCTAssertEqual(pixels.bytes[(y * pixels.width) * 4 + 3], 0, "Left edge clipped: \(context)", file: file, line: line)
            XCTAssertEqual(pixels.bytes[(y * pixels.width + pixels.width - 1) * 4 + 3], 0,
                           "Right edge clipped: \(context)", file: file, line: line)
        }
    }
}
