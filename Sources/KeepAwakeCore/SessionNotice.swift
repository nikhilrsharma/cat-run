import Foundation

public enum SessionNotice {
    public static func message(for record: SessionRecord?, locale: Locale = .autoupdatingCurrent,
                               timeZone: TimeZone = .autoupdatingCurrent) -> String {
        guard let record, record.state == .finished, let raw = record.reason else { return "" }
        guard let reason = SessionStopReason(rawValue: raw) else {
            let title = "Timer stopped · Reason unavailable"
            guard let date = record.endedAt else { return "\(title)\nStop time unknown." }
            return "\(title)\n\(formatted(date, locale: locale, timeZone: timeZone))"
        }
        if reason != .interrupted, record.endedAt == nil, let detectedAt = record.detectedAt {
            return "\(reason.message)\nDetected: \(formatted(detectedAt, locale: locale, timeZone: timeZone))"
        }
        return message(for: reason, finishedAt: record.endedAt, locale: locale, timeZone: timeZone)
    }

    /// A known stop instant stays fixed; presentation follows the Mac's current region and timezone.
    /// An unexpected interruption has no trustworthy stop instant, even if a caller supplies one.
    public static func message(
        for reason: SessionStopReason?,
        finishedAt: Date?,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard let reason else { return "" }
        guard reason != .interrupted, let finishedAt else { return reason.message }
        return "\(reason.message)\n\(formatted(finishedAt, locale: locale, timeZone: timeZone))"
    }

    private static func formatted(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMyyyyjmmz")
        return formatter.string(from: date)
    }
}
