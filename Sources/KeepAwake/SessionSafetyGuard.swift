import Darwin
import Foundation
import KeepAwakeCore

protocol SessionPowerManaging: AnyObject {
    func acquire(keepScreenAwake: Bool, timeout: TimeInterval) throws
    func release()
}
extension PowerAssertionManager: SessionPowerManaging {}

protocol SessionBatteryReading: AnyObject {
    func read() -> BatteryReading
}
extension BatteryReader: SessionBatteryReading {}

struct SessionSafetyClock {
    let continuous: TimeInterval
    let uptime: TimeInterval
    let date: Date

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func read() -> SessionSafetyClock {
        // Sample uptime between two continuous readings to reduce sampling skew.
        let first = Double(mach_continuous_time()) * secondsPerTick
        let uptime = Double(mach_absolute_time()) * secondsPerTick
        let last = Double(mach_continuous_time()) * secondsPerTick
        return SessionSafetyClock(continuous: (first + last) / 2, uptime: uptime, date: Date())
    }

    var isValid: Bool {
        continuous.isFinite && continuous >= 0 && uptime.isFinite && uptime >= 0
            && date.timeIntervalSince1970.isFinite
    }
}

enum SessionSafetyError: Error, Equatable {
    case invalidDuration, alreadyActive, staleSession, pendingStop
    case blocked(SessionStopReason)
}

/// Owns power assertions and fresh battery checks on a queue independent of AppKit.
/// No polling runs while idle. A short OS lease also bounds a stalled guard itself.
final class SessionSafetyGuard {
    struct StopEvent: Equatable {
        let token: UUID
        let reason: SessionStopReason
        let continuousTime: TimeInterval
        let date: Date
    }
    struct Snapshot {
        let token: UUID?
        let deadline: TimeInterval?
        let terminalEvents: [StopEvent]
    }

    static let checkInterval: TimeInterval = 10
    static let heartbeatTimeout: TimeInterval = 30
    static let maximumLease: TimeInterval = 45
    static let sleepGapTolerance: TimeInterval = 1

    private struct Session {
        let token: UUID
        let keepScreenAwake: Bool
        var deadline: TimeInterval
        let maximumDeadline: TimeInterval
        var leaseDeadline: TimeInterval
        var lastClock: SessionSafetyClock
        var lastHeartbeatUptime: TimeInterval
    }

    private let queue = DispatchQueue(label: "org.catrun.session-safety", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let power: SessionPowerManaging
    private let battery: SessionBatteryReading
    private let clock: () -> SessionSafetyClock
    private let automaticallySchedule: Bool
    private let deliverToMain: (@escaping () -> Void) -> Void
    private var session: Session?
    private var timer: DispatchSourceTimer?
    private var terminalEvents: [StopEvent] = []
    private var stopHandler: ((StopEvent) -> Void)?
    private var recordHandler: ((StopEvent) -> Void)?

    /// Delivered asynchronously on the main queue; the terminal record is already
    /// available through drainStopEvents, even if the UI has not received this yet.
    var onStop: ((StopEvent) -> Void)? {
        get { synchronized { stopHandler } }
        set { synchronized { stopHandler = newValue } }
    }

    /// Runs on the guard queue after power has been released and before onStop.
    /// The callback must be thread-safe and must not synchronously enter AppKit.
    var onStopRecorded: ((StopEvent) -> Void)? {
        get { synchronized { recordHandler } }
        set { synchronized { recordHandler = newValue } }
    }

    init(power: SessionPowerManaging = PowerAssertionManager(),
         battery: SessionBatteryReading = BatteryReader(),
         clock: @escaping () -> SessionSafetyClock = SessionSafetyClock.read,
         automaticallySchedule: Bool = true,
         deliverToMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.power = power
        self.battery = battery
        self.clock = clock
        self.automaticallySchedule = automaticallySchedule
        self.deliverToMain = deliverToMain
        queue.setSpecific(key: queueKey, value: true)
    }

    func begin(token: UUID, keepScreenAwake: Bool, timeout: TimeInterval) throws {
        try synchronized {
            guard session == nil else { throw SessionSafetyError.alreadyActive }
            guard terminalEvents.isEmpty else { throw SessionSafetyError.pendingStop }
            guard timeout.isFinite, timeout > 0, timeout <= SessionModel.maximumSessionSeconds
            else { throw SessionSafetyError.invalidDuration }
            let reading = battery.read()
            let now = clock()
            guard now.isValid, (now.continuous + timeout).isFinite else {
                throw SessionSafetyError.blocked(.clockUnavailable)
            }
            if let reason = batteryStopReason(reading) {
                throw SessionSafetyError.blocked(reason)
            }
            // A failed acquisition never creates a running guard session.
            do {
                try power.acquire(keepScreenAwake: keepScreenAwake,
                                  timeout: min(Self.maximumLease, timeout))
            } catch {
                power.release()
                throw error
            }
            session = Session(token: token, keepScreenAwake: keepScreenAwake,
                              deadline: now.continuous + timeout,
                              maximumDeadline: now.continuous + SessionModel.maximumSessionSeconds,
                              leaseDeadline: now.continuous + min(Self.maximumLease, timeout),
                              lastClock: now, lastHeartbeatUptime: now.uptime)
            // A delayed OS acquisition must not report an already stale session.
            let afterAcquisition = clock()
            if let active = session, let reason = timingStopReason(for: active, at: afterAcquisition) {
                terminate(reason, at: afterAcquisition)
                throw SessionSafetyError.blocked(reason)
            }
            scheduleNextCheck()
        }
    }

    /// Extends the existing deadline exactly, independent of acquisition latency.
    func extend(token: UUID, by additionalSeconds: TimeInterval) throws {
        try synchronized {
            guard additionalSeconds.isFinite, additionalSeconds > 0,
                  additionalSeconds <= SessionModel.maximumSessionSeconds
            else { throw SessionSafetyError.invalidDuration }
            try extendLocked(token: token) { active, _ in active.deadline + additionalSeconds }
        }
    }

    /// timeout is the total time remaining after the proposed extension.
    func extend(token: UUID, timeout: TimeInterval) throws {
        try synchronized {
            guard timeout.isFinite, timeout > 0, timeout <= SessionModel.maximumSessionSeconds
            else { throw SessionSafetyError.invalidDuration }
            try extendLocked(token: token) { _, now in now.continuous + timeout }
        }
    }

    private func extendLocked(token: UUID,
                              proposedDeadline: (Session, SessionSafetyClock) -> TimeInterval) throws {
        guard session?.token == token else { throw SessionSafetyError.staleSession }
        check(renewLease: false)
        guard var active = session, active.token == token else {
            throw SessionSafetyError.staleSession
        }
        let now = clock()
        if let reason = timingStopReason(for: active, at: now) {
            terminate(reason, at: now)
            throw SessionSafetyError.blocked(reason)
        }
        let deadline = proposedDeadline(active, now)
        guard deadline.isFinite, deadline >= active.deadline, deadline > now.continuous,
              deadline <= active.maximumDeadline else { throw SessionSafetyError.invalidDuration }
        let timeout = min(Self.maximumLease, deadline - now.continuous)
        do {
            try power.acquire(keepScreenAwake: active.keepScreenAwake, timeout: timeout)
        } catch {
            // Never leave an uncertain partially renewed session running.
            terminate(.assertionFailure, at: clock())
            throw error
        }
        let afterAcquisition = clock()
        if let reason = timingStopReason(for: active, at: afterAcquisition) {
            terminate(reason, at: afterAcquisition)
            throw SessionSafetyError.blocked(reason)
        }
        active.deadline = deadline
        active.leaseDeadline = now.continuous + timeout
        active.lastClock = afterAcquisition
        active.lastHeartbeatUptime = afterAcquisition.uptime
        session = active
        scheduleNextCheck()
    }

    /// Serializes user/lifecycle stops with background battery and expiry events.
    func stop(token: UUID, reason: SessionStopReason) {
        synchronized {
            guard let active = session, active.token == token else { return }
            let now = clock()
            let actualReason: SessionStopReason
            if reason == .systemSleep || reason == .unresponsive {
                actualReason = reason
            } else if let safetyReason = timingStopReason(for: active, at: now) {
                actualReason = safetyReason
            } else {
                actualReason = reason
            }
            terminate(actualReason, at: now)
        }
    }

    /// An old generation cannot release a later session's assertions.
    func release(token: UUID? = nil) {
        synchronized {
            if let token, session?.token != token { return }
            cancelTimer()
            session = nil
            power.release()
        }
    }

    /// May be called from the main queue; pings queued by the guard call this too.
    func heartbeat(token: UUID) {
        // Record when the main queue actually responded, not when this queue
        // eventually processes its ping after a delayed I/O operation.
        let observed = clock()
        queue.async { [weak self] in
            guard let self, var active = self.session, active.token == token else { return }
            guard observed.isValid, observed.uptime >= active.lastHeartbeatUptime else { return }
            active.lastHeartbeatUptime = observed.uptime
            self.session = active
        }
    }

    func stateSnapshot() -> Snapshot {
        synchronized { Snapshot(token: session?.token, deadline: session?.deadline,
                                terminalEvents: terminalEvents) }
    }

    func drainStopEvents() -> [StopEvent] {
        synchronized {
            let events = terminalEvents
            terminalEvents.removeAll()
            return events
        }
    }

    /// UI observations do not postpone the independent lease-renewal timer.
    /// Tests can explicitly request renewal with automatic scheduling disabled.
    func checkNow(renewLease: Bool = false) {
        synchronized { check(renewLease: renewLease) }
    }

    private func check(renewLease: Bool) {
        guard var active = session else { return }
        var now = clock()
        if let reason = timingStopReason(for: active, at: now) {
            terminate(reason, at: now)
            return
        }
        let reading = battery.read()
        // IOKit is synchronous. Recheck time after it returns, rather than renew
        // a lease using a timestamp captured before a potentially delayed read.
        now = clock()
        if let reason = timingStopReason(for: active, at: now) {
            terminate(reason, at: now)
            return
        }
        if let reason = batteryStopReason(reading) {
            terminate(reason, at: now)
            return
        }
        if renewLease {
            let timeout = min(Self.maximumLease, active.deadline - now.continuous)
            do {
                try power.acquire(keepScreenAwake: active.keepScreenAwake, timeout: timeout)
            } catch {
                terminate(.assertionFailure, at: clock())
                return
            }
            let afterAcquisition = clock()
            if let reason = timingStopReason(for: active, at: afterAcquisition) {
                terminate(reason, at: afterAcquisition)
                return
            }
            active.leaseDeadline = now.continuous + timeout
            now = afterAcquisition
        }
        active.lastClock = now
        session = active
        if renewLease {
            if automaticallySchedule {
                let token = active.token
                deliverToMain { [weak self] in self?.heartbeat(token: token) }
            }
            scheduleNextCheck()
        }
    }

    private func timingStopReason(for active: Session, at now: SessionSafetyClock) -> SessionStopReason? {
        guard now.isValid, now.continuous >= active.lastClock.continuous,
              now.uptime >= active.lastClock.uptime else { return .clockUnavailable }
        let continuousDelta = now.continuous - active.lastClock.continuous
        let uptimeDelta = now.uptime - active.lastClock.uptime
        // A missed sleep notification must not turn an interrupted timer into a
        // successful completion because its deadline passed while asleep.
        if continuousDelta - uptimeDelta > Self.sleepGapTolerance { return .systemSleep }
        // A queue that wakes after multiple boundaries must not claim a complete
        // session when heartbeat protection or the OS lease lapsed before its end.
        // A lease deliberately bounded to the session deadline is normal expiry.
        let heartbeatRemaining = Self.heartbeatTimeout - (now.uptime - active.lastHeartbeatUptime)
        let heartbeatDeadline = now.continuous + heartbeatRemaining
        if heartbeatRemaining <= 0, heartbeatDeadline < active.deadline { return .unresponsive }
        if active.leaseDeadline < active.deadline, now.continuous >= active.leaseDeadline {
            return .assertionFailure
        }
        if now.continuous >= active.deadline { return .expired }
        return nil
    }

    private func batteryStopReason(_ reading: BatteryReading) -> SessionStopReason? {
        guard reading.hasBattery else { return nil }
        guard let percent = reading.validPercent else { return .batteryUnavailable }
        return percent < SessionModel.minimumBatteryPercent ? .lowBattery : nil
    }

    private func terminate(_ reason: SessionStopReason, at now: SessionSafetyClock) {
        guard let active = session else { return }
        cancelTimer()
        power.release()
        session = nil
        let stoppedAt = reason == .expired ? active.deadline
            : (now.continuous.isFinite && now.continuous >= 0
               ? now.continuous : active.lastClock.continuous)
        let observedDate = now.date.timeIntervalSince1970.isFinite ? now.date : active.lastClock.date
        let stopDate = reason == .expired && now.continuous.isFinite
            ? observedDate.addingTimeInterval(min(0, active.deadline - now.continuous)) : observedDate
        let event = StopEvent(token: active.token, reason: reason,
                              continuousTime: stoppedAt, date: stopDate)
        terminalEvents.append(event)
        recordHandler?(event)
        if let callback = stopHandler { deliverToMain { callback(event) } }
    }

    private func scheduleNextCheck() {
        guard automaticallySchedule, let active = session else { return }
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.setEventHandler { [weak self] in self?.check(renewLease: true) }
            timer = source
            source.resume()
        }
        let remaining = active.deadline - clock().continuous
        let interval = max(0.001, min(Self.checkInterval, remaining))
        timer?.schedule(deadline: .now() + interval, leeway: .milliseconds(Int(min(1, interval / 10) * 1_000)))
    }

    private func cancelTimer() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func synchronized<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try work() }
        return try queue.sync(execute: work)
    }

    deinit {
        synchronized {
            cancelTimer()
            power.release()
        }
    }
}
