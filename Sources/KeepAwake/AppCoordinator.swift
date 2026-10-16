import AppKit
import Darwin
import KeepAwakeCore
import ServiceManagement

@main
enum CatRunLauncher {
    static func main() {
        let application = NSApplication.shared
        guard !SingleInstance.redirectToRunningInstanceIfNeeded() else { return }
        let delegate = AppCoordinator()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class AppCoordinator: NSObject, NSApplicationDelegate {
    private var model = SessionModel(preferences: PreferenceStore.load())
    private let power = PowerAssertionManager()
    private let monitor = BatteryMonitor()
    private let login = LoginService()
    private lazy var window = AppWindow()
    private lazy var status = CatStatusItem()
    private var reading = BatteryReading(hasBattery: true, percent: nil, onAC: false, minutesToEmpty: nil)
    private var tickTimer: Timer?
    private var expiryTimer: Timer?
    private var batteryTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pendingWarning: UUID?
    private var transientNotice = ""
    private var failedLoginRequest: Bool?
    private var persistentNotice = UserDefaults.standard.string(forKey: "lastSafetyStop") ?? ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        window.onStartStop = { [weak self] in guard let self else { return }; self.model.active ? self.stop(.manual) : self.requestStart() }
        window.onDuration = { [weak self] value in guard let self else { return }; if self.model.setDurationMinutes(value) { self.clearPending(); self.transientNotice = ""; self.save(); self.render() } }
        window.onScreen = { [weak self] value in guard let self else { return }; if self.model.setKeepScreenAwake(value) { self.clearPending(); self.save(); self.render() } }
        window.onRecent = { [weak self] value in self?.requestStart(duration: value) }
        window.onExtend = { [weak self] in self?.requestStart(extensionRequest: true) }
        window.onLogin = { [weak self] enabled in self?.setLogin(enabled) }
        window.onLoginSettings = { [weak self] in guard let self, !self.model.active else { return }; self.login.openSystemSettings() }
        window.onShow = { [weak self] in self?.refreshBattery() }
        status.onOpen = { [weak self] in guard let self else { return }; self.window.present(showMain: !self.persistentNotice.isEmpty || self.model.stopReason != nil) }
        status.onQuit = { NSApp.terminate(nil) }
        monitor.onChange = { [weak self] reading in self?.receive(reading) }
        monitor.start()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.stop(.systemSleep) })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshBattery() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshBattery() })
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in self?.render() })
        observers.append(NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.render() })
        render()
        // Login launches stay in the menu bar; opening the app directly shows the window.
        let isLoginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !isLoginLaunch { window.present() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.present(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        model.stop(reason: .quit); power.release(); cancelTimers(); monitor.stop(); status.invalidate(); save()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
    private func requestStart(duration: Int? = nil, extensionRequest: Bool = false, confirmed: Bool = false) {
        guard pendingWarning == nil else { return }
        if extensionRequest && !model.active { return }
        if !extensionRequest && model.active { return }
        reading = monitor.refresh()
        if model.advance(now: ContinuousTime.now, battery: reading) { didStop(); render(); return }
        let selected = duration ?? model.selectedDurationMinutes
        let result = extensionRequest ? model.prepareExtension(battery: reading, now: ContinuousTime.now, confirmRisk: confirmed) : model.prepareStart(durationMinutes: selected, battery: reading, now: ContinuousTime.now, confirmRisk: confirmed)
        switch result {
        case .blocked(let reason):
            transientNotice = reason.message; render()
        case .warning(_, let warning):
            let token = UUID(); pendingWarning = token
            window.confirmWarning(warning.message) { [weak self] accepted in
                guard let self, self.pendingWarning == token else { return }
                self.pendingWarning = nil
                if accepted { self.requestStart(duration: selected, extensionRequest: extensionRequest, confirmed: true) }
            }
        case .ready(let plan):
            do {
                if plan.isExtension { try power.updateTimeout(seconds: plan.timeoutSeconds) }
                else { try power.acquire(keepScreenAwake: plan.keepScreenAwake, timeout: plan.timeoutSeconds) }
                guard model.commit(plan, now: ContinuousTime.now) else {
                    power.release(); model.stop(reason: .assertionFailure); transientNotice = "The timer changed. Please start again."; cancelTimers(); render(); return
                }
                transientNotice = ""; persistentNotice = ""; UserDefaults.standard.removeObject(forKey: "lastSafetyStop")
                save(); scheduleTimers(); render()
            } catch {
                if !model.active { power.release() }
                transientNotice = plan.isExtension ? "Could not extend the timer. The original timer is still running." : "Could not keep the Mac awake. The timer has not started."
                render()
            }
        }
    }
    private func receive(_ fresh: BatteryReading) {
        reading = fresh
        if model.advance(now: ContinuousTime.now, battery: fresh) { didStop() }
        if pendingWarning != nil, fresh.hasBattery, (fresh.validPercent == nil || fresh.validPercent! < 15) {
            clearPending()
            transientNotice = fresh.validPercent == nil ? StartBlockReason.batteryUnavailable.message : StartBlockReason.lowBattery.message
        }
        render()
    }
    private func refreshBattery() { receive(monitor.refresh()) }
    private func stop(_ reason: SessionStopReason) {
        clearPending()
        guard model.stop(reason: reason) else { return }
        didStop(); render()
    }
    private func didStop() {
        power.release(); cancelTimers(); clearPending(); transientNotice = ""
        if let reason = model.stopReason, [.lowBattery, .batteryUnavailable, .assertionFailure, .systemSleep, .clockUnavailable].contains(reason) {
            persistentNotice = reason.message
            UserDefaults.standard.set(persistentNotice, forKey: "lastSafetyStop")
        }
        save()
    }
    private func clearPending() { pendingWarning = nil; window.cancelWarning() }
    private func setLogin(_ enabled: Bool) {
        guard !model.active else { render(); return }
        do { try login.setEnabled(enabled); failedLoginRequest = nil }
        catch { failedLoginRequest = enabled }
        render()
    }
    private func scheduleTimers() {
        cancelTimers()
        guard model.active else { return }
        let expiry = Timer(timeInterval: max(0.001, model.remaining(at: ContinuousTime.now)), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.refreshBattery()
            if self.model.active { self.scheduleTimers() }
        }
        expiry.tolerance = 0.1; expiryTimer = expiry; RunLoop.main.add(expiry, forMode: .common)
        let battery = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshBattery() }
        battery.tolerance = 5; batteryTimer = battery; RunLoop.main.add(battery, forMode: .common)
        scheduleMinuteTick()
    }
    private func scheduleMinuteTick() {
        guard model.active else { return }
        let remaining = model.remaining(at: ContinuousTime.now)
        let next = remaining - max(0, ceil(remaining / 60) - 1) * 60
        let timer = Timer(timeInterval: max(0.1, next + 0.02), repeats: false) { [weak self] _ in
            guard let self else { return }; if self.model.advance(now: ContinuousTime.now, battery: self.reading) { self.didStop() }; self.render(); self.scheduleMinuteTick()
        }
        timer.tolerance = 0.25; tickTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func cancelTimers() { tickTimer?.invalidate(); expiryTimer?.invalidate(); batteryTimer?.invalidate(); tickTimer = nil; expiryTimer = nil; batteryTimer = nil }
    private func save() { PreferenceStore.save(model.preferences) }
    private func render() {
        let remaining = model.remaining(at: ContinuousTime.now)
        var view = WindowState()
        view.active = model.active; view.duration = model.selectedDurationMinutes; view.remaining = remaining
        view.screenAwake = model.keepScreenAwake; view.recent = model.preferences.previousDurations
        if !reading.hasBattery { view.battery = "Connected to power" }
        else if let percent = reading.validPercent { view.battery = "Battery \(Int(floor(percent)))%" + (reading.onAC ? " · Plugged in" : "") }
        else { view.battery = "Battery reading unavailable" }
        view.notice = !transientNotice.isEmpty ? transientNotice : (!persistentNotice.isEmpty ? persistentNotice : SessionNotice.message(for: model.stopReason, finishedAt: model.finishedAt))
        if !model.active, reading.hasBattery, let percent = reading.validPercent, percent < 15, view.notice.isEmpty { view.notice = StartBlockReason.lowBattery.message }
        let loginStatus = login.status
        view.loginEnabled = loginStatus == .enabled || loginStatus == .requiresApproval
        view.loginNeedsApproval = loginStatus == .requiresApproval
        if let requested = failedLoginRequest, LoginStatusText.isSatisfied(requested, by: loginStatus) {
            failedLoginRequest = nil
        }
        view.loginNote = LoginStatusText.note(for: loginStatus, failedRequest: failedLoginRequest)
        view.canStart = !reading.hasBattery || (reading.validPercent.map { $0 >= 15 } ?? false)
        if persistentNotice == SessionStopReason.lowBattery.message, let percent = reading.validPercent, percent >= 15, transientNotice.isEmpty { view.notice = "Stopped because battery fell below 15%." }
        if persistentNotice == SessionStopReason.batteryUnavailable.message, reading.validPercent != nil, transientNotice.isEmpty { view.notice = "Stopped when the battery reading was unavailable." }
        view.canExtend = model.totalDurationSeconds < 6 * 60 * 60
        window.render(view)
        status.update(active: model.active, remaining: remaining, attention: !persistentNotice.isEmpty)
    }
    private func installMenu() {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Cat Run", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
    }
}

enum LoginStatusText {
    static func isSatisfied(_ enabled: Bool, by status: SMAppService.Status) -> Bool {
        enabled ? (status == .enabled || status == .requiresApproval)
            : (status == .notRegistered || status == .notFound)
    }

    static func note(for status: SMAppService.Status, failedRequest: Bool? = nil) -> String {
        if let requested = failedRequest, !isSatisfied(requested, by: status) {
            return requested ? "Could not turn on launch at login. Try again."
                : "Could not turn off launch at login. Try again."
        }
        switch status {
        case .requiresApproval:
            return "Allow Cat Run in Login Items to finish enabling this setting."
        case .notFound, .notRegistered, .enabled:
            // A never-registered service may be notFound. Only an attempted change can fail.
            return ""
        @unknown default:
            return "Launch at login is unavailable. Check Login Items in System Settings."
        }
    }
}

private enum PreferenceStore {
    private static let key = "preferences.v1"
    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key), data.count <= 8192,
              let preferences = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return preferences.sanitized()
    }
    static func save(_ preferences: Preferences) {
        if let data = try? JSONEncoder().encode(preferences.sanitized()) { UserDefaults.standard.set(data, forKey: key) }
    }
}
private enum ContinuousTime {
    private static let secondsPerTick: Double = { var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return Double(info.numer) / Double(info.denom) / 1_000_000_000 }()
    static var now: TimeInterval { Double(mach_continuous_time()) * secondsPerTick }
}
