import Foundation

/// A user-requested plain-text export of the verified, retained snapshot.
/// No identifiers or storage metadata are included, and recording order is kept.
public enum AuditLogText {
    public static func string(events: [AuditEvent], locale: Locale = .current,
                              timeZone: TimeZone = .current) -> String {
        guard !events.isEmpty else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let day = DateFormatter()
        day.locale = locale; day.timeZone = timeZone
        day.dateStyle = .medium; day.timeStyle = .none
        let time = DateFormatter()
        time.locale = locale; time.timeZone = timeZone
        time.dateFormat = "HH:mm:ss z"
        var lines = ["Cat Run activity"]
        var previousDay: Date?
        for event in events {
            let currentDay = calendar.startOfDay(for: event.date)
            if currentDay != previousDay {
                lines.append("")
                lines.append(day.string(from: event.date))
                previousDay = currentDay
            }
            lines.append("\(time.string(from: event.date))  \(event.message)")
        }
        return lines.joined(separator: "\n")
    }
}
