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
    private let safety = SessionSafetyGuard()
    private let monitor = BatteryMonitor()
    private let login = LoginService()
    private let journal = SessionJournal(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cat Run/session.json"))
    private lazy var window = AppWindow()
    private lazy var status = CatStatusItem()
    private var reading = BatteryReading(hasBattery: true, percent: nil, onAC: false)
    private var tickTimer: Timer?
    private var expiryTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pendingWarning: UUID?
    private var sessionToken: UUID?
    private var lastRecord: SessionRecord?
    private var transientNotice = ""
    private var legacyNotice = UserDefaults.standard.string(forKey: "lastSafetyStop") ?? ""
    private var failedLoginRequest: Bool?
    private var userSessionActive = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        restoreOutcome()
        // Recording runs on the guard queue even when the interface is unresponsive.
        // A failed write leaves the active marker for conservative interruption recovery.
        safety.onStopRecorded = { [journal] event in
            try? journal.finish(id: event.token, reason: event.reason.rawValue, endedAt: event.date)
        }
        safety.onStop = { [weak self] _ in
            guard let self else { return }
            self.consumeSafetyEvents(); self.render()
        }
        window.onStartStop = { [weak self] in
            guard let self else { return }
            self.model.active ? self.stop(.manual) : self.requestStart()
        }
        window.onDuration = { [weak self] value in
            guard let self else { return }
            if self.model.setDurationMinutes(value) { self.clearPending(); self.transientNotice = ""; self.save(); self.render() }
        }
        window.onScreen = { [weak self] value in
            guard let self else { return }
            if self.model.setKeepScreenAwake(value) { self.clearPending(); self.save(); self.render() }
        }
        window.onRecent = { [weak self] value in self?.requestStart(duration: value) }
        window.onExtend = { [weak self] in self?.requestStart(extensionRequest: true) }
        window.onLogin = { [weak self] enabled in self?.setLogin(enabled) }
        window.onLoginSettings = { [weak self] in guard let self, !self.model.active else { return }; self.login.openSystemSettings() }
        window.onShow = { [weak self] in self?.refreshBattery() }
        status.onOpen = { [weak self] in
            guard let self else { return }
            self.window.present(showMain: self.lastRecord != nil || self.model.stopReason != nil || !self.legacyNotice.isEmpty)
        }
        status.onQuit = { NSApp.terminate(nil) }
        monitor.onChange = { [weak self] reading in self?.receive(reading) }

        // Register wake fallback before the monitor: a wake must reconcile a running
        // session as interrupted before a fresh battery sample can label it finished.
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.stop(.systemSleep) })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.stop(.systemSleep); self.refreshBattery()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.userSessionActive = false; self.stop(.sessionInactive)
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.userSessionActive = true; self.refreshBattery()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in self?.stop(.shutdown) })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshBattery() })
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in self?.render() })
        observers.append(NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.render() })
        monitor.start()
        render()
        let isLoginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !isLoginLaunch { window.present() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.present(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if let token = sessionToken { safety.stop(token: token, reason: .quit) }
        consumeSafetyEvents()
        safety.release(); cancelTimers(); monitor.stop(); status.invalidate(); save()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    private func restoreOutcome() {
        do {
            lastRecord = try journal.recoverInterrupted()
            if lastRecord != nil { legacyNotice = "" }
        } catch {
            do {
                if try journal.quarantineUnreadableRecord() {
                    transientNotice = "Previous timer status unavailable. Start a new timer."
                } else { transientNotice = "Session status could not be read. Try again." }
            } catch { transientNotice = "Session status could not be read. Try again." }
        }
    }

    private func requestStart(duration: Int? = nil, extensionRequest: Bool = false, confirmed: Bool = false) {
        guard pendingWarning == nil, userSessionActive else { return }
        // Drain older guard events before considering a new generation.
        safety.checkNow()
        if consumeSafetyEvents() { render(); return }
        if extensionRequest != model.active { return }
        reading = monitor.refresh()
        let selected = duration ?? model.selectedDurationMinutes
        let result = extensionRequest
            ? model.prepareExtension(battery: reading, now: ContinuousTime.now, confirmRisk: confirmed)
            : model.prepareStart(durationMinutes: selected, battery: reading, now: ContinuousTime.now, confirmRisk: confirmed)
        switch result {
        case .blocked(let reason): transientNotice = reason.message; render()
        case .warning(_, let warning):
            let token = UUID(); pendingWarning = token
            window.confirmWarning(warning.message) { [weak self] accepted in
                guard let self, self.pendingWarning == token else { return }
                self.pendingWarning = nil
                if accepted { self.requestStart(duration: selected, extensionRequest: extensionRequest, confirmed: true) }
            }
        case .ready(let plan):
            let token = sessionToken ?? UUID()
            do {
                if plan.isExtension {
                    try safety.extend(token: token, by: 900)
                } else {
                    // Save the marker before acquiring power; failures are recorded as
                    // failed starts and never add a recent duration or resume on launch.
                    _ = try journal.recoverInterrupted()
                    try journal.begin(id: token, startedAt: Date())
                    try safety.begin(token: token, keepScreenAwake: plan.keepScreenAwake, timeout: plan.timeoutSeconds)
                    sessionToken = token
                }
                let commitTime = plan.isExtension ? ContinuousTime.now
                    : (safety.stateSnapshot().deadline.map { $0 - plan.timeoutSeconds } ?? ContinuousTime.now)
                guard model.commit(plan, now: commitTime) else {
                    safety.stop(token: token, reason: .assertionFailure)
                    consumeSafetyEvents(); transientNotice = "The timer changed. Please start again."; render(); return
                }
                // The main thread is responsive again after synchronous OS work.
                // Do not count acquisition latency against its next heartbeat.
                safety.heartbeat(token: token)
                transientNotice = ""; legacyNotice = ""; lastRecord = nil
                UserDefaults.standard.removeObject(forKey: "lastSafetyStop")
                save(); scheduleTimers(); render()
            } catch {
                let didStop = consumeSafetyEvents()
                if !plan.isExtension {
                    safety.release(token: token)
                    sessionToken = nil
                    let reason: SessionStopReason
                    if case SessionSafetyError.blocked(let blocked) = error { reason = blocked }
                    else { reason = .assertionFailure }
                    try? journal.finish(id: token, reason: reason.rawValue, endedAt: Date())
                    lastRecord = try? journal.load()
                    if case SessionSafetyError.blocked(.lowBattery) = error { transientNotice = StartBlockReason.lowBattery.message }
                    else if case SessionSafetyError.blocked(.batteryUnavailable) = error { transientNotice = StartBlockReason.batteryUnavailable.message }
                    else { transientNotice = "Could not safely start the timer. Please try again." }
                } else if !didStop {
                    transientNotice = model.active ? "Could not extend the timer. The original timer is still running." : "The timer stopped. Please start again."
                }
                render()
            }
        }
    }

    private func receive(_ fresh: BatteryReading) {
        reading = fresh
        safety.checkNow()
        consumeSafetyEvents()
        if pendingWarning != nil, fresh.hasBattery, (fresh.validPercent == nil || fresh.validPercent! < 15) {
            clearPending()
            transientNotice = fresh.validPercent == nil ? StartBlockReason.batteryUnavailable.message : StartBlockReason.lowBattery.message
        }
        render()
    }
    private func refreshBattery() { receive(monitor.refresh()) }
    private func stop(_ reason: SessionStopReason) {
        clearPending()
        if let token = sessionToken { safety.stop(token: token, reason: reason) }
        consumeSafetyEvents(); render()
    }

    @discardableResult
    private func consumeSafetyEvents() -> Bool {
        var changed = false
        for event in safety.drainStopEvents() {
            guard event.token == sessionToken else { continue }
            changed = true
            model.stop(reason: event.reason, at: event.date)
            sessionToken = nil
            cancelTimers(); clearPending(); transientNotice = ""
            lastRecord = try? journal.load()
            if lastRecord?.id != event.token || lastRecord?.state != .finished {
                transientNotice = "Timer stopped; its status could not be saved."
                lastRecord = nil
            }
            save()
        }
        return changed
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
            guard let self else { return }; self.refreshBattery()
            if self.model.active { self.scheduleTimers() }
        }
        expiry.tolerance = 0.1; expiryTimer = expiry; RunLoop.main.add(expiry, forMode: .common)
        scheduleMinuteTick()
    }
    private func scheduleMinuteTick() {
        guard model.active else { return }
        let remaining = model.remaining(at: ContinuousTime.now)
        let next = remaining - max(0, ceil(remaining / 60) - 1) * 60
        let timer = Timer(timeInterval: max(0.1, next + 0.02), repeats: false) { [weak self] _ in
            guard let self else { return }; self.refreshBattery(); self.scheduleMinuteTick()
        }
        timer.tolerance = 0.25; tickTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func cancelTimers() { tickTimer?.invalidate(); expiryTimer?.invalidate(); tickTimer = nil; expiryTimer = nil }
    private func save() { PreferenceStore.save(model.preferences) }
    private func render() {
        let remaining = model.remaining(at: ContinuousTime.now)
        var view = WindowState()
        view.active = model.active; view.duration = model.selectedDurationMinutes; view.remaining = remaining
        view.screenAwake = model.keepScreenAwake; view.recent = model.preferences.previousDurations
        if !reading.hasBattery { view.battery = "Connected to power" }
        else if let percent = reading.validPercent { view.battery = "Battery \(Int(floor(percent)))%" + (reading.onAC ? " · Plugged in" : "") }
        else { view.battery = "Battery reading unavailable" }
        view.notice = transientNotice
        if view.notice.isEmpty, model.active {
            if case .estimatedBelowMinimum(let percent)? = SessionModel.forecastWarning(battery: reading, seconds: remaining) {
                view.notice = "Battery may reach \(Int(floor(percent)))%. Stops below 15%."
            }
        } else if view.notice.isEmpty {
            view.notice = SessionNotice.message(for: lastRecord)
            if view.notice.isEmpty { view.notice = !legacyNotice.isEmpty ? legacyNotice : SessionNotice.message(for: model.stopReason, finishedAt: model.finishedAt) }
        }
        if !model.active, reading.hasBattery, let percent = reading.validPercent, percent < 15, view.notice.isEmpty { view.notice = StartBlockReason.lowBattery.message }
        let loginStatus = login.status
        view.loginEnabled = loginStatus == .enabled || loginStatus == .requiresApproval
        view.loginNeedsApproval = loginStatus == .requiresApproval
        if let requested = failedLoginRequest, LoginStatusText.isSatisfied(requested, by: loginStatus) { failedLoginRequest = nil }
        view.loginNote = LoginStatusText.note(for: loginStatus, failedRequest: failedLoginRequest)
        view.canStart = userSessionActive && (!reading.hasBattery || (reading.validPercent.map { $0 >= 15 } ?? false))
        view.canExtend = model.totalDurationSeconds < 6 * 60 * 60
        window.render(view)
        status.update(active: model.active, remaining: remaining, attention: !model.active && (lastRecord?.reason.map { $0 != "expired" && $0 != "manual" && $0 != "quit" } ?? !legacyNotice.isEmpty))
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
