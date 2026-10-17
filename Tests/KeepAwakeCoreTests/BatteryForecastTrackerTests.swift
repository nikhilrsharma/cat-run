import XCTest
@testable import KeepAwakeCore

final class BatteryForecastTrackerTests: XCTestCase {
    private func battery(_ runtime: Double? = 300, percent: Double? = 90, onAC: Bool = false) -> BatteryReading {
        BatteryReading(hasBattery: true, percent: percent, onAC: onAC, minutesToEmpty: runtime)
    }

    func testFirstSamplePreservesChargeButDoesNotTrustRuntime() {
        var tracker = BatteryForecastTracker()
        let reading = tracker.observe(battery(), at: 100)
        XCTAssertEqual(reading.validPercent, 90)
        XCTAssertTrue(reading.hasBattery)
        XCTAssertFalse(reading.onAC)
        XCTAssertNil(reading.minutesToEmpty)
    }

    func testRuntimeRequiresThirtySecondsOfStableObservations() {
        var tracker = BatteryForecastTracker()
        XCTAssertNil(tracker.observe(battery(), at: 100).minutesToEmpty)
        XCTAssertNil(tracker.observe(battery(), at: 129).minutesToEmpty)
        XCTAssertEqual(tracker.observe(battery(299), at: 130).minutesToEmpty, 299)
        XCTAssertEqual(tracker.observe(battery(298), at: 160).minutesToEmpty, 298)
    }

    func testRepeatedSynchronousRefreshCannotSkipSettling() {
        var tracker = BatteryForecastTracker()
        for _ in 0..<100 {
            XCTAssertNil(tracker.observe(battery(), at: 100).minutesToEmpty)
        }
        XCTAssertEqual(tracker.observe(battery(), at: 130).minutesToEmpty, 300)
    }

    func testNinetyPercentAfterUnplugWithoutRuntimeRemainsUsableButUnknown() {
        var tracker = BatteryForecastTracker()
        _ = tracker.observe(battery(300, onAC: true), at: 100)
        for now in [110.0, 140, 170, 200] {
            let reading = tracker.observe(battery(nil), at: now)
            XCTAssertEqual(reading.validPercent, 90)
            XCTAssertNil(reading.validMinutesToEmpty)
            XCTAssertNil(SessionModel.forecastWarning(battery: reading, seconds: 15 * 60))
            guard case .ready = SessionModel().prepareStart(durationMinutes: 15, battery: reading, now: now) else {
                return XCTFail("A missing estimate must not present a battery-risk confirmation")
            }
        }
    }

    func testWakeDiscardsThePreviousForecastEvenOnTheSamePowerSource() {
        var tracker = BatteryForecastTracker()
        _ = tracker.observe(battery(), at: 100)
        XCTAssertEqual(tracker.observe(battery(), at: 130).minutesToEmpty, 300)
        tracker.reset()
        XCTAssertNil(tracker.observe(battery(10), at: 140).minutesToEmpty)
        XCTAssertNil(tracker.observe(battery(10), at: 169).minutesToEmpty)
        XCTAssertEqual(tracker.observe(battery(10), at: 170).minutesToEmpty, 10)
    }

    func testReplugAndUnplugCannotReuseEarlierBatteryRuntime() {
        var tracker = BatteryForecastTracker()
        _ = tracker.observe(battery(), at: 100)
        XCTAssertEqual(tracker.observe(battery(), at: 130).minutesToEmpty, 300)
        let pluggedIn = tracker.observe(battery(300, onAC: true), at: 135)
        XCTAssertNil(pluggedIn.minutesToEmpty)
        XCTAssertTrue(pluggedIn.onAC)
        XCTAssertEqual(pluggedIn.validPercent, 90)
        XCTAssertNil(tracker.observe(battery(20), at: 140).minutesToEmpty)
        XCTAssertEqual(tracker.observe(battery(20), at: 170).minutesToEmpty, 20)
    }

    func testMissingRuntimeNeverReturnsTheLastKnownRuntime() {
        var tracker = BatteryForecastTracker()
        _ = tracker.observe(battery(), at: 100)
        XCTAssertEqual(tracker.observe(battery(), at: 130).minutesToEmpty, 300)
        XCTAssertNil(tracker.observe(battery(nil), at: 131).minutesToEmpty)
        XCTAssertNil(tracker.observe(battery(), at: 132).minutesToEmpty)
        XCTAssertEqual(tracker.observe(battery(), at: 162).minutesToEmpty, 300)
    }

    func testInvalidRuntimeSentinelsRemainUnknown() {
        for runtime in [nil, -1, -2, 0, Double.nan, Double.infinity, -Double.infinity] as [Double?] {
            var tracker = BatteryForecastTracker()
            _ = tracker.observe(battery(), at: 100)
            _ = tracker.observe(battery(), at: 130)
            let reading = tracker.observe(battery(runtime), at: 140)
            XCTAssertEqual(reading.validPercent, 90)
            XCTAssertNil(reading.minutesToEmpty)
            XCTAssertNil(SessionModel.forecastWarning(battery: reading, seconds: 15 * 60))
            XCTAssertNil(tracker.observe(battery(), at: 141).minutesToEmpty)
        }
    }

    func testInvalidChargeCannotValidateAUsableForecast() {
        for percent in [nil, -1, 101, Double.nan, Double.infinity] as [Double?] {
            var tracker = BatteryForecastTracker()
            _ = tracker.observe(battery(), at: 100)
            _ = tracker.observe(battery(), at: 130)
            let reading = tracker.observe(battery(300, percent: percent), at: 140)
            XCTAssertNil(reading.validPercent)
            XCTAssertNil(reading.minutesToEmpty)
            XCTAssertEqual(SessionModel().prepareStart(durationMinutes: 15, battery: reading, now: 140),
                           .blocked(.batteryUnavailable))
            XCTAssertNil(tracker.observe(battery(), at: 141).minutesToEmpty)
        }
    }

    func testSettlingNeverHidesTheActualLowBatteryCutoffOnACOrBattery() {
        for onAC in [false, true] {
            var tracker = BatteryForecastTracker()
            let low = tracker.observe(battery(300, percent: 14, onAC: onAC), at: 100)
            XCTAssertEqual(low.validPercent, 14)
            XCTAssertEqual(SessionModel().prepareStart(durationMinutes: 15, battery: low, now: 100),
                           .blocked(.lowBattery))
            let boundary = tracker.observe(battery(nil, percent: 15, onAC: onAC), at: 101)
            guard case .ready = SessionModel().prepareStart(durationMinutes: 15, battery: boundary, now: 101) else {
                return XCTFail("Exactly 15% with an unknown forecast is allowed")
            }
        }
    }

    func testLongGapsAndClockRegressionRequireNewSettling() {
        for next in [99.0, 251] {
            var tracker = BatteryForecastTracker()
            _ = tracker.observe(battery(), at: 100)
            _ = tracker.observe(battery(), at: 130)
            XCTAssertNil(tracker.observe(battery(), at: next).minutesToEmpty)
            XCTAssertEqual(tracker.observe(battery(), at: next + 30).minutesToEmpty, 300)
        }
    }

    func testInvalidClockNeverProducesAForecast() {
        for now in [-1, Double.nan, Double.infinity, -Double.infinity] {
            var tracker = BatteryForecastTracker()
            _ = tracker.observe(battery(), at: 100)
            _ = tracker.observe(battery(), at: 130)
            let reading = tracker.observe(battery(), at: now)
            XCTAssertEqual(reading.validPercent, 90)
            XCTAssertNil(reading.minutesToEmpty)
            XCTAssertNil(tracker.observe(battery(), at: 140).minutesToEmpty)
        }
    }

    func testLargeRuntimeChangesRequireAnotherStablePeriod() {
        for changedRuntime in [10.0, 1_000] {
            var tracker = BatteryForecastTracker()
            _ = tracker.observe(battery(), at: 100)
            _ = tracker.observe(battery(), at: 130)
            XCTAssertNil(tracker.observe(battery(changedRuntime), at: 140).minutesToEmpty)
            XCTAssertNil(tracker.observe(battery(changedRuntime), at: 169).minutesToEmpty)
            XCTAssertEqual(tracker.observe(battery(changedRuntime), at: 170).minutesToEmpty, changedRuntime)
        }
    }

    func testReliableLowProjectionStillWarns() {
        var tracker = BatteryForecastTracker()
        _ = tracker.observe(battery(100, percent: 30), at: 100)
        let reading = tracker.observe(battery(100, percent: 30), at: 130)
        guard case .estimatedBelowMinimum(let projected)? = SessionModel.forecastWarning(battery: reading, seconds: 60 * 60) else {
            return XCTFail("A stable low projection must still warn")
        }
        XCTAssertEqual(projected, 10, accuracy: 0.001)
    }

    func testDesktopRequiresNeitherChargeNorRuntime() {
        var tracker = BatteryForecastTracker()
        _ = tracker.observe(battery(), at: 100)
        let desktop = BatteryReading(hasBattery: false, percent: nil, onAC: true, minutesToEmpty: 300)
        let reading = tracker.observe(desktop, at: 130)
        XCTAssertFalse(reading.hasBattery)
        XCTAssertNil(reading.minutesToEmpty)
        guard case .ready = SessionModel().prepareStart(durationMinutes: 360, battery: reading, now: 130) else {
            return XCTFail("Desktop start must not depend on a battery")
        }
        XCTAssertNil(tracker.observe(battery(), at: 140).minutesToEmpty)
    }
}
