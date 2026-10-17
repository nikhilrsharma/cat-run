import Foundation

public enum SessionNotice {
    public static func message(for record: SessionRecord?, locale: Locale = .autoupdatingCurrent,
                               timeZone: TimeZone = .autoupdatingCurrent) -> String {
        guard let record, record.state == .finished, let raw = record.reason else { return "" }
        guard let reason = SessionStopReason(rawValue: raw) else { return "Previous timer status unavailable." }
        guard let date = record.endedAt else { return reason.message }
        let title: String
        switch reason {
        case .expired: return message(for: reason, finishedAt: date, locale: locale, timeZone: timeZone)
        case .manual: title = "Timer stopped"
        case .lowBattery: title = "Stopped: battery below 15%"
        case .batteryUnavailable: title = "Stopped: battery reading unavailable"
        case .clockUnavailable: title = "Stopped: timer clock unavailable"
        case .assertionFailure: title = "Stopped: keep-awake request failed"
        case .systemSleep: title = "Stopped for sleep"
        case .quit: title = "Stopped when Cat Run quit"
        case .unresponsive: title = "Stopped: app was unresponsive"
        case .sessionInactive: title = "Stopped for user switch"
        case .shutdown: title = "Stopped for logout or shutdown"
        case .storageFailure: title = "Stopped: session could not be saved"
        case .interrupted: return reason.message
        }
        return "\(title).\n\(formatted(date, locale: locale, timeZone: timeZone))"
    }
    /// The stored instant stays fixed; its presentation follows the Mac's current region and timezone.
    public static func message(
        for reason: SessionStopReason?,
        finishedAt: Date?,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard let reason else { return "" }
        guard reason == .expired, let finishedAt else { return reason.message }
        return "Timer finished at \(formatted(finishedAt, locale: locale, timeZone: timeZone))."
    }

    private static func formatted(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMyyyyjmmz")
        return formatter.string(from: date)
    }
}
