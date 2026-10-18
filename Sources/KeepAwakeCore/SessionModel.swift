import Foundation

public enum SessionStopReason: String, Codable, Equatable {
    case manual, expired, lowBattery, batteryUnavailable, clockUnavailable, assertionFailure, systemSleep, quit
    case unresponsive, sessionInactive, shutdown, interrupted, storageFailure

    /// A compact reason shared by the timer notice and the activity log.
    public var shortLabel: String {
        switch self {
        case .manual: return "Stopped by you"
        case .expired: return "Time elapsed"
        case .lowBattery: return "Battery below 15%"
        case .batteryUnavailable: return "Battery reading unavailable"
        case .clockUnavailable: return "Timer clock unavailable"
        case .assertionFailure: return "Keep-awake request failed"
        case .systemSleep: return "Mac went to sleep"
        case .quit: return "Cat Run quit"
        case .unresponsive: return "App stopped responding"
        case .sessionInactive: return "User switched"
        case .shutdown: return "Logout, restart or shutdown"
        case .interrupted: return "Unexpected interruption"
        case .storageFailure: return "Session could not be saved"
        }
    }

    public var message: String {
        let title = "Timer stopped · \(shortLabel)"
        return self == .interrupted ? "\(title)\nCause and stop time unknown." : title
    }

    /// No crash or shutdown cause is inferred after an unrecorded interruption.
    public var auditDescription: String {
        switch self {
        case .manual: return "Timer stopped by you."
        case .expired: return "Timer stopped because its time elapsed."
        case .lowBattery: return "Timer stopped because battery charge fell below 15%."
        case .batteryUnavailable: return "Timer stopped because battery protection could not be verified."
        case .clockUnavailable: return "Timer stopped because its clock could not be verified."
        case .assertionFailure: return "Timer stopped because the keep-awake request failed."
        case .systemSleep: return "Timer stopped when the Mac went to sleep."
        case .quit: return "Timer stopped when Cat Run quit."
        case .unresponsive: return "Timer stopped because Cat Run stopped responding."
        case .sessionInactive: return "Timer stopped when the active user changed."
        case .shutdown: return "Timer stopped for logout, restart or shutdown; macOS did not identify which."
        case .interrupted: return "Unexpected timer interruption detected. Cause and stop time unknown."
        case .storageFailure: return "Timer stopped because its session status could not be saved."
        }
    }

}

public enum StartBlockReason: Equatable {
    case invalidDuration, alreadyActive, notActive, sixHourLimit, lowBattery, batteryUnavailable, invalidClock

    public var message: String {
        switch self {
        case .invalidDuration: return "Choose 15m to 06h, in 15m increments."
        case .alreadyActive: return "Stop the current timer before starting another."
        case .notActive: return "Start a timer before extending it."
        case .sixHourLimit: return "A session can last no more than 06h."
        case .lowBattery: return "Battery is below 15%. Charge to at least 15% before starting."
        case .batteryUnavailable: return "The battery reading is unavailable. Try again when battery protection can be verified."
        case .invalidClock: return "The timer clock is unavailable. Try again."
        }
    }
}

public enum ForecastWarning: Equatable {
    case estimatedBelowMinimum(projectedPercent: Double)

    public var message: String {
        switch self {
        case .estimatedBelowMinimum(let percent):
            return "Battery may fall below 15% during this timer (approximately \(Int(floor(percent)))% remaining at the end). The timer will stop if actual charge falls below 15%, even while plugged in."
        }
    }
}

/// A prepared change is committed only after native wake requests have been acquired successfully.
public struct SessionPlan: Equatable {
    public let timeoutSeconds: TimeInterval
    public let keepScreenAwake: Bool
    public let isExtension: Bool
    public let durationMinutes: Int
    fileprivate let owner: UUID
    fileprivate let revision: UInt64
    fileprivate let preparedAt: TimeInterval
    fileprivate let canCommit: Bool
}

public enum SessionPreparation: Equatable {
    case ready(SessionPlan)
    case warning(SessionPlan, ForecastWarning)
    case blocked(StartBlockReason)
}

/// Session state driven by a continuous monotonic clock that includes system sleep.
/// Wall time is used only to label a completed timer, never to control its duration.
public struct SessionModel {
    public static let minimumBatteryPercent = 15.0
    public static let maximumSessionSeconds: TimeInterval = 6 * 60 * 60
    /// Account for changes in load instead of treating the operating-system estimate as exact.
    public static let forecastRuntimeAllowance = 0.9

    public private(set) var preferences: Preferences
    public private(set) var active = false
    public private(set) var stopReason: SessionStopReason?
    public private(set) var finishedAt: Date?
    public private(set) var stoppedAt: Date?
    public private(set) var totalDurationSeconds: TimeInterval = 0

    private let owner = UUID()
    private var revision: UInt64 = 0
    private var deadline: TimeInterval = 0
    private var lastObservedNow: TimeInterval = 0

    public init(preferences: Preferences = Preferences()) {
        self.preferences = preferences.sanitized()
    }

    public var selectedDurationMinutes: Int { preferences.durationMinutes }
    public var activeDurationMinutes: Int? { active ? Int(totalDurationSeconds / 60) : nil }
    public var keepScreenAwake: Bool { preferences.keepScreenAwake }

    @discardableResult
    public mutating func setDurationMinutes(_ minutes: Int) -> Bool {
        guard !active, Preferences.isValidDuration(minutes) else { return false }
        if preferences.durationMinutes != minutes {
            preferences.durationMinutes = minutes
            revision &+= 1
        }
        return true
    }

    @discardableResult
    public mutating func setKeepScreenAwake(_ value: Bool) -> Bool {
        guard !active else { return false }
        if preferences.keepScreenAwake != value {
            preferences.keepScreenAwake = value
            revision &+= 1
        }
        return true
    }

    public func remaining(at now: TimeInterval) -> TimeInterval {
        guard active else { return 0 }
        let observed = now.isFinite ? max(now, lastObservedNow) : lastObservedNow
        return min(totalDurationSeconds, max(0, deadline - observed))
    }

    public func prepareStart(
        durationMinutes: Int,
        battery: BatteryReading,
        now: TimeInterval,
        confirmRisk: Bool = false
    ) -> SessionPreparation {
        guard !active else { return .blocked(.alreadyActive) }
        guard Preferences.isValidDuration(durationMinutes) else { return .blocked(.invalidDuration) }
        return prepare(
            seconds: TimeInterval(durationMinutes * 60),
            totalMinutes: durationMinutes,
            isExtension: false,
            battery: battery,
            now: now,
            confirmRisk: confirmRisk
        )
    }

    public func prepareStart(
        battery: BatteryReading,
        now: TimeInterval,
        confirmRisk: Bool = false
    ) -> SessionPreparation {
        prepareStart(durationMinutes: preferences.durationMinutes, battery: battery, now: now, confirmRisk: confirmRisk)
    }

    public func prepareExtension(
        battery: BatteryReading,
        now: TimeInterval,
        confirmRisk: Bool = false
    ) -> SessionPreparation {
        guard active, remaining(at: now) > 0 else { return .blocked(.notActive) }
        guard totalDurationSeconds + 900 <= Self.maximumSessionSeconds else { return .blocked(.sixHourLimit) }
        return prepare(
            seconds: remaining(at: now) + 900,
            totalMinutes: Int(totalDurationSeconds / 60) + 15,
            isExtension: true,
            battery: battery,
            now: now,
            confirmRisk: confirmRisk
        )
    }

    private func prepare(
        seconds: TimeInterval,
        totalMinutes: Int,
        isExtension: Bool,
        battery: BatteryReading,
        now: TimeInterval,
        confirmRisk: Bool
    ) -> SessionPreparation {
        guard now.isFinite, now >= 0 else { return .blocked(.invalidClock) }
        if let reason = Self.batteryBlock(battery) { return .blocked(reason) }
        let warning = confirmRisk ? nil : Self.forecastWarning(battery: battery, seconds: seconds)
        let plan = SessionPlan(
            timeoutSeconds: seconds,
            keepScreenAwake: preferences.keepScreenAwake,
            isExtension: isExtension,
            durationMinutes: totalMinutes,
            owner: owner,
            revision: revision,
            preparedAt: now,
            canCommit: warning == nil
        )
        if let warning {
            return .warning(plan, warning)
        }
        return .ready(plan)
    }

    /// Call immediately after acquiring native assertions. Re-prepare after a user confirmation.
    /// A failed acquisition must not call commit, so it cannot add a history entry.
    @discardableResult
    public mutating func commit(_ plan: SessionPlan, now: TimeInterval) -> Bool {
        guard plan.canCommit, plan.owner == owner, plan.revision == revision,
              now.isFinite, now >= plan.preparedAt,
              plan.keepScreenAwake == preferences.keepScreenAwake else { return false }
        if plan.isExtension {
            guard active, remaining(at: now) > 0,
                  plan.durationMinutes == Int(totalDurationSeconds / 60) + 15,
                  totalDurationSeconds + 900 <= Self.maximumSessionSeconds else { return false }
            deadline += 900
            totalDurationSeconds += 900
        } else {
            guard !active, Preferences.isValidDuration(plan.durationMinutes) else { return false }
            totalDurationSeconds = TimeInterval(plan.durationMinutes * 60)
            deadline = now + totalDurationSeconds
            active = true
            preferences.durationMinutes = plan.durationMinutes
            preferences.previousDurations = [plan.durationMinutes] + preferences.previousDurations.filter {
                $0 != plan.durationMinutes
            }
            preferences.previousDurations = Array(preferences.previousDurations.prefix(3))
        }
        lastObservedNow = max(lastObservedNow, now)
        stopReason = nil
        finishedAt = nil
        stoppedAt = nil
        revision &+= 1
        return true
    }

    /// Returns true if the call stopped the session. Normal countdown changes need no mutation notice.
    @discardableResult
    public mutating func advance(now: TimeInterval, battery: BatteryReading, wallNow: Date = Date()) -> Bool {
        let batteryBlock = Self.batteryBlock(battery)
        let clockValid = now.isFinite && now >= 0
        guard active else {
            // A ready plan may be waiting for native assertion acquisition. Invalidate it
            // if new evidence means starting it would no longer satisfy the safeguards.
            if batteryBlock != nil || !clockValid { revision &+= 1 }
            return false
        }
        guard clockValid else { return stop(reason: .clockUnavailable, at: wallNow) }
        lastObservedNow = max(lastObservedNow, now)
        if remaining(at: now) == 0 {
            // Preserve the deadline's instant even if the run loop delivers this callback late.
            let completion = wallNow.addingTimeInterval(deadline - now)
            return stop(reason: .expired, at: completion)
        }
        if let reason = batteryBlock {
            return stop(reason: reason == .lowBattery ? .lowBattery : .batteryUnavailable, at: wallNow)
        }
        return false
    }

    @discardableResult
    public mutating func stop(reason: SessionStopReason = .manual, at date: Date? = nil) -> Bool {
        guard active else { return false }
        active = false
        totalDurationSeconds = 0
        deadline = 0
        stopReason = reason
        finishedAt = reason == .expired ? date : nil
        stoppedAt = date
        revision &+= 1
        return true
    }

    private static func batteryBlock(_ battery: BatteryReading) -> StartBlockReason? {
        guard battery.hasBattery else { return nil }
        guard let percent = battery.validPercent else { return .batteryUnavailable }
        return percent < minimumBatteryPercent ? .lowBattery : nil
    }

    public static func forecastWarning(battery: BatteryReading, seconds: TimeInterval) -> ForecastWarning? {
        guard battery.hasBattery, !battery.onAC else { return nil }
        guard let percent = battery.validPercent,
              let runtime = battery.validMinutesToEmpty else { return nil }
        let projected = max(0, percent * (1 - seconds / (runtime * 60 * forecastRuntimeAllowance)))
        return projected < minimumBatteryPercent ? .estimatedBelowMinimum(projectedPercent: projected) : nil
    }
}
