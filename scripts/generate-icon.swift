import AppKit
import Foundation

// Original vector artwork. No downloaded images or external dependencies.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift generate-icon.swift output.iconset\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (filename, pixels) in sizes {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
        pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "CatRun.Icon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true
    context.cgContext.clear(CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    let peach = NSColor(srgbRed: 251.0 / 255, green: 193.0 / 255,
                        blue: 147.0 / 255, alpha: 1)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                 xRadius: 196, yRadius: 196).fill()
    NSColor.black.setFill()
    peach.setStroke()
    let tail = NSBezierPath()
    tail.lineWidth = 59
    tail.lineCapStyle = .round
    tail.move(to: NSPoint(x: 660, y: 280))
    tail.curve(to: NSPoint(x: 805, y: 467),
               controlPoint1: NSPoint(x: 848, y: 208),
               controlPoint2: NSPoint(x: 871, y: 381))
    tail.stroke()
    let body = NSBezierPath(roundedRect: NSRect(x: 329, y: 202, width: 362, height: 363),
                            xRadius: 146, yRadius: 146)
    body.lineWidth = 32
    body.fill()
    body.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 291, y: 540))
    head.line(to: NSPoint(x: 291, y: 790))
    head.line(to: NSPoint(x: 415, y: 698))
    head.line(to: NSPoint(x: 607, y: 698))
    head.line(to: NSPoint(x: 732, y: 790))
    head.line(to: NSPoint(x: 732, y: 540))
    head.curve(to: NSPoint(x: 291, y: 540),
               controlPoint1: NSPoint(x: 677, y: 411),
               controlPoint2: NSPoint(x: 346, y: 411))
    head.lineWidth = 32
    head.lineJoinStyle = .round
    head.fill()
    head.stroke()
    peach.setFill()
    for x in [409.0, 586.0] {
        NSBezierPath(ovalIn: NSRect(x: x, y: 566, width: 30, height: 39)).fill()
    }
    let nose = NSBezierPath()
    nose.move(to: NSPoint(x: 497, y: 536))
    nose.line(to: NSPoint(x: 525, y: 536))
    nose.line(to: NSPoint(x: 511, y: 520))
    nose.close()
    nose.fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CatRun.Icon", code: 2)
    }
    try png.write(to: output.appendingPathComponent(filename), options: .atomic)
}
