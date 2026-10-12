import Foundation
import XCTest
@testable import KeepAwakeCore

final class SessionModelTests: XCTestCase {
    private let desktop = BatteryReading(hasBattery: false, percent: nil, onAC: true)
    private let charged = BatteryReading(hasBattery: true, percent: 80, onAC: false, minutesToEmpty: 600)

    private func ready(
        _ preparation: SessionPreparation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SessionPlan {
        guard case .ready(let plan) = preparation else {
            XCTFail("Expected ready, got \(preparation)", file: file, line: line)
            throw TestError.notReady
        }
        return plan
    }

    private func start(
        _ model: inout SessionModel,
        minutes: Int = 60,
        now: TimeInterval = 100,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let plan = try ready(model.prepareStart(durationMinutes: minutes, battery: desktop, now: now), file: file, line: line)
        XCTAssertTrue(model.commit(plan, now: now), file: file, line: line)
    }

    private enum TestError: Error { case notReady }

    func testAllTwentyFourDurationsAndInvalidValues() throws {
        XCTAssertEqual(Preferences.allowedDurations.count, 24)
        for duration in stride(from: 15, through: 360, by: 15) {
            var model = SessionModel()
            try start(&model, minutes: duration)
            XCTAssertEqual(model.remaining(at: 100), TimeInterval(duration * 60))
            XCTAssertEqual(model.totalDurationSeconds, TimeInterval(duration * 60))
            XCTAssertEqual(model.activeDurationMinutes, duration)
        }
        let model = SessionModel()
        for invalid in [Int.min, -15, 0, 1, 14, 16, 359, 361, 375, Int.max] {
            XCTAssertEqual(model.prepareStart(durationMinutes: invalid, battery: desktop, now: 100), .blocked(.invalidDuration))
        }
    }

    func testPreferencesSanitizeAndPersistOnlyChoices() throws {
        let prefs = Preferences(durationMinutes: 17, keepScreenAwake: false, previousDurations: [60, 60, -1, 16, 90, 360, 15])
        XCTAssertEqual(prefs.durationMinutes, 15)
        XCTAssertEqual(prefs.previousDurations, [60, 90, 360])
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded, prefs)
        let corruptValues = Data(#"{"durationMinutes":"forever","keepScreenAwake":null,"previousDurations":[1,"bad"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: corruptValues), Preferences())
        let missingValues = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(missingValues, Preferences())
    }

    func testMutatedPreferencesAreSanitizedAtModelBoundaryAndEncoding() throws {
        var prefs = Preferences()
        prefs.durationMinutes = 721
        prefs.previousDurations = [0, 45, 45, 360, 15, 30]
        let model = SessionModel(preferences: prefs)
        XCTAssertEqual(model.preferences.durationMinutes, 15)
        XCTAssertEqual(model.preferences.previousDurations, [45, 360, 15])
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded, model.preferences)
    }

    func testPreparationAndFailedAssertionAcquisitionDoNotChangeHistory() throws {
        let prefs = Preferences(previousDurations: [90, 45, 180])
        var model = SessionModel(preferences: prefs)
        let plan = try ready(model.prepareStart(durationMinutes: 60, battery: desktop, now: 100))
        // Native assertion acquisition fails: deliberately do not commit its prepared plan.
        XCTAssertFalse(model.active)
        XCTAssertEqual(model.preferences, prefs)
        XCTAssertNil(model.stopReason)
        XCTAssertTrue(model.commit(plan, now: 110))
        XCTAssertEqual(model.remaining(at: 110), 3_600)
        XCTAssertEqual(model.preferences.previousDurations, [60, 90, 45])
    }

    func testHistoryIsDistinctMostRecentFirstAndOnlyThree() throws {
        var model = SessionModel()
        for (index, minutes) in [60, 90, 45, 120, 90].enumerated() {
            try start(&model, minutes: minutes, now: Double(index * 10 + 100))
            XCTAssertTrue(model.stop())
        }
        XCTAssertEqual(model.preferences.previousDurations, [90, 120, 45])
        XCTAssertEqual(model.preferences.durationMinutes, 90)
    }

    func testRelaunchRestoresChoicesButNeverAnActiveSession() throws {
        var original = SessionModel(preferences: Preferences(keepScreenAwake: false))
        try start(&original, minutes: 90)
        let restored = SessionModel(preferences: original.preferences)
        XCTAssertFalse(restored.active)
        XCTAssertNil(restored.activeDurationMinutes)
        XCTAssertNil(restored.stopReason)
        XCTAssertEqual(restored.remaining(at: 150), 0)
        XCTAssertEqual(restored.preferences.previousDurations, [90])
        XCTAssertFalse(restored.keepScreenAwake)
    }

    func testSettingsLockDuringAnActiveScreenOffSession() throws {
        var model = SessionModel(preferences: Preferences(durationMinutes: 60, keepScreenAwake: false))
        try start(&model)
        XCTAssertFalse(model.advance(now: 1_000, battery: charged))
        XCTAssertEqual(model.remaining(at: 1_000), 2_700)
        XCTAssertFalse(model.setKeepScreenAwake(true))
        XCTAssertFalse(model.setDurationMinutes(90))
        XCTAssertFalse(model.keepScreenAwake)
        XCTAssertEqual(model.preferences.durationMinutes, 60)
        XCTAssertEqual(model.prepareStart(durationMinutes: 90, battery: desktop, now: 1_000), .blocked(.alreadyActive))
        XCTAssertTrue(model.stop())
        XCTAssertTrue(model.setKeepScreenAwake(true))
        XCTAssertTrue(model.setDurationMinutes(90))
        XCTAssertFalse(model.setDurationMinutes(16))
    }

    func testActualBatteryCutoffIsStrictlyBelowFifteenOnBatteryAndAC() throws {
        for onAC in [false, true] {
            var model = SessionModel()
            let low = BatteryReading(hasBattery: true, percent: 14.999, onAC: onAC, minutesToEmpty: 600)
            XCTAssertEqual(model.prepareStart(durationMinutes: 15, battery: low, now: 100, confirmRisk: true), .blocked(.lowBattery))
            let boundary = BatteryReading(hasBattery: true, percent: 15, onAC: onAC, minutesToEmpty: 600)
            let plan = try ready(model.prepareStart(durationMinutes: 15, battery: boundary, now: 100, confirmRisk: true))
            XCTAssertTrue(model.commit(plan, now: 100))
            XCTAssertFalse(model.advance(now: 101, battery: boundary))
            XCTAssertTrue(model.active)
            XCTAssertTrue(model.advance(now: 102, battery: low))
            XCTAssertEqual(model.stopReason, .lowBattery)
            XCTAssertFalse(model.active)
        }
    }

    func testUnknownAndInvalidInternalBatteryReadingsBlockAndStopEvenOnAC() throws {
        for percent in [nil, Double.nan, Double.infinity, -1, 101] as [Double?] {
            for onAC in [false, true] {
                var model = SessionModel()
                let invalid = BatteryReading(hasBattery: true, percent: percent, onAC: onAC)
                XCTAssertEqual(model.prepareStart(durationMinutes: 15, battery: invalid, now: 100, confirmRisk: true), .blocked(.batteryUnavailable))
                try start(&model)
                XCTAssertTrue(model.advance(now: 101, battery: invalid))
                XCTAssertEqual(model.stopReason, .batteryUnavailable)
            }
        }
    }

    func testDesktopDoesNotRequireBatteryReadingsOrForecast() throws {
        var model = SessionModel()
        let plan = try ready(model.prepareStart(durationMinutes: 360, battery: desktop, now: 100))
        XCTAssertTrue(model.commit(plan, now: 100))
        XCTAssertFalse(model.advance(now: 200, battery: desktop))
        XCTAssertTrue(model.active)
    }

    func testRiskRequiresConfirmationAndFreshBatteryStillBlocks() throws {
        var model = SessionModel(preferences: Preferences(previousDurations: [90]))
        let risk = BatteryReading(hasBattery: true, percent: 30, onAC: false, minutesToEmpty: 100)
        guard case .warning(let unconfirmedPlan, .estimatedBelowMinimum(let percent)) = model.prepareStart(durationMinutes: 60, battery: risk, now: 100) else {
            return XCTFail("Expected a low projected battery warning")
        }
        XCTAssertLessThan(percent, 15)
        XCTAssertFalse(model.commit(unconfirmedPlan, now: 100))
        XCTAssertEqual(model.preferences.previousDurations, [90])
        let low = BatteryReading(hasBattery: true, percent: 14, onAC: true)
        XCTAssertEqual(model.prepareStart(durationMinutes: 60, battery: low, now: 110, confirmRisk: true), .blocked(.lowBattery))
        let plan = try ready(model.prepareStart(durationMinutes: 60, battery: risk, now: 110, confirmRisk: true))
        XCTAssertTrue(model.commit(plan, now: 111))
        XCTAssertEqual(model.remaining(at: 111), 3_600)
    }

    func testUnknownForecastCanBeConfirmedButActualProtectionRemains() throws {
        for runtime in [nil, 0, -1, Double.nan, Double.infinity] as [Double?] {
            var model = SessionModel()
            let noForecast = BatteryReading(hasBattery: true, percent: 75, onAC: false, minutesToEmpty: runtime)
            guard case .warning(_, .estimateUnavailable) = model.prepareStart(durationMinutes: 30, battery: noForecast, now: 100) else {
                return XCTFail("Expected unavailable forecast warning")
            }
            let plan = try ready(model.prepareStart(durationMinutes: 30, battery: noForecast, now: 100, confirmRisk: true))
            XCTAssertTrue(model.commit(plan, now: 100))
            XCTAssertTrue(model.advance(now: 200, battery: BatteryReading(hasBattery: true, percent: 14, onAC: true)))
        }
    }

    func testForecastBoundaryConservativeAllowanceAndACSuppression() {
        // The allowance leaves 90 usable minutes. 45 minutes consumes half of 30%.
        let reading = BatteryReading(hasBattery: true, percent: 30, onAC: false, minutesToEmpty: 100)
        XCTAssertNil(SessionModel.forecastWarning(battery: reading, seconds: 2_700))
        guard case .estimatedBelowMinimum(let percent)? = SessionModel.forecastWarning(battery: reading, seconds: 2_701) else {
            return XCTFail("Expected warning just below 15%")
        }
        XCTAssertLessThan(percent, 15)
        let pluggedIn = BatteryReading(hasBattery: true, percent: 20, onAC: true)
        XCTAssertNil(SessionModel.forecastWarning(battery: pluggedIn, seconds: 21_600))
    }

    func testNaturalExpirationAndRepeatedStopAreIdempotent() throws {
        var model = SessionModel()
        try start(&model, minutes: 15)
        XCTAssertEqual(model.remaining(at: 999), 1)
        XCTAssertFalse(model.advance(now: 999, battery: desktop))
        XCTAssertTrue(model.advance(now: 1_000, battery: desktop))
        XCTAssertEqual(model.stopReason, .expired)
        XCTAssertFalse(model.stop(reason: .manual))
        XCTAssertFalse(model.advance(now: 2_000, battery: desktop))
        XCTAssertEqual(model.stopReason, .expired)
        XCTAssertEqual(model.remaining(at: 1_001), 0)
    }

    func testContinuousClockAndObservedTimeDoNotRunBackward() throws {
        var model = SessionModel()
        try start(&model)
        XCTAssertFalse(model.advance(now: 1_000, battery: desktop))
        XCTAssertEqual(model.remaining(at: 1_000), 2_700)
        XCTAssertEqual(model.remaining(at: 900), 2_700)
        XCTAssertEqual(model.remaining(at: .nan), 2_700)
        XCTAssertFalse(model.advance(now: 900, battery: desktop))
        XCTAssertEqual(model.remaining(at: 900), 2_700)
        // A continuous-clock jump after sleep counts toward the original duration.
        XCTAssertTrue(model.advance(now: 4_000, battery: desktop))
        XCTAssertEqual(model.stopReason, .expired)
    }

    func testSystemSleepStopsAndNeverAutomaticallyResumes() throws {
        var model = SessionModel()
        try start(&model)
        XCTAssertTrue(model.stop(reason: .systemSleep))
        XCTAssertFalse(model.advance(now: 200, battery: desktop))
        XCTAssertFalse(model.active)
        XCTAssertEqual(model.stopReason, .systemSleep)
        XCTAssertFalse(model.stopReason!.message.isEmpty)
    }

    func testExtensionPreservesDeadlineAndDoesNotCountAcquisitionDelay() throws {
        var model = SessionModel()
        try start(&model)
        let plan = try ready(model.prepareExtension(battery: desktop, now: 1_000))
        XCTAssertTrue(plan.isExtension)
        XCTAssertEqual(plan.durationMinutes, 75)
        XCTAssertEqual(plan.timeoutSeconds, 3_600)
        XCTAssertTrue(model.commit(plan, now: 1_010))
        XCTAssertEqual(model.totalDurationSeconds, 4_500)
        XCTAssertEqual(model.remaining(at: 1_010), 3_590)
        XCTAssertEqual(model.preferences.previousDurations, [60])
    }

    func testSixHourTotalCannotBeExtendedEvenAfterTimeElapses() throws {
        var model = SessionModel()
        try start(&model, minutes: 345)
        let last = try ready(model.prepareExtension(battery: desktop, now: 200))
        XCTAssertTrue(model.commit(last, now: 200))
        XCTAssertEqual(model.activeDurationMinutes, 360)
        XCTAssertFalse(model.advance(now: 3_700, battery: desktop))
        XCTAssertEqual(model.prepareExtension(battery: desktop, now: 3_700), .blocked(.sixHourLimit))
        XCTAssertEqual(model.totalDurationSeconds, 21_600)
    }

    func testExtensionForecastIncludesAllRemainingTimeAndDoesNotMutateOnWarning() throws {
        var model = SessionModel()
        try start(&model)
        let risk = BatteryReading(hasBattery: true, percent: 30, onAC: false, minutesToEmpty: 100)
        guard case .warning(let plan, _) = model.prepareExtension(battery: risk, now: 1_000) else {
            return XCTFail("Expected warning for the proposed 60-minute remainder")
        }
        XCTAssertEqual(plan.timeoutSeconds, 3_600)
        XCTAssertEqual(model.totalDurationSeconds, 3_600)
        XCTAssertEqual(model.remaining(at: 1_000), 2_700)
        XCTAssertFalse(model.commit(plan, now: 1_000))
        let confirmed = try ready(model.prepareExtension(battery: risk, now: 1_010, confirmRisk: true))
        XCTAssertTrue(model.commit(confirmed, now: 1_010))
        XCTAssertEqual(model.totalDurationSeconds, 4_500)
    }

    func testExpiredOrStoppedSessionCannotBeExtended() throws {
        var model = SessionModel()
        XCTAssertEqual(model.prepareExtension(battery: desktop, now: 100), .blocked(.notActive))
        try start(&model, minutes: 15)
        let plan = try ready(model.prepareExtension(battery: desktop, now: 999))
        XCTAssertFalse(model.commit(plan, now: 1_000))
        XCTAssertEqual(model.prepareExtension(battery: desktop, now: 1_000), .blocked(.notActive))
        XCTAssertTrue(model.stop())
        XCTAssertFalse(model.commit(plan, now: 1_001))
    }

    func testStaleForeignAndDoubleCommitsAreRejected() throws {
        var model = SessionModel()
        let beforeEdit = try ready(model.prepareStart(durationMinutes: 60, battery: desktop, now: 100))
        XCTAssertTrue(model.setKeepScreenAwake(false))
        XCTAssertFalse(model.commit(beforeEdit, now: 101))
        let valid = try ready(model.prepareStart(durationMinutes: 60, battery: desktop, now: 101))
        var other = SessionModel()
        XCTAssertFalse(other.commit(valid, now: 101))
        XCTAssertTrue(model.commit(valid, now: 101))
        XCTAssertFalse(model.commit(valid, now: 101))
        XCTAssertEqual(model.preferences.previousDurations, [60])
    }

    func testInvalidClockDoesNotPrepareOrCommit() throws {
        var model = SessionModel()
        for now in [-1, Double.nan, Double.infinity] {
            XCTAssertEqual(model.prepareStart(durationMinutes: 60, battery: desktop, now: now), .blocked(.invalidClock))
        }
        let plan = try ready(model.prepareStart(durationMinutes: 60, battery: desktop, now: 100))
        XCTAssertFalse(model.commit(plan, now: 99))
        XCTAssertFalse(model.commit(plan, now: .nan))
        XCTAssertFalse(model.active)
        XCTAssertEqual(model.preferences.previousDurations, [])
    }

    func testRecoveryNeverRestartsTheStoppedSession() throws {
        var model = SessionModel()
        try start(&model)
        let low = BatteryReading(hasBattery: true, percent: 14, onAC: false)
        XCTAssertTrue(model.advance(now: 200, battery: low))
        XCTAssertFalse(model.advance(now: 201, battery: charged))
        XCTAssertFalse(model.active)
        XCTAssertEqual(model.stopReason, .lowBattery)
        XCTAssertTrue(model.setDurationMinutes(90))
        XCTAssertTrue(model.setKeepScreenAwake(false))
        let plan = try ready(model.prepareStart(battery: charged, now: 300))
        XCTAssertTrue(model.commit(plan, now: 300))
        XCTAssertNil(model.stopReason)
        XCTAssertEqual(model.remaining(at: 300), 5_400)
    }

    func testBatteryDropInvalidatesPreparedStartEvenWhileWindowWouldBeHidden() throws {
        for reading in [
            BatteryReading(hasBattery: true, percent: 14, onAC: true),
            BatteryReading(hasBattery: true, percent: nil, onAC: false)
        ] {
            var model = SessionModel()
            let plan = try ready(model.prepareStart(durationMinutes: 60, battery: charged, now: 100))
            // Core safeguards never depend on whether a window is visible.
            XCTAssertFalse(model.advance(now: 101, battery: reading))
            XCTAssertFalse(model.commit(plan, now: 101))
            XCTAssertFalse(model.active)
            XCTAssertEqual(model.preferences.previousDurations, [])
            let fresh = try ready(model.prepareStart(durationMinutes: 60, battery: charged, now: 102))
            XCTAssertTrue(model.commit(fresh, now: 102))
        }
    }

    func testBatteryStopInvalidatesPreparedExtensionAndPreservesHistory() throws {
        var model = SessionModel()
        try start(&model)
        let extensionPlan = try ready(model.prepareExtension(battery: desktop, now: 200))
        XCTAssertTrue(model.advance(now: 201, battery: BatteryReading(hasBattery: true, percent: 14, onAC: true)))
        XCTAssertFalse(model.commit(extensionPlan, now: 202))
        XCTAssertEqual(model.stopReason, .lowBattery)
        XCTAssertEqual(model.preferences.previousDurations, [60])
        XCTAssertEqual(model.totalDurationSeconds, 0)
    }

    func testInvalidClockStopsActiveSessionAndInvalidatesPreparedStart() throws {
        for invalid in [-1, Double.nan, Double.infinity, -Double.infinity] {
            var inactive = SessionModel()
            let startPlan = try ready(inactive.prepareStart(durationMinutes: 60, battery: desktop, now: 100))
            XCTAssertFalse(inactive.advance(now: invalid, battery: desktop))
            XCTAssertFalse(inactive.commit(startPlan, now: 101))
            var active = SessionModel()
            try start(&active)
            XCTAssertTrue(active.advance(now: invalid, battery: desktop))
            XCTAssertEqual(active.stopReason, .clockUnavailable)
            XCTAssertFalse(active.active)
            XCTAssertFalse(active.advance(now: 200, battery: desktop))
        }
    }

    func testPreparedExtensionCannotCommitAfterAnotherExtension() throws {
        var model = SessionModel()
        try start(&model)
        let first = try ready(model.prepareExtension(battery: desktop, now: 200))
        let second = try ready(model.prepareExtension(battery: desktop, now: 200))
        XCTAssertTrue(model.commit(first, now: 201))
        XCTAssertFalse(model.commit(second, now: 202))
        XCTAssertEqual(model.totalDurationSeconds, 4_500)
        XCTAssertEqual(model.remaining(at: 202), 4_398)
    }

    func testLateConfirmationDoesNotExtendAnExpiredSession() throws {
        var model = SessionModel()
        try start(&model, minutes: 15)
        let risk = BatteryReading(hasBattery: true, percent: 20, onAC: false, minutesToEmpty: 30)
        guard case .warning = model.prepareExtension(battery: risk, now: 990) else {
            return XCTFail("Expected extension warning")
        }
        XCTAssertTrue(model.advance(now: 1_000, battery: risk))
        XCTAssertEqual(model.prepareExtension(battery: risk, now: 1_001, confirmRisk: true), .blocked(.notActive))
        XCTAssertEqual(model.stopReason, .expired)
        XCTAssertEqual(model.preferences.previousDurations, [15])
    }

    func testDeterministicMixedEventsPreserveSafetyAndHistoryInvariants() {
        struct Generator {
            var state: UInt64
            mutating func next(_ bound: Int) -> Int {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((state >> 32) % UInt64(bound))
            }
        }
        for seed in [1, 17, 101, 4_099, 65_537] as [UInt64] {
            var random = Generator(state: seed)
            var model = SessionModel()
            var now: TimeInterval = 100
            for eventIndex in 0..<400 {
                now += TimeInterval(random.next(121))
                let battery: BatteryReading
                switch random.next(6) {
                case 0: battery = desktop
                case 1: battery = BatteryReading(hasBattery: true, percent: nil, onAC: random.next(2) == 1)
                default:
                    battery = BatteryReading(
                        hasBattery: true,
                        percent: Double(random.next(101)),
                        onAC: random.next(2) == 1,
                        minutesToEmpty: random.next(3) == 0 ? nil : Double(random.next(600) + 1)
                    )
                }
                model.advance(now: now, battery: battery)
                let historyBeforeAction = model.preferences.previousDurations
                switch random.next(10) {
                case 0, 1:
                    let duration = (random.next(26) * 15)
                    let prepared = model.prepareStart(durationMinutes: duration, battery: battery, now: now, confirmRisk: random.next(2) == 1)
                    if case .ready(let plan) = prepared, random.next(3) != 0 { XCTAssertTrue(model.commit(plan, now: now)) }
                    if case .warning(let plan, _) = prepared { XCTAssertFalse(model.commit(plan, now: now)) }
                case 2:
                    let prepared = model.prepareExtension(battery: battery, now: now, confirmRisk: random.next(2) == 1)
                    if case .ready(let plan) = prepared, random.next(3) != 0 { XCTAssertTrue(model.commit(plan, now: now)) }
                    if case .warning(let plan, _) = prepared { XCTAssertFalse(model.commit(plan, now: now)) }
                case 3:
                    model.stop(reason: random.next(2) == 0 ? .manual : .systemSleep)
                case 4:
                    let wasActive = model.active
                    let previous = model.keepScreenAwake
                    XCTAssertEqual(model.setKeepScreenAwake(!previous), !wasActive)
                    if wasActive { XCTAssertEqual(model.keepScreenAwake, previous) }
                case 5:
                    let wasActive = model.active
                    let previous = model.selectedDurationMinutes
                    model.setDurationMinutes(random.next(26) * 15)
                    if wasActive { XCTAssertEqual(model.selectedDurationMinutes, previous) }
                case 6:
                    let saved = model.preferences
                    let wasActive = model.active
                    // Simulate an acquisition failure: obtaining a plan alone cannot change anything.
                    _ = model.prepareStart(durationMinutes: 60, battery: battery, now: now, confirmRisk: true)
                    XCTAssertEqual(model.preferences, saved)
                    XCTAssertEqual(model.active, wasActive)
                case 7:
                    model.advance(now: .nan, battery: battery)
                    XCTAssertFalse(model.active)
                case 8:
                    model = SessionModel(preferences: model.preferences)
                    XCTAssertFalse(model.active)
                default:
                    break
                }
                let context = "seed \(seed), event \(eventIndex)"
                let history = model.preferences.previousDurations
                XCTAssertLessThanOrEqual(history.count, 3, context)
                XCTAssertEqual(Set(history).count, history.count, context)
                XCTAssertTrue(history.allSatisfy(Preferences.isValidDuration), context)
                XCTAssertTrue(Preferences.isValidDuration(model.selectedDurationMinutes), context)
                if history != historyBeforeAction {
                    XCTAssertTrue(model.active, context)
                    XCTAssertEqual(history.first, model.selectedDurationMinutes, context)
                }
                if model.active {
                    XCTAssertGreaterThan(model.remaining(at: now), 0, context)
                    XCTAssertLessThanOrEqual(model.remaining(at: now), model.totalDurationSeconds, context)
                    XCTAssertLessThanOrEqual(model.totalDurationSeconds, 21_600, context)
                    XCTAssertTrue(Preferences.isValidDuration(model.activeDurationMinutes!), context)
                    if battery.hasBattery {
                        XCTAssertNotNil(battery.validPercent, context)
                        XCTAssertGreaterThanOrEqual(battery.validPercent ?? -1, 15, context)
                    }
                } else {
                    XCTAssertEqual(model.remaining(at: now), 0, context)
                    XCTAssertEqual(model.totalDurationSeconds, 0, context)
                }
            }
        }
    }
}
