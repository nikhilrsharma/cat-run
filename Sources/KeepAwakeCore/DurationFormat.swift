import Foundation

/// One display convention for timer values; seconds are rounded up to the next minute.
public enum DurationFormat {
    public static func minutes(seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(ceil(seconds / 60), SessionModel.maximumSessionSeconds / 60))
    }

    public static func string(minutes: Int) -> String {
        let minutes = max(0, min(minutes, Int(SessionModel.maximumSessionSeconds / 60)))
        guard minutes >= 60 else { return String(format: "%02dm", minutes) }
        return String(format: "%02dh %02dm", minutes / 60, minutes % 60)
    }

    public static func string(seconds: TimeInterval) -> String {
        string(minutes: minutes(seconds: seconds))
    }
}
