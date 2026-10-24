import Foundation
import KeepAwakeCore
import XCTest
@testable import KeepAwake

final class SessionRequestFlowTests: XCTestCase {
    func testUnsafeSecondReadingStopsBeforeExtensionDespiteHealthyGuardReader() throws {
        for onAC in [false, true] {
            for percent: Double? in [14, nil] {
                let f = Fixture(); try f.start()
                f.uiReading = .init(hasBattery: true, percent: percent, onAC: onAC)
                let result = f.flow.prepare(f.extensionRequest, model: f.model, sessionID: f.token)
                XCTAssertNil(result.preparation)
                XCTAssertEqual(result.reading, f.uiReading)
                XCTAssertNil(f.safety.stateSnapshot().token)
                XCTAssertEqual(f.safety.drainStopEvents().first?.reason, percent == nil ? .batteryUnavailable : .lowBattery)
                XCTAssertEqual(f.power.acquisitions, 1)
                XCTAssertEqual(f.power.releases, 1)
            }
        }
    }

    func testFreshEventStopsWithoutRereadingOrAcceptingContradictoryHealthySnapshot() throws {
        let f = Fixture(); try f.start()
        let reads = f.guardBattery.readCount
        f.safety.observeBattery(.init(hasBattery: true, percent: 14, onAC: true), token: f.token)
        f.safety.checkNow()
        XCTAssertEqual(f.guardBattery.readCount, reads)
        XCTAssertEqual(f.safety.drainStopEvents().first?.reason, .lowBattery)
    }

    func testUnsafeObservationCannotStopAnotherGeneration() throws {
        let f = Fixture(); try f.start()
        f.safety.observeBattery(.init(hasBattery: true, percent: 1, onAC: false), token: UUID())
        XCTAssertEqual(f.safety.stateSnapshot().token, f.token)
        XCTAssertTrue(f.safety.drainStopEvents().isEmpty)
    }

    func testExactlyFifteenAndUnknownRuntimeAllowExtensionOnBatteryAndAC() throws {
        for onAC in [false, true] {
            let f = Fixture(); try f.start()
            f.uiReading = .init(hasBattery: true, percent: 15, onAC: onAC)
            try f.extend()
            XCTAssertEqual(f.model.totalDurationSeconds, 4_500)
        }
    }

    func testUnsafeInitialGuardReadingStopsBeforeSecondRead() throws {
        let f = Fixture(); try f.start()
        let reads = f.uiReadCount
        f.guardBattery.value = .init(hasBattery: true, percent: 14, onAC: false)
        XCTAssertNil(f.flow.prepare(f.extensionRequest, model: f.model, sessionID: f.token).preparation)
        XCTAssertEqual(f.uiReadCount, reads)
        XCTAssertEqual(f.safety.drainStopEvents().first?.reason, .lowBattery)
    }

    func testStartWithUnsafeUIReadingIsBlockedWithoutAcquiringPower() {
        let f = Fixture()
        f.uiReading = .init(hasBattery: true, percent: 14, onAC: true)
        let evaluation = f.flow.prepare(.init(durationMinutes: 60, isExtension: false), model: f.model, sessionID: nil)
        guard case .blocked(.lowBattery)? = evaluation.preparation else { return XCTFail("Expected low-charge block") }
        XCTAssertEqual(f.power.acquisitions, 0)
    }

    func testRapidExtensionsAddExactlyFifteenUntilTotalLimit() throws {
        let f = Fixture(); try f.start(minutes: 180)
        for _ in 0..<12 { try f.extend() }
        XCTAssertEqual(f.model.totalDurationSeconds, 21_600)
        XCTAssertEqual(f.safety.stateSnapshot().deadline, 22_600)
        guard case .blocked(.sixHourLimit)? = f.flow.prepare(f.extensionRequest, model: f.model, sessionID: f.token).preparation else {
            return XCTFail("Expected total-session cap")
        }
        XCTAssertEqual(f.power.acquisitions, 13)
        XCTAssertEqual(f.model.preferences.previousDurations, [180])
    }

    func testWarningUsesAllRemainingTimeAndPendingClicksDoNotAddTime() throws {
        let f = Fixture(); try f.start()
        let warning = try f.showRiskWarning()
        let beforeReads = f.uiReadCount
        XCTAssertNil(f.flow.prepare(f.extensionRequest, model: f.model, sessionID: f.token).preparation)
        XCTAssertEqual(f.uiReadCount, beforeReads)
        XCTAssertEqual(f.model.remaining(at: f.clock.now), 3_600)
        XCTAssertEqual(f.flow.warning?.id, warning.id)
        XCTAssertEqual(f.power.acquisitions, 1)
    }

    func testCancelDoesNotExtendAndCompletionCanOnlyBeConsumedOnce() throws {
        let f = Fixture(); try f.start()
        let warning = try f.showRiskWarning()
        XCTAssertNil(f.flow.resolveWarning(id: warning.id, accepted: false, sessionID: f.token))
        XCTAssertNil(f.flow.resolveWarning(id: warning.id, accepted: true, sessionID: f.token))
        XCTAssertEqual(f.model.remaining(at: f.clock.now), 3_600)
    }

    func testContinueRereadsAndCannotOverrideNewUnsafeCharge() throws {
        let f = Fixture(); try f.start()
        let warning = try f.showRiskWarning()
        let accepted = try XCTUnwrap(f.flow.resolveWarning(id: warning.id, accepted: true, sessionID: f.token))
        f.uiReading = .init(hasBattery: true, percent: 14, onAC: true)
        XCTAssertNil(f.flow.prepare(accepted, model: f.model, sessionID: f.token).preparation)
        XCTAssertEqual(f.safety.drainStopEvents().first?.reason, .lowBattery)
        XCTAssertEqual(f.model.totalDurationSeconds, 3_600)
    }

    func testWaitingDoesNotAddExtraTimeAndNextExtensionWarnsAgain() throws {
        let f = Fixture(); try f.start()
        let warning = try f.showRiskWarning()
        f.clock.now += 10
        let accepted = try XCTUnwrap(f.flow.resolveWarning(id: warning.id, accepted: true, sessionID: f.token))
        try f.commit(try f.ready(f.flow.prepare(accepted, model: f.model, sessionID: f.token)))
        XCTAssertEqual(f.model.remaining(at: f.clock.now), 4_490)
        XCTAssertEqual(f.safety.stateSnapshot().deadline, 5_500)
        guard case .warning? = f.flow.prepare(f.extensionRequest, model: f.model, sessionID: f.token).preparation else {
            return XCTFail("Each later extension must assess forecast risk again")
        }
    }

    func testWarningRefreshShowsACUnknownAndChangedForecastWithoutCommitting() throws {
        let f = Fixture(); try f.start()
        _ = try f.showRiskWarning()
        let first = try XCTUnwrap(f.flow.warningMessage(model: f.model, reading: f.uiReading))
        XCTAssertTrue(first.contains("Adding 15m"))
        let worse = BatteryReading(hasBattery: true, percent: 20, onAC: false, minutesToEmpty: 40)
        XCTAssertNotEqual(f.flow.warningMessage(model: f.model, reading: worse), first)
        let ac = BatteryReading(hasBattery: true, percent: 70, onAC: true)
        XCTAssertTrue(f.flow.warningMessage(model: f.model, reading: ac)!.contains("Connected to power"))
        let unknown = BatteryReading(hasBattery: true, percent: 70, onAC: false)
        XCTAssertTrue(f.flow.warningMessage(model: f.model, reading: unknown)!.contains("estimate unavailable"))
        let safe = BatteryReading(hasBattery: true, percent: 70, onAC: false, minutesToEmpty: 600)
        XCTAssertTrue(f.flow.warningMessage(model: f.model, reading: safe)!.contains("no longer"))
        XCTAssertEqual(f.model.totalDurationSeconds, 3_600)
        XCTAssertEqual(f.power.acquisitions, 1)
    }

    func testLateContinueCannotReviveStoppedOrExpiredSession() throws {
        for reason in [SessionStopReason.manual, .systemSleep, .lowBattery, .shutdown] {
            let f = Fixture(); try f.start()
            let warning = try f.showRiskWarning()
            f.safety.stop(token: f.token, reason: reason)
            let accepted = try XCTUnwrap(f.flow.resolveWarning(id: warning.id, accepted: true, sessionID: f.token))
            XCTAssertNil(f.flow.prepare(accepted, model: f.model, sessionID: f.token).preparation)
            XCTAssertNil(f.safety.stateSnapshot().token)
        }
        let f = Fixture(); try f.start()
        let warning = try f.showRiskWarning()
        f.advanceSafely(seconds: 3_600)
        let accepted = try XCTUnwrap(f.flow.resolveWarning(id: warning.id, accepted: true, sessionID: f.token))
        XCTAssertNil(f.flow.prepare(accepted, model: f.model, sessionID: f.token).preparation)
        XCTAssertEqual(f.safety.drainStopEvents().first?.reason, .expired)
    }

    func testUnsafeObservationPreservesExpiryAndMissedSleepPriority() throws {
        let expired = Fixture(); try expired.start()
        expired.advanceSafely(seconds: 3_590)
        expired.clock.now += 10
        expired.safety.observeBattery(.init(hasBattery: true, percent: 14, onAC: false), token: expired.token)
        XCTAssertEqual(expired.safety.drainStopEvents().first?.reason, .expired)

        let asleep = Fixture(); try asleep.start()
        asleep.clock.now += 60; asleep.clock.slept += 60
        asleep.safety.observeBattery(.init(hasBattery: true, percent: nil, onAC: true), token: asleep.token)
        let stop = try XCTUnwrap(asleep.safety.drainStopEvents().first)
        XCTAssertEqual(stop.reason, .systemSleep)
        XCTAssertTrue(stop.timeIsDetection)
    }

    func testCancelledOrOlderWarningCannotAffectNewWarningOrSession() throws {
        let f = Fixture(); try f.start()
        let old = try f.showRiskWarning()
        f.flow.cancelWarning()
        let new = try f.showRiskWarning()
        XCTAssertNil(f.flow.resolveWarning(id: old.id, accepted: true, sessionID: f.token))
        XCTAssertEqual(f.flow.warning?.id, new.id)
        XCTAssertNil(f.flow.resolveWarning(id: new.id, accepted: true, sessionID: UUID()))
        XCTAssertNil(f.flow.warning)
    }

    private final class Fixture {
        final class Clock {
            var now: TimeInterval = 1_000
            var slept: TimeInterval = 0
            func read() -> SessionSafetyClock { .init(continuous: now, uptime: now - slept, date: Date(timeIntervalSince1970: now)) }
        }
        final class Reader: SessionBatteryReading {
            var value = BatteryReading(hasBattery: true, percent: 70, onAC: false)
            var readCount = 0
            func read() -> BatteryReading { readCount += 1; return value }
        }
        final class Power: SessionPowerManaging {
            var acquisitions = 0; var releases = 0
            func acquire(keepScreenAwake: Bool, timeout: TimeInterval) throws { acquisitions += 1 }
            func release() { releases += 1 }
        }
        let token = UUID()
        let clock = Clock()
        let guardBattery = Reader()
        let power = Power()
        var model = SessionModel()
        var uiReading = BatteryReading(hasBattery: true, percent: 70, onAC: false)
        var uiReadCount = 0
        lazy var safety = SessionSafetyGuard(power: power, battery: guardBattery, clock: clock.read,
                                             automaticallySchedule: false, deliverToMain: { _ in })
        lazy var flow = SessionRequestFlow(safety: safety, readBattery: { [unowned self] in
            self.uiReadCount += 1; return self.uiReading
        }, now: { [clock] in clock.now })
        var extensionRequest: SessionRequestFlow.Request { .init(durationMinutes: model.selectedDurationMinutes, isExtension: true) }
        func start(minutes: Int = 60) throws {
            let plan = try ready(flow.prepare(.init(durationMinutes: minutes, isExtension: false), model: model, sessionID: nil))
            try safety.begin(token: token, keepScreenAwake: plan.keepScreenAwake, timeout: plan.timeoutSeconds)
            XCTAssertTrue(model.commit(plan, now: clock.now))
        }
        func ready(_ result: SessionRequestFlow.Evaluation) throws -> SessionPlan {
            guard case .ready(let plan)? = result.preparation else { throw NSError(domain: "ExpectedReady", code: 1) }
            return plan
        }
        func commit(_ plan: SessionPlan) throws {
            try safety.extend(token: token, by: 900)
            XCTAssertTrue(model.commit(plan, now: clock.now))
        }
        func extend() throws { try commit(try ready(flow.prepare(extensionRequest, model: model, sessionID: token))) }
        func advanceSafely(seconds: Int) {
            for _ in 0..<(seconds / 10) {
                clock.now += 10
                safety.heartbeat(token: token)
                safety.checkScheduled()
            }
        }
        func showRiskWarning() throws -> SessionRequestFlow.Warning {
            uiReading = .init(hasBattery: true, percent: 30, onAC: false, minutesToEmpty: 100)
            guard case .warning(let plan, _)? = flow.prepare(extensionRequest, model: model, sessionID: token).preparation else {
                throw NSError(domain: "ExpectedWarning", code: 1)
            }
            XCTAssertEqual(plan.timeoutSeconds, model.remaining(at: clock.now) + 900)
            return flow.beginWarning(for: extensionRequest, sessionID: token)
        }
    }
}
