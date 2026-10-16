import Foundation

public enum SessionNotice {
    /// The stored instant stays fixed; its presentation follows the Mac's current region and timezone.
    public static func message(
        for reason: SessionStopReason?,
        finishedAt: Date?,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard let reason else { return "" }
        guard reason == .expired, let finishedAt else { return reason.message }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMyyyyjmmz")
        return "Timer finished at \(formatter.string(from: finishedAt))."
    }
}
