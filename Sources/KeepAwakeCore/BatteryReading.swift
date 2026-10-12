import Foundation

public struct BatteryReading: Equatable {
    public let hasBattery: Bool
    public let percent: Double?
    public let onAC: Bool
    public let minutesToEmpty: Double?

    public init(hasBattery: Bool, percent: Double?, onAC: Bool, minutesToEmpty: Double? = nil) {
        self.hasBattery = hasBattery
        self.percent = percent
        self.onAC = onAC
        self.minutesToEmpty = minutesToEmpty
    }

    /// Invalid readings are treated as unavailable, never as evidence that protection is safe.
    public var validPercent: Double? {
        guard let percent, percent.isFinite, (0...100).contains(percent) else { return nil }
        return percent
    }

    public var validMinutesToEmpty: Double? {
        guard let minutesToEmpty, minutesToEmpty.isFinite, minutesToEmpty > 0 else { return nil }
        return minutesToEmpty
    }
}
