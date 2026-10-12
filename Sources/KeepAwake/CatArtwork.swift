import AppKit
import CoreGraphics

/// Stable names and identifiers for the twenty original menu-bar activities.
enum CatAnimationAction: Int, CaseIterable {
    case tailSwish = 1, lookAround, pawWave, happyHop, blinkAndEarTwitch
    case longStretch, walk, trot, curlUp, rollOver, groom, earScratch, shake
    case yawn, sniff, pounce, ballPlay, butterflyWatch, heartPurr, peek

    var name: String {
        switch self {
        case .tailSwish: return "Tail swish"
        case .lookAround: return "Look around"
        case .pawWave: return "Paw wave"
        case .happyHop: return "Happy hop"
        case .blinkAndEarTwitch: return "Blink and ear twitch"
        case .longStretch: return "Long stretch"
        case .walk: return "Walk"
        case .trot: return "Trot"
        case .curlUp: return "Curl up"
        case .rollOver: return "Roll over"
        case .groom: return "Groom"
        case .earScratch: return "Ear scratch"
        case .shake: return "Shake"
        case .yawn: return "Yawn"
        case .sniff: return "Sniff"
        case .pounce: return "Pounce"
        case .ballPlay: return "Ball play"
        case .butterflyWatch: return "Butterfly watch"
        case .heartPurr: return "Heart purr"
        case .peek: return "Peek"
        }
    }

    static func candidates(excluding previous: CatAnimationAction?) -> [CatAnimationAction] {
        allCases.filter { $0 != previous }
    }

    static func choose<R: RandomNumberGenerator>(excluding previous: CatAnimationAction?, using generator: inout R) -> CatAnimationAction {
        let choices = candidates(excluding: previous)
        return choices[Int.random(in: choices.indices, using: &generator)]
    }
}

/// Transparent outline art, explicitly rasterized for reliable alpha in menu-bar templates.
enum CatArtwork {
    /// Uses the idle menu cat's exact alpha mask, with no transparent outer padding.
    /// Only RGB is tinted; the raster's antialiased alpha remains unchanged.
    static func headerImage(size: NSSize, foreground: NSColor) -> NSImage {
        let idle = croppedInkImage(size: size)
        guard let source = idle.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let sourceData = source.dataProvider?.data, let sourceBytes = CFDataGetBytePtr(sourceData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return idle }
        let color = foreground.usingColorSpace(.sRGB) ?? .black
        let components = [color.redComponent, color.greenComponent, color.blueComponent].map { min(1, max(0, $0)) }
        let rowBytes = source.width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * source.height)
        for y in 0..<source.height {
            for x in 0..<source.width {
                let alpha = sourceBytes[y * source.bytesPerRow + x * 4 + 3]
                let destination = y * rowBytes + x * 4
                for component in 0..<3 {
                    bytes[destination + component] = UInt8((components[component] * CGFloat(alpha)).rounded())
                }
                bytes[destination + 3] = alpha
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let bitmap = CGImage(width: source.width, height: source.height, bitsPerComponent: 8,
                                   bitsPerPixel: 32, bytesPerRow: rowBytes, space: colorSpace,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return idle }
        let result = NSImage(cgImage: bitmap, size: idle.size)
        result.isTemplate = false
        result.accessibilityDescription = "Cat Run cat"
        return result
    }

    static func image(
        action: Int = 0,
        phase: Double = 0,
        size: NSSize = NSSize(width: 24, height: 20),
        template: Bool = true
    ) -> NSImage {
        let size = NSSize(width: max(1, size.width), height: max(1, size.height))
        let pixelWidth = Int(ceil(size.width * 2)), pixelHeight = Int(ceil(size.height * 2))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return NSImage(size: size) }
        context.clear(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        let scale = min(CGFloat(pixelWidth) / 28, CGFloat(pixelHeight) / 24)
        context.translateBy(x: (CGFloat(pixelWidth) - 28 * scale) / 2, y: (CGFloat(pixelHeight) - 24 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        context.setLineCap(.round); context.setLineJoin(.round); context.setLineWidth(1.15)
        let component: CGFloat = 0
        let ink = CGColor(red: component, green: component, blue: component, alpha: 1)
        context.setStrokeColor(ink); context.setFillColor(ink)
        draw(in: context, action: action, phase: phase.isFinite ? max(0, min(1, phase)) : 0)
        guard let bitmap = context.makeImage() else { return NSImage(size: size) }
        let result = NSImage(cgImage: bitmap, size: size)
        result.isTemplate = template
        result.accessibilityDescription = "Cat Run cat"
        return result
    }

    /// Removes transparent padding so the visible paws can align with the wordmark.
    static func croppedInkImage(size: NSSize) -> NSImage {
        let image = image(size: size, template: false)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return image }
        var left = cg.width, top = cg.height, right = 0, bottom = 0
        for y in 0..<cg.height {
            for x in 0..<cg.width where bytes[y * cg.bytesPerRow + x * 4 + 3] > 0 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top,
              let cropped = cg.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else { return image }
        let result = NSImage(cgImage: cropped, size: NSSize(width: CGFloat(cropped.width) / 2, height: CGFloat(cropped.height) / 2))
        result.isTemplate = false
        result.accessibilityDescription = "Cat Run cat"
        return result
    }

    private static func draw(in c: CGContext, action: Int, phase: Double) {
        let atRest = phase == 0 || phase == 1
        if !atRest, let activity = CatAnimationAction(rawValue: action), action >= 6 {
            c.saveGState()
            drawActivity(activity, in: c, phase: phase)
            c.restoreGState()
            return
        }
        let wave: CGFloat = atRest ? 0 : CGFloat(sin(phase * .pi * 2))
        let rise: CGFloat = atRest ? 0 : CGFloat(sin(phase * .pi))
        let hop: CGFloat = action == 4 ? rise * 1.4 : 0
        let lift: CGFloat = action == 3 ? rise : 0
        c.saveGState(); c.translateBy(x: 0, y: hop)

        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: 18, y: 3.1))
        tail.addCurve(to: CGPoint(x: 25 + (action == 1 ? wave * 1.5 : 0), y: 10 + (action == 1 ? wave * 3 : 0)),
                      control1: CGPoint(x: 23.5, y: 1), control2: CGPoint(x: 25.8, y: 4.8))
        c.addPath(tail); c.strokePath()

        // Sitting body and paws stay unfilled, so interior features cannot become a solid blob.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 9, y: 11))
        body.addCurve(to: CGPoint(x: 7.8, y: 3.1), control1: CGPoint(x: 7.4, y: 8.5), control2: CGPoint(x: 6.9, y: 4.8))
        body.addCurve(to: CGPoint(x: 12, y: 2), control1: CGPoint(x: 8.2, y: 1.8), control2: CGPoint(x: 10.5, y: 1.5))
        body.addLine(to: CGPoint(x: 17.5, y: 2))
        body.addCurve(to: CGPoint(x: 18.8, y: 10.6), control1: CGPoint(x: 21, y: 2.4), control2: CGPoint(x: 20.2, y: 7.8))
        c.addPath(body); c.strokePath()
        line(c, CGPoint(x: 12.2, y: 7.9), CGPoint(x: 11.7, y: 2.3))
        line(c, CGPoint(x: 15.8, y: 7.9), CGPoint(x: 16.2, y: 2.3))
        line(c, CGPoint(x: 9.2, y: 2.1), CGPoint(x: 10.1, y: 3.2))
        line(c, CGPoint(x: 17, y: 2.1), CGPoint(x: 17.8, y: 3.2))
        if lift > 0.01 {
            let paw = CGMutablePath()
            paw.move(to: CGPoint(x: 9.1, y: 7.5))
            paw.addQuadCurve(to: CGPoint(x: 4.5, y: 7.5 + lift * 5), control: CGPoint(x: 4.5, y: 4.5 + lift * 3))
            c.addPath(paw); c.strokePath()
            c.strokeEllipse(in: CGRect(x: 3.5, y: 6.9 + lift * 5, width: 2, height: 1.6))
        }

        c.saveGState()
        if action == 2 {
            c.translateBy(x: 13.5, y: 14.8); c.rotate(by: wave * 0.14); c.translateBy(x: -13.5, y: -14.8)
        }
        let earWiggle: CGFloat = action == 5 ? wave * 0.8 : 0
        let head = CGMutablePath()
        head.move(to: CGPoint(x: 7.2, y: 12))
        head.addCurve(to: CGPoint(x: 6.5, y: 17), control1: CGPoint(x: 6, y: 13.2), control2: CGPoint(x: 6.1, y: 15.3))
        head.addLine(to: CGPoint(x: 6.2 - earWiggle, y: 21.2))
        head.addLine(to: CGPoint(x: 10.7, y: 18.9))
        head.addQuadCurve(to: CGPoint(x: 16.7, y: 18.9), control: CGPoint(x: 13.7, y: 19.7))
        head.addLine(to: CGPoint(x: 21.1 + earWiggle, y: 21.2))
        head.addLine(to: CGPoint(x: 20.5, y: 16.9))
        head.addCurve(to: CGPoint(x: 19.6, y: 12), control1: CGPoint(x: 21, y: 15.2), control2: CGPoint(x: 20.7, y: 13.1))
        head.addCurve(to: CGPoint(x: 7.2, y: 12), control1: CGPoint(x: 17, y: 9), control2: CGPoint(x: 9.7, y: 9))
        c.addPath(head); c.strokePath()
        c.setLineWidth(0.85)
        line(c, CGPoint(x: 8, y: 18.1), CGPoint(x: 7.9, y: 19.1))
        line(c, CGPoint(x: 19, y: 18.1), CGPoint(x: 19.5, y: 19.1))

        let glance: CGFloat = action == 2 ? wave * 0.9 : 0
        let blink = action == 5 && phase > 0.3 && phase < 0.65
        for x in [CGFloat(10.2), CGFloat(16.7)] {
            if blink { line(c, CGPoint(x: x - 0.8 + glance, y: 15.1), CGPoint(x: x + 0.8 + glance, y: 15.1)) }
            else { c.fillEllipse(in: CGRect(x: x - 0.65 + glance, y: 14.5, width: 1.3, height: 1.6)) }
        }
        let nose = CGMutablePath()
        nose.move(to: CGPoint(x: 12.7 + glance, y: 13.1)); nose.addLine(to: CGPoint(x: 14.3 + glance, y: 13.1))
        nose.addLine(to: CGPoint(x: 13.5 + glance, y: 12.3)); nose.closeSubpath()
        c.addPath(nose); c.fillPath()
        line(c, CGPoint(x: 13.5 + glance, y: 12.3), CGPoint(x: 13.5 + glance, y: 11.6))
        line(c, CGPoint(x: 12.5 + glance, y: 11.3), CGPoint(x: 13.5 + glance, y: 11.6))
        line(c, CGPoint(x: 14.5 + glance, y: 11.3), CGPoint(x: 13.5 + glance, y: 11.6))
        line(c, CGPoint(x: 8.5, y: 13), CGPoint(x: 3.5, y: 13.9))
        line(c, CGPoint(x: 8.3, y: 11.9), CGPoint(x: 3.1, y: 11.4))
        line(c, CGPoint(x: 18.5, y: 13), CGPoint(x: 23.6, y: 13.9))
        line(c, CGPoint(x: 18.8, y: 11.9), CGPoint(x: 24, y: 11.4))
        c.restoreGState(); c.restoreGState()
    }

    private static func line(_ context: CGContext, _ start: CGPoint, _ end: CGPoint) {
        context.move(to: start); context.addLine(to: end); context.strokePath()
    }

    private static func drawActivity(_ action: CatAnimationAction, in c: CGContext, phase: Double) {
        let wave = CGFloat(sin(phase * .pi * 2))
        let pulse = CGFloat(sin(phase * .pi))
        let quick = CGFloat(sin(phase * .pi * 4))
        switch action {
        case .longStretch:
            c.translateBy(x: 0, y: 2)
            sideCat(c, stride: 2.8 + pulse, squat: 0.42 + pulse * 0.12, headDown: 0.35)
            // The forepaws reach forward as the rump and tail stay raised.
            curve(c, from: CGPoint(x: 6, y: 9), to: CGPoint(x: 3, y: 17 + pulse), control1: CGPoint(x: 1, y: 10), control2: CGPoint(x: 2, y: 17))
        case .walk:
            sideCat(c, stride: wave * 2.5, squat: 0, headDown: 0)
        case .trot:
            c.translateBy(x: 14, y: 12 + abs(quick) * 1.1); c.rotate(by: -0.07)
            c.translateBy(x: -14, y: -12)
            sideCat(c, stride: CGFloat(cos(phase * .pi * 6)) * 3.2, squat: 0.12, headDown: -0.12)
            line(c, CGPoint(x: 2.2, y: 8), CGPoint(x: 4.2, y: 8))
            line(c, CGPoint(x: 2.5, y: 5.5), CGPoint(x: 4, y: 5.5))
        case .curlUp:
            c.strokeEllipse(in: CGRect(x: 5, y: 2.6, width: 18, height: 12 + pulse))
            curve(c, from: CGPoint(x: 21, y: 8), to: CGPoint(x: 11, y: 4.8), control1: CGPoint(x: 19, y: 1.7), control2: CGPoint(x: 12, y: 2.8))
            miniFace(c, at: CGPoint(x: 11.5, y: 10.6 + pulse * 0.3), scale: 0.65, tilt: -0.25, expression: .sleep)
            c.setLineWidth(0.8)
            polyline(c, [CGPoint(x: 21, y: 18), CGPoint(x: 24, y: 18), CGPoint(x: 21, y: 15), CGPoint(x: 24, y: 15)])
        case .rollOver:
            c.translateBy(x: 14, y: 12); c.rotate(by: CGFloat(phase * .pi * 2)); c.scaleBy(x: 0.71, y: 0.71); c.translateBy(x: -14, y: -12)
            miniSeated(c, headTilt: 0, expression: .happy, raisedPaw: 0.9)
        case .groom:
            miniSeated(c, headTilt: -0.23 - pulse * 0.1, expression: .tongue, raisedPaw: 0)
            curve(c, from: CGPoint(x: 11.5, y: 7), to: CGPoint(x: 11.5 + quick * 0.4, y: 12), control1: CGPoint(x: 7, y: 9), control2: CGPoint(x: 8, y: 12))
            c.strokeEllipse(in: CGRect(x: 9.6 + quick * 0.4, y: 11, width: 2.2, height: 2))
        case .earScratch:
            miniSeated(c, headTilt: 0.12, expression: .happy, raisedPaw: 0)
            curve(c, from: CGPoint(x: 19, y: 4), to: CGPoint(x: 22.2, y: 17 + wave), control1: CGPoint(x: 25.6, y: 4), control2: CGPoint(x: 25.7, y: 12))
            c.strokeEllipse(in: CGRect(x: 20.5, y: 16 + wave, width: 2.5, height: 1.7))
        case .shake:
            c.saveGState(); c.translateBy(x: 14 + quick * 0.5, y: 11); c.rotate(by: quick * 0.08); c.translateBy(x: -14, y: -11)
            miniSeated(c, headTilt: -quick * 0.06, expression: .happy, raisedPaw: 0)
            c.restoreGState()
            for x: CGFloat in [2.3, 25.7] { line(c, CGPoint(x: x, y: 12 + pulse), CGPoint(x: x, y: 15 + pulse)) }
        case .yawn:
            miniSeated(c, headTilt: 0, expression: .yawn, raisedPaw: 0, mouthOpen: 1 + pulse * 2.5)
        case .sniff:
            c.saveGState(); c.translateBy(x: 0, y: 1); c.scaleBy(x: 0.88, y: 0.88)
            sideCat(c, stride: 0.3, squat: 0.15, headDown: 0.5 + pulse * 0.15)
            c.restoreGState()
            line(c, CGPoint(x: 24, y: 2.8), CGPoint(x: 24, y: 6.2))
            for offset in [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1.2)] {
                c.strokeEllipse(in: CGRect(x: 23 + offset.x, y: 6 + offset.y, width: 1.8, height: 1.8))
            }
            line(c, CGPoint(x: 22.5, y: 10.1 + quick * 0.3), CGPoint(x: 23.7, y: 9.3))
        case .pounce:
            c.translateBy(x: 2, y: 1 + pulse * 3); c.scaleBy(x: 0.85, y: 0.85)
            sideCat(c, stride: 3.8 * pulse, squat: -0.12, headDown: 0.2)
            line(c, CGPoint(x: 8, y: 2), CGPoint(x: 10, y: 3.5))
            line(c, CGPoint(x: 12, y: 1.5), CGPoint(x: 14, y: 3))
        case .ballPlay:
            c.saveGState(); c.translateBy(x: 4.5, y: 1); c.scaleBy(x: 0.8, y: 0.8)
            miniSeated(c, headTilt: -0.12, expression: .normal, raisedPaw: pulse)
            c.restoreGState()
            let ball = CGRect(x: 2.1 + pulse * 1.2, y: 2.6 + abs(quick) * 3.2, width: 3.6, height: 3.6)
            c.strokeEllipse(in: ball)
            line(c, CGPoint(x: ball.minX + 0.7, y: ball.minY + 0.6), CGPoint(x: ball.maxX - 0.6, y: ball.maxY - 0.5))
        case .butterflyWatch:
            c.saveGState(); c.translateBy(x: 4.5, y: 0); c.scaleBy(x: 0.83, y: 0.83)
            miniSeated(c, headTilt: -0.18 + wave * 0.05, expression: .normal, raisedPaw: 0.4)
            c.restoreGState()
            let center = CGPoint(x: 4 + wave, y: 18 + pulse * 2)
            let width: CGFloat = 1.3 + abs(quick) * 0.8
            c.strokeEllipse(in: CGRect(x: center.x - width, y: center.y, width: width, height: 2.2))
            c.strokeEllipse(in: CGRect(x: center.x, y: center.y, width: width, height: 2.2))
            line(c, CGPoint(x: center.x, y: center.y - 0.5), CGPoint(x: center.x, y: center.y + 2.2))
        case .heartPurr:
            c.saveGState(); c.translateBy(x: 4, y: 0); c.scaleBy(x: 0.82, y: 0.82)
            miniSeated(c, headTilt: wave * 0.03, expression: .happy, raisedPaw: 0)
            c.restoreGState()
            heart(c, at: CGPoint(x: 4.3, y: 18.4), scale: 0.8 + pulse * 0.25)
        case .peek:
            miniFace(c, at: CGPoint(x: 14, y: 10 + pulse * 6), scale: 0.75, tilt: wave * 0.06, expression: .normal)
            // The box hides the body; its rim and two rounded paws make the action readable.
            c.stroke(CGRect(x: 5.5, y: 2.5, width: 17, height: 8))
            c.strokeEllipse(in: CGRect(x: 8.3, y: 9.5, width: 3, height: 2))
            c.strokeEllipse(in: CGRect(x: 17, y: 9.5, width: 3, height: 2))
        default: break
        }
    }

    private enum FaceExpression { case normal, happy, sleep, yawn, tongue }

    private static func miniSeated(_ c: CGContext, headTilt: CGFloat, expression: FaceExpression,
                                   raisedPaw: CGFloat, mouthOpen: CGFloat = 2.2) {
        c.setLineWidth(1.05)
        curve(c, from: CGPoint(x: 19, y: 3.8), to: CGPoint(x: 24.5, y: 10.5), control1: CGPoint(x: 26, y: 2.3), control2: CGPoint(x: 25.7, y: 8))
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 10, y: 10.6))
        body.addCurve(to: CGPoint(x: 9, y: 2.7), control1: CGPoint(x: 7.5, y: 8), control2: CGPoint(x: 7, y: 3))
        body.addQuadCurve(to: CGPoint(x: 19.5, y: 2.7), control: CGPoint(x: 14, y: 1.7))
        body.addCurve(to: CGPoint(x: 18, y: 10.5), control1: CGPoint(x: 22, y: 3), control2: CGPoint(x: 21, y: 8))
        c.addPath(body); c.strokePath()
        line(c, CGPoint(x: 12, y: 7.6), CGPoint(x: 11.7, y: 2.8))
        line(c, CGPoint(x: 16.5, y: 7.6), CGPoint(x: 17, y: 2.8))
        if raisedPaw > 0 {
            curve(c, from: CGPoint(x: 10, y: 8), to: CGPoint(x: 5.2, y: 8 + raisedPaw * 4), control1: CGPoint(x: 6, y: 5), control2: CGPoint(x: 4.7, y: 7 + raisedPaw * 3))
            c.strokeEllipse(in: CGRect(x: 4.2, y: 7.4 + raisedPaw * 4, width: 2.1, height: 1.8))
        }
        miniFace(c, at: CGPoint(x: 14, y: 15), scale: 1, tilt: headTilt, expression: expression, mouthOpen: mouthOpen)
    }

    private static func miniFace(_ c: CGContext, at point: CGPoint, scale: CGFloat, tilt: CGFloat,
                                 expression: FaceExpression, mouthOpen: CGFloat = 2.2) {
        c.saveGState(); c.translateBy(x: point.x, y: point.y); c.rotate(by: tilt); c.scaleBy(x: scale, y: scale)
        c.setLineWidth(1.05)
        let head = CGMutablePath()
        head.move(to: CGPoint(x: -5.4, y: -2.4))
        head.addQuadCurve(to: CGPoint(x: -5.5, y: 2.8), control: CGPoint(x: -7, y: 0))
        head.addLine(to: CGPoint(x: -5.8, y: 6.3)); head.addLine(to: CGPoint(x: -2, y: 4.1))
        head.addQuadCurve(to: CGPoint(x: 2.2, y: 4.1), control: CGPoint(x: 0, y: 4.8))
        head.addLine(to: CGPoint(x: 5.8, y: 6.3)); head.addLine(to: CGPoint(x: 5.5, y: 2.8))
        head.addQuadCurve(to: CGPoint(x: 5.4, y: -2.4), control: CGPoint(x: 7, y: 0))
        head.addCurve(to: CGPoint(x: -5.4, y: -2.4), control1: CGPoint(x: 3.7, y: -5.2), control2: CGPoint(x: -3.7, y: -5.2))
        c.addPath(head); c.strokePath()
        for x: CGFloat in [-2.6, 2.6] {
            if expression == .happy || expression == .sleep || expression == .yawn {
                curve(c, from: CGPoint(x: x - 0.8, y: 0.7), to: CGPoint(x: x + 0.8, y: 0.7), control1: CGPoint(x: x - 0.4, y: 0.1), control2: CGPoint(x: x + 0.4, y: 0.1))
            } else { c.fillEllipse(in: CGRect(x: x - 0.55, y: 0.1, width: 1.1, height: 1.5)) }
        }
        c.fillEllipse(in: CGRect(x: -0.55, y: -1.2, width: 1.1, height: 0.75))
        if expression == .yawn { c.strokeEllipse(in: CGRect(x: -0.85, y: -1.5 - mouthOpen * 0.7, width: 1.7, height: mouthOpen * 0.7)) }
        else {
            curve(c, from: CGPoint(x: -1.1, y: -2), to: CGPoint(x: 1.1, y: -2), control1: CGPoint(x: -0.4, y: -2.8), control2: CGPoint(x: 0.4, y: -2.8))
            if expression == .tongue { c.strokeEllipse(in: CGRect(x: -0.6, y: -3.4, width: 1.2, height: 1.5)) }
        }
        c.setLineWidth(0.75)
        line(c, CGPoint(x: -4.8, y: -1), CGPoint(x: -7.1, y: -0.5))
        line(c, CGPoint(x: 4.8, y: -1), CGPoint(x: 7.1, y: -0.5))
        c.restoreGState()
    }

    private static func sideCat(_ c: CGContext, stride: CGFloat, squat: CGFloat, headDown: CGFloat) {
        let back: CGFloat = 14 - squat * 6
        let belly: CGFloat = back - 5.7
        c.setLineWidth(1)
        // Each pair has its own phase, so the silhouette visibly steps or bounds.
        for (hip, direction, lift) in [(CGFloat(9), CGFloat(1), CGFloat(0.8)), (CGFloat(18.8), CGFloat(-1), CGFloat(0.6)), (CGFloat(11), CGFloat(-1), CGFloat(0)), (CGFloat(20), CGFloat(1), CGFloat(0))] {
            let pawX = hip + direction * stride
            line(c, CGPoint(x: hip, y: belly + 0.4), CGPoint(x: pawX, y: 3.2 + lift))
            c.strokeEllipse(in: CGRect(x: pawX - 0.9, y: 2.2 + lift, width: 2.5, height: 1.6))
        }
        curve(c, from: CGPoint(x: 8.3, y: back - 1), to: CGPoint(x: 3.5, y: 18 - squat * 2), control1: CGPoint(x: 2.6, y: back + 0.8), control2: CGPoint(x: 6, y: 20 - squat * 2))
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 20, y: back + 0.2))
        body.addCurve(to: CGPoint(x: 8, y: back - 0.1), control1: CGPoint(x: 16, y: back + 1.5), control2: CGPoint(x: 11, y: back + 1.6))
        body.addCurve(to: CGPoint(x: 9.3, y: belly), control1: CGPoint(x: 5, y: back - 1), control2: CGPoint(x: 5.8, y: belly + 0.5))
        body.addQuadCurve(to: CGPoint(x: 20.1, y: belly + 0.9), control: CGPoint(x: 15, y: belly - 1.2))
        c.addPath(body); c.strokePath()
        c.saveGState(); c.translateBy(x: 21.1, y: back + 1.5 - headDown * 3); c.rotate(by: -headDown * 0.45)
        let head = CGMutablePath()
        head.move(to: CGPoint(x: -2.8, y: -1))
        head.addLine(to: CGPoint(x: -3.1, y: 4.8)); head.addLine(to: CGPoint(x: -0.5, y: 3.2))
        head.addLine(to: CGPoint(x: 1.7, y: 4.8)); head.addLine(to: CGPoint(x: 2.1, y: 2.1))
        head.addQuadCurve(to: CGPoint(x: 3.7, y: -0.5), control: CGPoint(x: 4.1, y: 1.2))
        head.addQuadCurve(to: CGPoint(x: -2.8, y: -1), control: CGPoint(x: 2, y: -4))
        c.addPath(head); c.strokePath()
        c.fillEllipse(in: CGRect(x: 0.5, y: 0.3, width: 1, height: 1.2))
        c.fillEllipse(in: CGRect(x: 3.3, y: -0.4, width: 1, height: 0.7))
        c.restoreGState()
    }

    private static func curve(_ c: CGContext, from: CGPoint, to: CGPoint, control1: CGPoint, control2: CGPoint) {
        c.move(to: from); c.addCurve(to: to, control1: control1, control2: control2); c.strokePath()
    }

    private static func polyline(_ c: CGContext, _ points: [CGPoint]) {
        guard let first = points.first else { return }
        c.move(to: first); points.dropFirst().forEach { c.addLine(to: $0) }; c.strokePath()
    }

    private static func heart(_ c: CGContext, at point: CGPoint, scale: CGFloat) {
        c.saveGState(); c.translateBy(x: point.x, y: point.y); c.scaleBy(x: scale, y: scale)
        let heart = CGMutablePath()
        heart.move(to: CGPoint(x: 0, y: -2.3))
        heart.addCurve(to: CGPoint(x: 0, y: 1.6), control1: CGPoint(x: -5, y: 0.8), control2: CGPoint(x: -1.6, y: 4.3))
        heart.addCurve(to: CGPoint(x: 0, y: -2.3), control1: CGPoint(x: 1.6, y: 4.3), control2: CGPoint(x: 5, y: 0.8))
        c.addPath(heart); c.strokePath(); c.restoreGState()
    }
}
