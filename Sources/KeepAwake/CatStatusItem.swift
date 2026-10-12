import AppKit
import CoreText
import KeepAwakeCore

/// Shared timing rules make animation independent of delayed run-loop callbacks.
enum CatAnimationTiming {
    static let duration: TimeInterval = 2
    static let frameCount = 17
    static let repeatInterval: TimeInterval = 5
    static func interval(lowPower: Bool) -> TimeInterval { lowPower ? 0.5 : 0.125 }
    static func frameIndex(elapsed: TimeInterval, lowPower: Bool) -> Int {
        guard elapsed.isFinite else { return frameCount - 1 }
        let elapsed = min(duration, max(0, elapsed))
        return min(frameCount - 1, Int(floor(elapsed / interval(lowPower: lowPower))) * (lowPower ? 4 : 1))
    }
}

struct StatusCountdown: Equatable {
    let hours: Int
    let minutes: Int

    init(remaining: TimeInterval) {
        let total = Self.roundedMinutes(remaining: remaining)
        hours = total / 60
        minutes = total % 60
    }

    static func roundedMinutes(remaining: TimeInterval) -> Int {
        DurationFormat.minutes(seconds: remaining)
    }

    var hoursLine: String { String(format: "%02d", hours) }
    var minutesLine: String { String(format: "%02d", minutes) }
    var accessibilityText: String {
        "\(hours) \(hours == 1 ? "hour" : "hours"), \(minutes) \(minutes == 1 ? "minute" : "minutes") remaining"
    }

    static func font(size: CGFloat = 9) -> NSFont {
        let base = NSFont(name: "Verdana", size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
        ]]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func contentRect(catSize: NSSize) -> NSRect {
        let width = ceil(("00" as NSString).size(withAttributes: [.font: font()]).width) + 2
        return NSRect(x: catSize.width + 2, y: 0, width: width, height: catSize.height)
    }

    func layout(in bounds: NSRect) -> (font: NSFont, hours: NSRect, minutes: NSRect) {
        var font = Self.font()
        let fullHeight = ceil((hoursLine as NSString).size(withAttributes: [.font: font]).height)
        if fullHeight * 2 > bounds.height {
            font = Self.font(size: max(6, 9 * bounds.height / (fullHeight * 2)))
        }
        let rowHeight = bounds.height / 2
        let textHeight = min(rowHeight, ceil((hoursLine as NSString).size(withAttributes: [.font: font]).height))
        return (
            font,
            NSRect(x: bounds.minX, y: bounds.midY + (rowHeight - textHeight) / 2, width: bounds.width, height: textHeight),
            NSRect(x: bounds.minX, y: bounds.minY + (rowHeight - textHeight) / 2, width: bounds.width, height: textHeight)
        )
    }

    func draw(in bounds: NSRect, foreground: NSColor) {
        let layout = layout(in: bounds)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [.font: layout.font, .foregroundColor: foreground, .paragraphStyle: paragraph]
        (hoursLine as NSString).draw(in: layout.hours, withAttributes: attributes)
        (minutesLine as NSString).draw(in: layout.minutes, withAttributes: attributes)
    }

    /// A single template image lets macOS tint both cat and text for its actual menu-bar appearance.
    func image(cat: NSImage) -> NSImage {
        let content = Self.contentRect(catSize: cat.size)
        let size = NSSize(width: content.maxX, height: cat.size.height)
        let scale: CGFloat = 2
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let catImage = cat.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return cat }
        context.scaleBy(x: scale, y: scale)
        context.draw(catImage, in: NSRect(origin: .zero, size: cat.size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(in: content, foreground: .black)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return cat }
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = size
        let result = NSImage(size: size)
        result.addRepresentation(representation)
        result.isTemplate = true
        return result
    }
}

/// Only the current displayed minute is retained; frame changes reuse already composed images.
struct StatusCountdownImageCache {
    static let maximumEntries = CatAnimationTiming.frameCount + 2
    private var countdown: StatusCountdown?
    private var images: [ObjectIdentifier: NSImage] = [:]
    var count: Int { images.count }

    mutating func image(cat: NSImage, countdown: StatusCountdown) -> NSImage {
        if self.countdown != countdown { images.removeAll(keepingCapacity: true); self.countdown = countdown }
        let key = ObjectIdentifier(cat)
        if let image = images[key] { return image }
        if images.count >= Self.maximumEntries { images.removeAll(keepingCapacity: true) }
        let image = countdown.image(cat: cat)
        images[key] = image
        return image
    }

    mutating func clear() { images.removeAll(keepingCapacity: true); countdown = nil }
}

/// Cached raster frames, animated for two seconds at a time rather than continuously.
final class CatStatusItem: NSObject {
    var onOpen: (() -> Void)?
    var onQuit: (() -> Void)?
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var countdown = StatusCountdown(remaining: 0)
    private var composedFrames = StatusCountdownImageCache()
    private var currentCat: NSImage?
    private var animationTimer: Timer?
    private var restTimer: Timer?
    private var frame = 0
    private var frames: [NSImage] = []
    private var active = false
    private var invalidated = false
    private var screensAwake = true
    private var lastAction: CatAnimationAction?
    private let idle = CatArtwork.image()
    private let activePose = CatArtwork.image(action: 3, phase: 0.5)
    private lazy var animations = CatAnimationAction.allCases.map { action in (0..<CatAnimationTiming.frameCount).map { CatArtwork.image(action: action.rawValue, phase: Double($0) / Double(CatAnimationTiming.frameCount - 1)) } }
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        if let button = item.button {
            button.image = idle
            button.imagePosition = .imageOnly
            button.title = ""
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Cat Run. Open window")
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.resetAnimation() })
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.resetAnimation() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.resetAnimation() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.screensAwake = false; self?.resetAnimation() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.screensAwake = true; self?.resetAnimation() })
    }

    func update(active: Bool, remaining: TimeInterval, attention: Bool) {
        guard !invalidated else { return }
        let changed = self.active != active
        self.active = active
        countdown = StatusCountdown(remaining: remaining)
        if !active { composedFrames.clear() }
        item.button?.toolTip = active ? "Cat Run · \(Self.time(remaining)) remaining" : (attention ? "Cat Run stopped · click for details" : "Cat Run · inactive")
        item.button?.setAccessibilityLabel(active ? "Cat Run · \(countdown.accessibilityText)" : (item.button?.toolTip ?? "Cat Run"))
        if changed { resetAnimation() }
        else { display(currentCat ?? idle) }
    }

    static func time(_ seconds: TimeInterval) -> String {
        DurationFormat.string(seconds: seconds)
    }
    private func display(_ cat: NSImage) {
        currentCat = cat
        item.button?.image = active ? composedFrames.image(cat: cat, countdown: countdown) : cat
    }
    private var shouldAnimate: Bool {
        !invalidated && active && screensAwake && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }
    private func resetAnimation() {
        animationTimer?.invalidate(); animationTimer = nil
        restTimer?.invalidate(); restTimer = nil
        guard !invalidated else { return }
        // Reduce Motion gets a clear active pose, without frame-by-frame movement.
        display(active ? activePose : idle)
        if shouldAnimate { beginAction() }
    }
    private func beginAction() {
        guard shouldAnimate else { resetAnimation(); return }
        restTimer?.invalidate(); restTimer = nil
        animationTimer?.invalidate(); animationTimer = nil
        var generator = SystemRandomNumberGenerator()
        let action = CatAnimationAction.choose(excluding: lastAction, using: &generator)
        lastAction = action
        composedFrames.clear()
        frames = animations[action.rawValue - 1]; frame = 0
        display(frames[frame])
        // Low Power Mode uses four visible updates over two seconds, not total suppression.
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let startedAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: CatAnimationTiming.interval(lowPower: lowPower), repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.shouldAnimate else { self.resetAnimation(); return }
            let nextFrame = CatAnimationTiming.frameIndex(elapsed: ProcessInfo.processInfo.systemUptime - startedAt, lowPower: lowPower)
            if nextFrame != self.frame {
                self.frame = nextFrame
                self.display(self.frames[self.frame])
            }
            if self.frame == self.frames.count - 1 {
                timer.invalidate(); self.animationTimer = nil
            }
        }
        timer.tolerance = lowPower ? 0.05 : 0.015
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        // A fixed start-to-start cadence includes the action's two seconds.
        let next = Timer(timeInterval: CatAnimationTiming.repeatInterval, repeats: false) { [weak self] _ in self?.beginAction() }
        next.tolerance = 0.05
        restTimer = next
        RunLoop.main.add(next, forMode: .common)
    }
    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let open = menu.addItem(withTitle: "Open", action: #selector(openApp), keyEquivalent: "")
            open.target = self
            let quit = menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "")
            quit.target = self
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else { onOpen?() }
    }
    @objc private func openApp() { onOpen?() }
    @objc private func quitApp() { onQuit?() }
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        active = false
        restTimer?.invalidate(); restTimer = nil
        animationTimer?.invalidate(); animationTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        composedFrames.clear()
        NSStatusBar.system.removeStatusItem(item)
    }
}
