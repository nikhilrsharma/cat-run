import AppKit
import CoreText
import KeepAwakeCore

struct WindowState {
    var active = false
    var duration = 15
    var remaining: TimeInterval = 0
    var screenAwake = true
    var recent: [Int] = []
    var battery = ""
    var notice = ""
    var loginEnabled = false
    var loginNote = ""
    var loginNeedsApproval = false
    var canExtend = true
    var canStart = true
}

final class AppWindow: NSWindowController, NSWindowDelegate {
    var onStartStop: (() -> Void)?
    var onDuration: ((Int) -> Void)?
    var onScreen: ((Bool) -> Void)?
    var onRecent: ((Int) -> Void)?
    var onExtend: (() -> Void)?
    var onLogin: ((Bool) -> Void)?
    var onLoginSettings: (() -> Void)?
    var onViewLogs: (() -> Void)?
    var onShow: (() -> Void)?
    private let root = DarkView()
    private let main = FlippedView()
    private let settings = FlippedView()
    private let logs = AuditLogView()
    private let brand = BrandWordmark(frame: .zero)
    private let cat = NSImageView()
    private let navigation = FlatButton("Settings", size: 13)
    private let title = AppWindow.label("Duration", size: 15)
    private let time = AppWindow.label("15m", size: 15)
    private let slider = NSSlider(value: 15, minValue: 15, maxValue: 360, target: nil, action: nil)
    private let minus = FlatButton("−", size: 19, soft: true, dimWhenDisabled: true)
    private let plus = FlatButton("+", size: 19, soft: true, dimWhenDisabled: true)
    private let recentTitle = AppWindow.label("Previously used", size: 13)
    private let recent = FlippedView()
    private let recentEmpty = AppWindow.label("No timers used yet.", size: 13)
    private let mainRule = AppWindow.rule()
    private let mac = CatCheckbox("Keep Mac awake")
    private let macLock = LockHintView()
    private let lockHint = LockHintBubble()
    private let screen = CatCheckbox("Keep screen awake")
    private let battery = AppWindow.label("", size: 13)
    private let notice = AppWindow.label("", size: 14)
    private let start = FlatButton("Start", primary: true)
    private let extend = FlatButton("+15m", size: 13)
    private let login = CatCheckbox("Launch at login")
    private let loginNote = AppWindow.label("", size: 13)
    private let approval = FlatButton("Open Login Settings", size: 14)
    private let viewLogs = FlatButton("View logs", size: 14)
    private let settingsRule = AppWindow.rule()
    private let about = AppWindow.label("About", size: 15)
    private let credit = AppWindow.label("Created by Nikhil Sharma with assistance from OpenAI’s ChatGPT models.", size: 13)
    private let inspiration = AppWindow.label("Inspired by Caffeine by Dominic Rodemer.", size: 13)
    private let version = AppWindow.label("", size: 13)
    private let license = AppWindow.label("Open source · MIT License", size: 13)
    private var cachedRecents: [Int]?
    private var showingSettings = false
    private var showingLogs = false
    private var warningSheet: NSWindow?
    private var layoutObservers: [NSObjectProtocol] = []
    private var hoverMonitor: Any?
    static let minimumContentSize = NSSize(width: 420, height: 400)
    private var sizingPolicy: WindowSizingPolicy?

    init(persistWindowFrame: Bool = true) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.minimumContentSize), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Cat Run"
        window.titleVisibility = .hidden
        window.backgroundColor = DarkView.base
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        root.wantsLayer = true
        window.contentView = root
        configure()
        root.onLayout = { [weak self] in self?.layoutContent() }
        if persistWindowFrame { window.setFrameAutosaveName("CatRunWindow") }
        let needsInitialPlacement = !persistWindowFrame || !UserDefaults.standard.bool(forKey: "hasPlacedWindow")
        applyBounds(resetToDefault: needsInitialPlacement)
        layoutContent()
        layoutObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.applyBounds() })
        if persistWindowFrame && !UserDefaults.standard.bool(forKey: "hasPlacedWindow") {
            window.center(); UserDefaults.standard.set(true, forKey: "hasPlacedWindow")
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    deinit {
        layoutObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
    }

    private func configure() {
        cat.image = CatArtwork.headerImage(size: NSSize(width: 48, height: 40), foreground: AppPalette.foreground)
        cat.imageScaling = .scaleProportionallyUpOrDown
        cat.setAccessibilityElement(false)
        macLock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: LockHintView.hintText)
        macLock.contentTintColor = AppPalette.foreground
        macLock.imageScaling = .scaleProportionallyDown
        macLock.onHoverChange = { [weak self] showing in self?.setLockHintVisible(showing) }
        // A local monitor sees only this application's events, never other apps or global input.
        // It also dismisses the hint when an event goes directly to another control.
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged]) { [weak self] event in
            if let self, event.window === self.window {
                let point = self.macLock.convert(event.locationInWindow, from: nil)
                self.macLock.setPointerInside(!self.showingSettings && !self.showingLogs && self.macLock.bounds.contains(point))
            }
            return event
        }
        navigation.onClick = { [weak self] in
            guard let self else { return }
            self.showSettings(self.showingLogs || !self.showingSettings)
        }
        for (view, id) in [(brand, "title"), (cat, "cat"), (navigation, "navigation"), (main, "main-page"), (settings, "settings-page"), (logs, "logs-page")] as [(NSView, String)] {
            view.identifier = NSUserInterfaceItemIdentifier(id); root.addSubview(view)
        }
        for (view, id) in [(title, "duration"), (time, "time"), (slider, "slider"), (minus, "minus"), (plus, "plus"), (recentTitle, "history-label"), (recent, "history"), (recentEmpty, "history-empty"), (mainRule, "main-rule"), (mac, "mac-checkbox"), (macLock, "mac-lock"), (screen, "screen-checkbox"), (battery, "battery"), (notice, "notice"), (start, "action"), (extend, "extend")] as [(NSView, String)] {
            view.identifier = NSUserInterfaceItemIdentifier(id); main.addSubview(view)
        }
        for (view, id) in [(login, "login-checkbox"), (loginNote, "login-note"), (approval, "login-approval"), (viewLogs, "view-logs"), (settingsRule, "settings-rule"), (about, "about"), (credit, "credit"), (inspiration, "inspiration"), (version, "version"), (license, "license")] as [(NSView, String)] {
            view.identifier = NSUserInterfaceItemIdentifier(id); settings.addSubview(view)
        }
        lockHint.identifier = NSUserInterfaceItemIdentifier("lock-hint")
        lockHint.isHidden = true
        root.addSubview(lockHint)
        time.alignment = .right
        slider.cell = SmoothSliderCell(); slider.minValue = 15; slider.maxValue = 360; slider.doubleValue = 15
        slider.numberOfTickMarks = 24; slider.allowsTickMarkValuesOnly = true; slider.tickMarkPosition = .below
        slider.target = self; slider.action = #selector(sliderChanged); slider.setAccessibilityLabel("Duration in minutes")
        minus.onClick = { [weak self] in guard let self else { return }; self.onDuration?(Int(self.slider.doubleValue) - 15) }
        plus.onClick = { [weak self] in guard let self else { return }; self.onDuration?(Int(self.slider.doubleValue) + 15) }
        minus.setAccessibilityLabel("Decrease duration by 15 minutes"); plus.setAccessibilityLabel("Increase duration by 15 minutes")
        mac.state = .on; mac.isEnabled = false; mac.toolTip = LockHintView.hintText
        screen.target = self; screen.action = #selector(screenChanged)
        start.onClick = { [weak self] in self?.onStartStop?() }
        extend.onClick = { [weak self] in self?.onExtend?() }
        login.target = self; login.action = #selector(loginChanged)
        approval.onClick = { [weak self] in self?.onLoginSettings?() }
        viewLogs.onClick = { [weak self] in self?.showLogs() }
        let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
        let updated = Bundle.main.object(forInfoDictionaryKey: "CatRunLastUpdated") as? String ?? "2026-10-17"
        version.stringValue = "Version \(number) · Updated \(updated)"
        settings.isHidden = true
        logs.isHidden = true
    }

    // Every state occupies the same slots. Hidden controls never move the footer.
    private func layoutContent() {
        let w = root.bounds.width, h = root.bounds.height, inset: CGFloat = 24
        let available = w - inset * 2
        let brandPadding = brand.drawingPadding
        brand.frame = NSRect(x: inset - brandPadding, y: 9 - brandPadding,
                            width: max(98, ceil(brand.inkBounds.width)) + brandPadding * 2,
                            height: 35 + brandPadding * 2)
        let catHeight: CGFloat = 28
        let ratio = (cat.image?.size.width ?? 1) / max(1, cat.image?.size.height ?? 1)
        // Align the button's outer bottom with the wordmark and paws; center its title inside.
        let headerBottom = brand.convert(brand.inkBounds, to: root).maxY
        cat.frame = NSRect(x: brand.frame.maxX - brandPadding + 10, y: headerBottom - catHeight,
                          width: catHeight * ratio, height: catHeight)
        navigation.frame = NSRect(x: w - inset - 86, y: headerBottom - 30, width: 86, height: 30)
        main.frame = NSRect(x: inset, y: 62, width: available, height: h - 78)
        settings.frame = main.frame
        logs.frame = main.frame
        title.frame = NSRect(x: 0, y: 0, width: available - 100, height: 23)
        time.frame = NSRect(x: available - 96, y: 0, width: 96, height: 23)
        minus.frame = NSRect(x: 0, y: 31, width: 40, height: 32)
        slider.frame = NSRect(x: 50, y: 32, width: available - 100, height: 30)
        plus.frame = NSRect(x: available - 40, y: 31, width: 40, height: 32)
        recentTitle.frame = NSRect(x: 0, y: 81, width: 111, height: 20)
        recent.frame = NSRect(x: 121, y: 74, width: available - 121, height: 32)
        recentEmpty.frame = NSRect(x: 121, y: 81, width: available - 121, height: 20)
        for (index, view) in recent.subviews.enumerated() {
            let width = min(100, (recent.bounds.width - 12) / 3)
            view.frame = NSRect(x: CGFloat(index) * (width + 6), y: 0, width: width, height: 32)
        }
        mainRule.frame = NSRect(x: 0, y: 113, width: available, height: 1)
        mac.frame = NSRect(x: 0, y: 122, width: mac.intrinsicContentSize.width, height: 27)
        macLock.frame = NSRect(x: mac.frame.maxX + 1, y: 122, width: 27, height: 27)
        let lockFrame = macLock.convert(macLock.bounds, to: root)
        let hintSize = lockHint.intrinsicContentSize
        lockHint.frame = NSRect(x: max(inset, min(w - inset - hintSize.width, lockFrame.midX - hintSize.width / 2)),
                                y: lockFrame.minY - hintSize.height - 5, width: hintSize.width, height: hintSize.height)
        screen.frame = NSRect(x: 0, y: 152, width: available, height: 27)
        battery.frame = NSRect(x: 0, y: 199, width: available - 94, height: 20)
        extend.frame = NSRect(x: available - 86, y: 192, width: 86, height: 30)
        // Some regional date formats need a third line after a detection label.
        // Reserve it without moving the Start/Stop footer or reducing the font.
        notice.frame = NSRect(x: 0, y: 227, width: available, height: 53)
        start.frame = NSRect(x: 0, y: main.bounds.height - 40, width: available, height: 40)
        login.frame = NSRect(x: 0, y: 0, width: available, height: 28)
        loginNote.frame = NSRect(x: 0, y: 39, width: available, height: 42)
        approval.frame = NSRect(x: 0, y: 90, width: 184, height: 32)
        viewLogs.frame = NSRect(x: available - 110, y: 90, width: 110, height: 32)
        settingsRule.frame = NSRect(x: 0, y: 126, width: available, height: 1)
        about.frame = NSRect(x: 0, y: 143, width: available, height: 23)
        credit.frame = NSRect(x: 0, y: 172, width: available, height: 44)
        inspiration.frame = NSRect(x: 0, y: 222, width: available, height: 21)
        version.frame = NSRect(x: 0, y: 250, width: available, height: 21)
        license.frame = NSRect(x: 0, y: 282, width: available, height: 21)
    }

    func render(_ state: WindowState) {
        title.stringValue = state.active ? "Remaining" : "Duration"
        time.stringValue = state.active ? CatStatusItem.time(state.remaining) : CatStatusItem.time(Double(state.duration * 60))
        slider.doubleValue = Double(state.duration); slider.isEnabled = !state.active
        minus.isEnabled = !state.active && state.duration > 15; plus.isEnabled = !state.active && state.duration < 360
        screen.state = state.screenAwake ? .on : .off; screen.isEnabled = !state.active
        screen.toolTip = state.active ? nil : "Prevents the display from sleeping during the timer."
        start.title = state.active ? "Stop" : "Start"; start.isEnabled = state.active || state.canStart
        extend.isHidden = !state.active; extend.isEnabled = state.canExtend
        battery.stringValue = state.battery
        notice.stringValue = state.notice; notice.isHidden = state.notice.isEmpty
        login.state = state.loginEnabled ? .on : .off; login.isEnabled = !state.active
        login.toolTip = nil
        loginNote.stringValue = state.active ? "" : state.loginNote
        loginNote.isHidden = loginNote.stringValue.isEmpty
        approval.isHidden = !state.loginNeedsApproval; approval.isEnabled = !state.active
        if cachedRecents != state.recent {
            recent.subviews.forEach { $0.removeFromSuperview() }
            for value in state.recent.prefix(3) {
                let button = FlatButton(CatStatusItem.time(Double(value * 60)), size: 13)
                button.onClick = { [weak self] in self?.onRecent?(value) }; recent.addSubview(button)
            }
            cachedRecents = state.recent
        }
        recent.isHidden = state.recent.isEmpty; recentEmpty.isHidden = !state.recent.isEmpty
        recent.subviews.forEach { ($0 as? NSButton)?.isEnabled = !state.active }
        layoutContent()
    }
    func present(showMain: Bool = false) { if showMain { showSettings(false) }; onShow?(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); applyBounds() }
    func confirmWarning(_ message: String, completion: @escaping (Bool) -> Void) {
        guard let window else { completion(false); return }
        cancelWarning()
        let panel = makeWarningPanel(message)
        warningSheet = panel
        window.beginSheet(panel) { [weak self, weak panel] response in if self?.warningSheet === panel { self?.warningSheet = nil }; completion(response == .OK) }
    }
    // Build independently of presentation so its geometry can be checked offscreen.
    func makeWarningPanel(_ message: String) -> NSPanel {
        let panel = WarningPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Battery warning"; panel.titlebarAppearsTransparent = true; panel.backgroundColor = DarkView.base
        panel.appearance = NSAppearance(named: .darkAqua)
        let background = DarkView(); panel.contentView = background
        let cancel = FlatButton("Cancel", primary: true); let proceed = FlatButton("Continue", size: 15)
        cancel.keyEquivalent = "\r"; proceed.toolTip = "Start with automatic protection below 15%."
        let actions = NSStackView(views: [cancel, proceed]); actions.orientation = .horizontal; actions.spacing = 10; actions.distribution = .fillEqually
        let content = NSStackView(views: [AppWindow.label("Battery warning", size: 21), AppWindow.label(message, size: 15), actions])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 18
        background.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22), content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -22), content.topAnchor.constraint(equalTo: background.topAnchor, constant: 20), content.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -20), cancel.heightAnchor.constraint(equalToConstant: 40), proceed.heightAnchor.constraint(equalToConstant: 40)])
        content.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        cancel.onClick = { [weak self, weak panel] in guard let panel else { return }; self?.window?.endSheet(panel, returnCode: .cancel) }
        panel.onCancel = cancel.onClick
        proceed.onClick = { [weak self, weak panel] in guard let panel else { return }; self?.window?.endSheet(panel, returnCode: .OK) }
        return panel
    }
    func cancelWarning() { if let panel = warningSheet { window?.endSheet(panel, returnCode: .cancel); warningSheet = nil } }
    func setLockHintVisible(_ visible: Bool) {
        lockHint.isHidden = !visible || showingSettings || showingLogs
    }
    private func hideLockHint() { macLock.resetHover(); lockHint.isHidden = true }
    func windowDidResignKey(_ notification: Notification) { hideLockHint() }
    func windowWillClose(_ notification: Notification) { hideLockHint() }
    func showSettings(_ show: Bool) {
        hideLockHint(); showingSettings = show; showingLogs = false
        main.isHidden = show; settings.isHidden = !show; logs.isHidden = true
        navigation.title = show ? "Back" : "Settings"; layoutContent()
    }
    func showLogs() {
        hideLockHint(); showingSettings = false; showingLogs = true
        main.isHidden = true; settings.isHidden = true; logs.isHidden = false
        navigation.title = "Back"; layoutContent(); onViewLogs?(); logs.scrollToNewest()
    }
    func renderLogs(events: [AuditEvent], error: String?) { logs.render(events: events, error: error) }
    @objc private func sliderChanged() { onDuration?(Int((slider.doubleValue / 15).rounded()) * 15) }
    @objc private func screenChanged() { onScreen?(screen.state == .on) }
    @objc private func loginChanged() { onLogin?(login.state == .on) }
    func windowDidChangeScreen(_ notification: Notification) { applyBounds() }
    func windowDidResize(_ notification: Notification) { layoutContent() }
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        sizingPolicy?.constrain(frameSize, relativeTo: sender.frame.size) ?? frameSize
    }
    func windowDidEndLiveResize(_ notification: Notification) { applyBounds() }
    func applyBounds(visibleFrame: NSRect? = nil, resetToDefault: Bool = false) {
        guard let window, let visible = visibleFrame ?? (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let minimumFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)).size
        let policy = WindowSizingPolicy(visibleSize: visible.size, chromeHeight: minimumFrame.height - Self.minimumContentSize.height)
        sizingPolicy = policy
        window.minSize = policy.minimumFrameSize
        window.maxSize = policy.maximumFrameSize
        window.aspectRatio = policy.referenceFrameSize
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        var frame = window.frame
        let oldTop = frame.maxY
        frame.size = resetToDefault ? policy.defaultFrameSize : policy.constrain(frame.size)
        frame.origin.y = oldTop - frame.height
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = frame.height > visible.height
            ? visible.maxY - frame.height
            : max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        if frame != window.frame { window.setFrame(frame, display: true) }
        layoutContent()
    }
    private static func label(_ text: String, size: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.font = font(size); label.textColor = AppPalette.foreground; label.isSelectable = false
        label.setContentCompressionResistancePriority(.required, for: .vertical); return label
    }
    static func font(_ size: CGFloat) -> NSFont { NSFont(name: "Verdana", size: size) ?? .systemFont(ofSize: size) }
    private static func rule() -> NSView { let view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = AppPalette.foreground.withAlphaComponent(0.25).cgColor; return view }
}

class FlippedView: NSView { override var isFlipped: Bool { true } }
final class DarkView: FlippedView {
    var onLayout: (() -> Void)?
    static let base = AppPalette.background
    override func layout() { super.layout(); onLayout?() }
    override func draw(_ dirtyRect: NSRect) {
        Self.base.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}
final class FlatButton: NSButton {
    var onClick: (() -> Void)?
    private var primary = false
    private var soft = false
    private var dimWhenDisabled = false
    init(_ title: String, size: CGFloat = 15, primary: Bool = false, soft: Bool = false, dimWhenDisabled: Bool = false) {
        super.init(frame: .zero); self.primary = primary; self.soft = soft; self.dimWhenDisabled = dimWhenDisabled; self.title = title
        font = AppWindow.font(size); isBordered = false; bezelStyle = .regularSquare
        target = self; action = #selector(invoke); focusRingType = .default
        setButtonType(.momentaryPushIn)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width + 20, height: primary ? 40 : 32) }
    var visibleTitleBounds: NSRect {
        let text = NSAttributedString(string: title, attributes: [.font: font ?? AppWindow.font(15)])
        let ink = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), .useGlyphPathBounds)
        let y = (bounds.height - ink.height) / 2
        return NSRect(x: (bounds.width - ink.width) / 2, y: y, width: ink.width, height: ink.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? (isHighlighted ? 0.18 : (primary ? 0.10 : 0.025)) : 0.015
        AppPalette.foreground.withAlphaComponent(soft ? (isEnabled ? 0.06 : 0.025) : alpha).setFill()
        let radius: CGFloat = soft ? bounds.height / 2 : 8
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius); shape.fill()
        AppPalette.foreground.withAlphaComponent(soft ? (isEnabled ? 0.55 : (dimWhenDisabled ? 0.20 : 0.30)) : (isEnabled ? 0.85 : 0.35)).setStroke(); shape.lineWidth = 1; shape.stroke()
        let titleColor = AppPalette.foreground.withAlphaComponent(!isEnabled && dimWhenDisabled ? 0.30 : 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? AppWindow.font(15), .foregroundColor: titleColor]
        let text = NSAttributedString(string: title, attributes: attrs)
        if let context = NSGraphicsContext.current?.cgContext {
            let line = CTLineCreateWithAttributedString(text)
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let target = visibleTitleBounds
            context.saveGState()
            if isFlipped { context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1) }
            context.textMatrix = .identity
            let baseline = isFlipped ? bounds.height - target.maxY : target.minY
            context.textPosition = NSPoint(x: target.minX - ink.minX, y: baseline - ink.minY)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
    @objc private func invoke() { guard isEnabled else { return }; onClick?() }
}
private final class WarningPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A native switch with artwork wholly inside its frame and native keyboard/AX behavior.
private final class CatCheckbox: NSButton {
    init(_ title: String) {
        super.init(frame: .zero)
        self.title = title; setButtonType(.switch); isBordered = false
        setAccessibilityRole(.checkBox); setAccessibilityLabel(title)
        font = AppWindow.font(15); focusRingType = .default
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize { NSSize(width: (title as NSString).size(withAttributes: [.font: font ?? AppWindow.font(15)]).width + 32, height: 27) }
    override func draw(_ dirtyRect: NSRect) {
        let opacity: CGFloat = isEnabled ? 1 : 0.75
        let y = (bounds.height - 18) / 2
        let box = NSBezierPath(roundedRect: NSRect(x: 3, y: y, width: 18, height: 18), xRadius: 4, yRadius: 4)
        AppPalette.foreground.withAlphaComponent(state == .on ? 0.12 : 0.015).setFill(); box.fill()
        AppPalette.foreground.withAlphaComponent(opacity * 0.8).setStroke(); box.lineWidth = 1; box.stroke()
        if state == .on {
            let check = NSBezierPath(); check.lineWidth = 2; check.lineCapStyle = .round; check.lineJoinStyle = .round
            check.move(to: NSPoint(x: 7, y: y + 9)); check.line(to: NSPoint(x: 11, y: y + 13)); check.line(to: NSPoint(x: 17, y: y + 5))
            AppPalette.foreground.withAlphaComponent(opacity).setStroke(); check.stroke()
        }
        let text = NSAttributedString(string: title, attributes: [.font: font ?? AppWindow.font(15), .foregroundColor: AppPalette.foreground])
        text.draw(at: NSPoint(x: 32, y: (bounds.height - text.size().height) / 2))
    }
}

/// A continuous-looking track with native keyboard, accessibility, and discrete tracking.
/// The same centered geometry is used for hit testing and drawing.
final class SmoothSliderCell: NSSliderCell {
    private let thumbDiameter: CGFloat = 18
    private let edgeClearance: CGFloat = 3

    override func barRect(flipped: Bool) -> NSRect {
        let bounds = controlView?.bounds ?? .zero
        // The native cell's cached track can change during drawing. Define the
        // travel from our view instead, reserving the complete thumb and glow.
        let inset = thumbDiameter / 2 + edgeClearance
        return NSRect(x: bounds.minX + inset, y: bounds.midY - 2,
                      width: max(0, bounds.width - 2 * inset), height: 4)
    }
    override func knobRect(flipped: Bool) -> NSRect {
        let track = barRect(flipped: flipped)
        let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
        return NSRect(x: track.minX + CGFloat(fraction) * track.width - thumbDiameter / 2,
                      y: track.midY - thumbDiameter / 2,
                      width: thumbDiameter, height: thumbDiameter)
    }
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = barRect(flipped: flipped)
        let thumb = knobRect(flipped: flipped)
        AppPalette.foreground.withAlphaComponent(isEnabled ? 0.24 : 0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let filled = NSRect(x: track.minX, y: track.minY,
                            width: max(0, min(track.width, thumb.midX - track.minX)), height: track.height)
        AppPalette.foreground.withAlphaComponent(isEnabled ? 0.70 : 0.32).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
    override func drawKnob(_ rect: NSRect) {
        let knobRect = knobRect(flipped: controlView?.isFlipped ?? false)
        NSGraphicsContext.saveGraphicsState()
        if isEnabled {
            let shadow = NSShadow()
            shadow.shadowColor = AppPalette.foreground.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
        }
        let shape = NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.5, dy: 0.5))
        AppPalette.foreground.withAlphaComponent(isEnabled ? 1 : 0.55).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        AppPalette.foreground.withAlphaComponent(isEnabled ? 1 : 0.60).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
    // Tick values remain native and discrete; the visual track stays uncluttered.
    override func drawTickMarks() {}
}
