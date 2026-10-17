import Foundation

/// Separates a usable charge reading from a runtime estimate that is still settling.
/// The estimate is advisory: it must never replace the actual charge cutoff.
public struct BatteryForecastTracker {
    /// Observe more than one snapshot after launch, wake, or a power-source change.
    public static let settlingSeconds: TimeInterval = 30
    /// An old observation cannot validate a newly returned operating-system estimate.
    public static let maximumSampleGapSeconds: TimeInterval = 120

    private var candidateSince: TimeInterval?
    private var previousTime: TimeInterval?
    private var previousRuntime: Double?

    public init() {}

    /// Call on system wake even if the power source did not change during sleep.
    public mutating func reset() {
        candidateSince = nil
        previousTime = nil
        previousRuntime = nil
    }

    /// `now` must use a monotonic clock. Charge remains available immediately;
    /// runtime is returned only from the current snapshot after stable observations.
    public mutating func observe(_ reading: BatteryReading, at now: TimeInterval) -> BatteryReading {
        guard reading.hasBattery, !reading.onAC, reading.validPercent != nil,
              let runtime = reading.validMinutesToEmpty, now.isFinite, now >= 0 else {
            reset()
            return withoutForecast(reading)
        }

        guard let previousTime, let previousRuntime, let candidateSince,
              now >= previousTime,
              now - previousTime <= Self.maximumSampleGapSeconds else {
            beginCandidate(runtime: runtime, at: now)
            return withoutForecast(reading)
        }

        let elapsed = now - previousTime
        // Runtime can fluctuate with load. Large changes need another settling
        // period; neither old nor newly unstable values are presented as a forecast.
        let expectedRuntime = max(0, previousRuntime - elapsed / 60)
        let tolerance = max(5, previousRuntime * 0.25)
        guard abs(runtime - expectedRuntime) <= tolerance else {
            beginCandidate(runtime: runtime, at: now)
            return withoutForecast(reading)
        }

        self.previousTime = now
        self.previousRuntime = runtime
        guard now - candidateSince >= Self.settlingSeconds else {
            return withoutForecast(reading)
        }
        return BatteryReading(hasBattery: reading.hasBattery, percent: reading.percent,
                              onAC: reading.onAC, minutesToEmpty: runtime)
    }

    private mutating func beginCandidate(runtime: Double, at now: TimeInterval) {
        candidateSince = now
        previousTime = now
        previousRuntime = runtime
    }

    private func withoutForecast(_ reading: BatteryReading) -> BatteryReading {
        BatteryReading(hasBattery: reading.hasBattery, percent: reading.percent,
                       onAC: reading.onAC, minutesToEmpty: nil)
    }
}
