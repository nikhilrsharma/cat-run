import Foundation

public enum SessionStopReason: String, Codable, Equatable {
    case manual, expired, lowBattery, batteryUnavailable, clockUnavailable, assertionFailure, systemSleep, quit

    public var message: String {
        switch self {
        case .manual: return "Timer stopped."
        case .expired: return "Timer finished."
        case .lowBattery: return "Stopped: battery below 15%. Charge to at least 15% before starting again."
        case .batteryUnavailable: return "Stopped: battery protection could not be verified."
        case .clockUnavailable: return "Stopped: the timer clock could not be verified. You can try again."
        case .assertionFailure: return "Stopped: the keep-awake request failed. You can try again."
        case .systemSleep: return "Stopped when your Mac went to sleep. Start a new timer when ready."
        case .quit: return "Timer stopped when Cat Run quit."
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
    case estimateUnavailable

    public var message: String {
        switch self {
        case .estimatedBelowMinimum(let percent):
            return "Battery may fall below 15% during this timer (approximately \(Int(floor(percent)))% remaining at the end). The timer will stop if actual charge falls below 15%, even while plugged in."
        case .estimateUnavailable:
            return "Battery charge at the end cannot currently be estimated. The timer will stop if actual charge falls below 15%, even while plugged in."
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

/// Pure session state. Callers supply a continuous monotonic clock that includes system sleep.
public struct SessionModel {
    public static let minimumBatteryPercent = 15.0
    public static let maximumSessionSeconds: TimeInterval = 6 * 60 * 60
    /// Account for changes in load instead of treating the operating-system estimate as exact.
    public static let forecastRuntimeAllowance = 0.9

    public private(set) var preferences: Preferences
    public private(set) var active = false
    public private(set) var stopReason: SessionStopReason?
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
        revision &+= 1
        return true
    }

    /// Returns true if the call stopped the session. Normal countdown changes need no mutation notice.
    @discardableResult
    public mutating func advance(now: TimeInterval, battery: BatteryReading) -> Bool {
        let batteryBlock = Self.batteryBlock(battery)
        let clockValid = now.isFinite && now >= 0
        guard active else {
            // A ready plan may be waiting for native assertion acquisition. Invalidate it
            // if new evidence means starting it would no longer satisfy the safeguards.
            if batteryBlock != nil || !clockValid { revision &+= 1 }
            return false
        }
        if let reason = batteryBlock {
            return stop(reason: reason == .lowBattery ? .lowBattery : .batteryUnavailable)
        }
        guard clockValid else { return stop(reason: .clockUnavailable) }
        lastObservedNow = max(lastObservedNow, now)
        if remaining(at: now) == 0 { return stop(reason: .expired) }
        return false
    }

    @discardableResult
    public mutating func stop(reason: SessionStopReason = .manual) -> Bool {
        guard active else { return false }
        active = false
        totalDurationSeconds = 0
        deadline = 0
        stopReason = reason
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
              let runtime = battery.validMinutesToEmpty else { return .estimateUnavailable }
        let projected = max(0, percent * (1 - seconds / (runtime * 60 * forecastRuntimeAllowance)))
        return projected < minimumBatteryPercent ? .estimatedBelowMinimum(projectedPercent: projected) : nil
    }
}
