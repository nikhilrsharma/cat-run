import Foundation
import KeepAwakeCore
import XCTest
@testable import KeepAwake

final class SessionSafetyGuardTests: XCTestCase {
    func testStartAcquiresOnlyShortLeaseAndKeepsOriginalDeadline() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 900)
        XCTAssertEqual(fixture.power.acquisitions, [.init(screen: true, timeout: 45)])
        XCTAssertEqual(fixture.guardService.stateSnapshot().deadline, 1_900)
        XCTAssertEqual(fixture.guardService.stateSnapshot().token, fixture.token)
    }

    func testLeaseNeverOutlivesSessionDeadline() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 20)
        XCTAssertEqual(fixture.power.acquisitions.last?.timeout, 20)
        fixture.advance(10)
        fixture.guardService.checkNow(renewLease: true)
        XCTAssertEqual(fixture.power.acquisitions.last?.timeout, 10)
        XCTAssertEqual(fixture.guardService.stateSnapshot().deadline, 1_020)
    }

    func testFreshLowBatteryStopsEvenOnChargerAndBeforeUIProcessesCallback() throws {
        let fixture = Fixture()
        var persisted: [SessionSafetyGuard.StopEvent] = []
        var presented: [SessionSafetyGuard.StopEvent] = []
        fixture.guardService.onStopRecorded = { persisted.append($0) }
        fixture.guardService.onStop = { presented.append($0) }
        try fixture.begin()
        fixture.battery.value = BatteryReading(hasBattery: true, percent: 14.9,
                                               onAC: true, minutesToEmpty: nil)
        fixture.advance(10)
        fixture.guardService.checkNow()
        XCTAssertEqual(fixture.power.releases, 1)
        XCTAssertEqual(persisted.first?.reason, .lowBattery)
        XCTAssertTrue(presented.isEmpty)
        XCTAssertEqual(fixture.guardService.stateSnapshot().terminalEvents.first?.reason, .lowBattery)
        XCTAssertNil(fixture.guardService.stateSnapshot().token)
        fixture.deliverPending()
        XCTAssertEqual(presented, persisted)
    }

    func testExactlyFifteenPercentIsAllowedAndUnknownRuntimeIsIrrelevant() throws {
        let fixture = Fixture()
        fixture.battery.value = BatteryReading(hasBattery: true, percent: 15,
                                               onAC: false, minutesToEmpty: nil)
        try fixture.begin()
        fixture.advance(10)
        fixture.guardService.checkNow(renewLease: true)
        XCTAssertEqual(fixture.guardService.stateSnapshot().token, fixture.token)
        XCTAssertTrue(fixture.guardService.drainStopEvents().isEmpty)
    }

    func testUnavailableChargeStopsInsteadOfDisablingProtection() throws {
        let fixture = Fixture()
        try fixture.begin()
        fixture.battery.value = BatteryReading(hasBattery: true, percent: nil,
                                               onAC: true, minutesToEmpty: 100)
        fixture.guardService.checkNow()
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .batteryUnavailable)
        XCTAssertEqual(fixture.power.releases, 1)
    }

    func testKnownDesktopDoesNotRequireBatteryPercentage() throws {
        let fixture = Fixture()
        fixture.battery.value = BatteryReading(hasBattery: false, percent: nil,
                                               onAC: true, minutesToEmpty: nil)
        try fixture.begin()
        fixture.guardService.checkNow()
        XCTAssertEqual(fixture.guardService.stateSnapshot().token, fixture.token)
    }

    func testUnsafeInitialBatteryNeverAcquiresPower() {
        for percent in [Double?.none, 14.0] {
            let fixture = Fixture()
            fixture.battery.value = BatteryReading(hasBattery: true, percent: percent,
                                                   onAC: true, minutesToEmpty: nil)
            XCTAssertThrowsError(try fixture.begin())
            XCTAssertTrue(fixture.power.acquisitions.isEmpty)
            XCTAssertNil(fixture.guardService.stateSnapshot().token)
        }
    }

    func testMainThreadHangReleasesAtHeartbeatTimeout() throws {
        let fixture = Fixture()
        try fixture.begin()
        fixture.advance(10)
        fixture.guardService.checkNow(renewLease: true)
        fixture.advance(10)
        fixture.guardService.checkNow(renewLease: true)
        fixture.advance(10)
        fixture.guardService.checkNow(renewLease: true)
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .unresponsive)
        XCTAssertEqual(fixture.power.releases, 1)
        XCTAssertEqual(fixture.power.acquisitions.count, 3)
        // If this queue itself hangs, the latest issued OS lease is still <=45s.
        XCTAssertTrue(fixture.power.acquisitions.allSatisfy { $0.timeout <= 45 })
    }

    func testFreshMainHeartbeatKeepsHealthySessionRunning() throws {
        let fixture = Fixture()
        try fixture.begin()
        for _ in 0..<10 {
            fixture.advance(10)
            fixture.guardService.heartbeat(token: fixture.token)
            fixture.guardService.checkNow(renewLease: true)
        }
        XCTAssertEqual(fixture.guardService.stateSnapshot().token, fixture.token)
        XCTAssertEqual(fixture.power.acquisitions.count, 11)
    }

    func testMainHeartbeatAfterSlowSuccessfulStartPreventsFalseUnresponsiveStop() throws {
        let fixture = Fixture()
        fixture.power.onAcquire = { [weak fixture] in fixture?.advance(25) }
        try fixture.begin()
        fixture.power.onAcquire = nil

        // Acquisition blocked the caller, but the main thread has now returned
        // and committed the timer. AppCoordinator sends this immediate heartbeat.
        fixture.guardService.heartbeat(token: fixture.token)
        _ = fixture.guardService.stateSnapshot() // Drain the asynchronous heartbeat.
        fixture.advance(10)
        fixture.guardService.checkNow(renewLease: true)

        XCTAssertEqual(fixture.guardService.stateSnapshot().token, fixture.token)
        XCTAssertEqual(fixture.guardService.stateSnapshot().deadline, 1_900)
        XCTAssertTrue(fixture.guardService.drainStopEvents().isEmpty)
        XCTAssertEqual(fixture.power.acquisitions.count, 2)
        XCTAssertEqual(fixture.power.releases, 0)
    }

    func testMissedSleepNotificationStopsEvenAfterDeadline() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 100)
        fixture.advance(600, awake: 5)
        fixture.guardService.checkNow()
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .systemSleep)
        XCTAssertEqual(fixture.power.releases, 1)
    }

    func testOrdinarySmallClockSamplingDifferenceDoesNotLookLikeSleep() throws {
        let fixture = Fixture()
        try fixture.begin()
        fixture.advance(10, awake: 9.9)
        fixture.guardService.checkNow()
        XCTAssertTrue(fixture.guardService.drainStopEvents().isEmpty)
    }

    func testExpiredDeadlineWinsOverBatteryReadingObservedLater() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 20)
        fixture.battery.value = BatteryReading(hasBattery: true, percent: 1,
                                               onAC: false, minutesToEmpty: nil)
        fixture.advance(25)
        fixture.guardService.checkNow()
        let event = try XCTUnwrap(fixture.guardService.drainStopEvents().first)
        XCTAssertEqual(event.reason, .expired)
        XCTAssertEqual(event.continuousTime, 1_020)
        XCTAssertEqual(event.date, Date(timeIntervalSince1970: 10_020))
    }

    func testClockAnomalyStopsAndDoesNotRenewLease() throws {
        let fixture = Fixture()
        try fixture.begin()
        fixture.clock.continuous = .nan
        fixture.guardService.checkNow(renewLease: true)
        let event = try XCTUnwrap(fixture.guardService.drainStopEvents().first)
        XCTAssertEqual(event.reason, .clockUnavailable)
        XCTAssertTrue(event.continuousTime.isFinite)
        XCTAssertEqual(fixture.power.acquisitions.count, 1)
    }

    func testInvalidClockAndDurationNeverAcquirePower() {
        let fixture = Fixture()
        XCTAssertThrowsError(try fixture.begin(seconds: 0))
        XCTAssertThrowsError(try fixture.begin(seconds: .infinity))
        XCTAssertThrowsError(try fixture.begin(seconds: 21_601))
        fixture.clock.uptime = -1
        XCTAssertThrowsError(try fixture.begin())
        XCTAssertTrue(fixture.power.acquisitions.isEmpty)
    }

    func testRenewalFailureReleasesOriginalLeaseAndRecordsStop() throws {
        let fixture = Fixture()
        try fixture.begin()
        fixture.power.failNext = true
        fixture.advance(10)
        fixture.guardService.checkNow(renewLease: true)
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .assertionFailure)
        XCTAssertEqual(fixture.power.releases, 1)
        XCTAssertNil(fixture.guardService.stateSnapshot().token)
    }

    func testExtensionChecksFreshBatteryBeforeAcquiringLongerLease() throws {
        let fixture = Fixture()
        try fixture.begin()
        fixture.battery.value = BatteryReading(hasBattery: true, percent: 10,
                                               onAC: true, minutesToEmpty: nil)
        XCTAssertThrowsError(try fixture.guardService.extend(token: fixture.token, timeout: 1_800))
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .lowBattery)
        XCTAssertEqual(fixture.power.acquisitions.count, 1)
    }

    func testExtensionAfterExpiryCannotResurrectSession() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 20)
        fixture.advance(20)
        XCTAssertThrowsError(try fixture.guardService.extend(token: fixture.token, timeout: 900))
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .expired)
        XCTAssertNil(fixture.guardService.stateSnapshot().token)
    }

    func testExtensionFailureStopsConservatively() throws {
        let fixture = Fixture()
        try fixture.begin()
        fixture.power.failNext = true
        XCTAssertThrowsError(try fixture.guardService.extend(token: fixture.token, timeout: 1_800))
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .assertionFailure)
        XCTAssertEqual(fixture.power.releases, 1)
    }

    func testExtensionUpdatesDeadlineWithBoundedLease() throws {
        let fixture = Fixture()
        try fixture.begin()
        fixture.advance(10)
        try fixture.guardService.extend(token: fixture.token, timeout: 1_790)
        XCTAssertEqual(fixture.guardService.stateSnapshot().deadline, 2_800)
        XCTAssertEqual(fixture.power.acquisitions.last?.timeout, 45)
    }

    func testUndrainedStopPreventsNewSessionFromHidingPreviousEvent() throws {
        let fixture = Fixture()
        try fixture.begin()
        fixture.guardService.stop(token: fixture.token, reason: .manual)
        XCTAssertThrowsError(try fixture.guardService.begin(token: UUID(), keepScreenAwake: false,
                                                           timeout: 900)) {
            XCTAssertEqual($0 as? SessionSafetyError, .pendingStop)
        }
        XCTAssertEqual(fixture.guardService.drainStopEvents().count, 1)
        XCTAssertTrue(fixture.guardService.drainStopEvents().isEmpty)
        let newToken = UUID()
        try fixture.guardService.begin(token: newToken, keepScreenAwake: false, timeout: 900)
        XCTAssertEqual(fixture.guardService.stateSnapshot().token, newToken)
    }

    func testStaleCallbacksCannotStopReleaseOrExtendNewGeneration() throws {
        let fixture = Fixture()
        try fixture.begin()
        fixture.guardService.stop(token: fixture.token, reason: .manual)
        _ = fixture.guardService.drainStopEvents()
        let newToken = UUID()
        try fixture.guardService.begin(token: newToken, keepScreenAwake: false, timeout: 900)
        fixture.guardService.release(token: fixture.token)
        fixture.guardService.stop(token: fixture.token, reason: .quit)
        fixture.guardService.heartbeat(token: fixture.token)
        XCTAssertThrowsError(try fixture.guardService.extend(token: fixture.token, timeout: 1_800))
        XCTAssertEqual(fixture.guardService.stateSnapshot().token, newToken)
        XCTAssertEqual(fixture.power.releases, 1)
    }

    func testManualStopAfterDeadlineReportsFinishedButSleepStaysInterrupted() throws {
        for reason in [SessionStopReason.manual, .systemSleep, .unresponsive] {
            let fixture = Fixture()
            try fixture.begin(seconds: 20)
            fixture.advance(20)
            fixture.guardService.stop(token: fixture.token, reason: reason)
            XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason,
                           reason == .manual ? .expired : reason)
        }
    }

    func testIdleAndStoppedGuardDoesNoBatteryPolling() throws {
        let fixture = Fixture()
        fixture.guardService.checkNow(renewLease: true)
        XCTAssertEqual(fixture.battery.reads, 0)
        try fixture.begin()
        fixture.guardService.stop(token: fixture.token, reason: .quit)
        let readsAfterStop = fixture.battery.reads
        fixture.guardService.checkNow(renewLease: true)
        fixture.guardService.checkNow()
        XCTAssertEqual(fixture.battery.reads, readsAfterStop)
        XCTAssertEqual(fixture.guardService.drainStopEvents().count, 1)
    }

    func testUserInterfaceChecksDoNotRenewLeases() throws {
        let fixture = Fixture()
        try fixture.begin()
        for _ in 0..<20 { fixture.guardService.checkNow() }
        XCTAssertEqual(fixture.power.acquisitions.count, 1)
    }

    func testGuardDelayPastLeaseDoesNotResurrectLostProtection() throws {
        let fixture = Fixture()
        try fixture.begin()
        fixture.advance(50)
        fixture.guardService.heartbeat(token: fixture.token)
        fixture.guardService.checkNow(renewLease: true)
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .assertionFailure)
        XCTAssertEqual(fixture.power.acquisitions.count, 1)
    }

    func testBatteryReadDelayedPastDeadlineCannotRenewExpiredTimer() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 20)
        fixture.battery.onRead = { [weak fixture] in fixture?.advance(25) }
        fixture.guardService.checkNow(renewLease: true)
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .expired)
        XCTAssertEqual(fixture.power.acquisitions.count, 1)
    }

    func testOSAcquisitionDelayedPastDeadlineIsImmediatelyReleased() throws {
        let fixture = Fixture()
        fixture.power.onAcquire = { [weak fixture] in fixture?.advance(25) }
        XCTAssertThrowsError(try fixture.begin(seconds: 20))
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .expired)
        XCTAssertEqual(fixture.power.releases, 1)
        XCTAssertNil(fixture.guardService.stateSnapshot().token)
    }

    func testLateGuardDoesNotReportCompletionAfterLeaseLapsedBeforeDeadline() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 100)
        fixture.advance(150)
        fixture.guardService.heartbeat(token: fixture.token)
        fixture.guardService.checkNow(renewLease: true)
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .assertionFailure)
        XCTAssertEqual(fixture.power.acquisitions.count, 1)
    }

    func testLateGuardPreservesEarlierHeartbeatFailureBeforeDeadline() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 100)
        fixture.advance(150)
        fixture.guardService.checkNow()
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .unresponsive)
    }

    func testManualStopAlsoDetectsPreviouslyLapsedLease() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 100)
        fixture.advance(150)
        fixture.guardService.heartbeat(token: fixture.token)
        fixture.guardService.stop(token: fixture.token, reason: .manual)
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .assertionFailure)
    }

    func testHeartbeatAndLeaseEndingAtSessionDeadlineRemainNaturalCompletion() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 30)
        fixture.advance(40)
        fixture.guardService.checkNow()
        let event = try XCTUnwrap(fixture.guardService.drainStopEvents().first)
        XCTAssertEqual(event.reason, .expired)
        XCTAssertEqual(event.continuousTime, 1_030)
    }

    func testExactExtensionAddsToOriginalDeadlineDespiteAcquisitionDelay() throws {
        let fixture = Fixture()
        try fixture.begin()
        fixture.advance(10)
        fixture.power.onAcquire = { [weak fixture] in fixture?.advance(5) }
        try fixture.guardService.extend(token: fixture.token, by: 900)
        XCTAssertEqual(fixture.guardService.stateSnapshot().deadline, 2_800)
        XCTAssertEqual(fixture.power.acquisitions.last?.timeout, 45)
    }

    func testExactExtensionCannotExceedSixHoursFromSessionStart() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: SessionModel.maximumSessionSeconds)
        XCTAssertThrowsError(try fixture.guardService.extend(token: fixture.token, by: 900)) {
            XCTAssertEqual($0 as? SessionSafetyError, .invalidDuration)
        }
        XCTAssertEqual(fixture.guardService.stateSnapshot().deadline, 22_600)
        XCTAssertTrue(fixture.guardService.drainStopEvents().isEmpty)
    }

    func testExactExtensionCannotReviveElapsedSession() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 20)
        fixture.advance(25)
        XCTAssertThrowsError(try fixture.guardService.extend(token: fixture.token, by: 900))
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .expired)
    }

    func testRenewalDelayedPastShortSessionDeadlineReleasesAndRecordsExpiry() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 20)
        fixture.advance(10)
        fixture.power.onAcquire = { [weak fixture] in fixture?.advance(15) }
        fixture.guardService.checkNow(renewLease: true)
        let event = try XCTUnwrap(fixture.guardService.drainStopEvents().first)
        XCTAssertEqual(event.reason, .expired)
        XCTAssertEqual(event.continuousTime, 1_020)
        XCTAssertEqual(fixture.power.releases, 1)
    }

    func testRenewalDelayedBeyondLongSessionDoesNotFabricateCompletion() throws {
        let fixture = Fixture()
        try fixture.begin(seconds: 100)
        fixture.advance(10)
        fixture.power.onAcquire = { [weak fixture] in fixture?.advance(150) }
        fixture.guardService.checkNow(renewLease: true)
        XCTAssertEqual(fixture.guardService.drainStopEvents().first?.reason, .unresponsive)
        XCTAssertEqual(fixture.power.releases, 1)
    }

    private final class Fixture {
        let token = UUID()
        let clock = Clock()
        let power = Power()
        let battery = Battery()
        var pending: [() -> Void] = []
        lazy var guardService = SessionSafetyGuard(power: power, battery: battery,
            clock: { [clock] in clock.read() }, automaticallySchedule: false,
            deliverToMain: { [weak self] work in self?.pending.append(work) })
        func begin(seconds: TimeInterval = 900) throws {
            try guardService.begin(token: token, keepScreenAwake: true, timeout: seconds)
        }
        func advance(_ seconds: TimeInterval, awake: TimeInterval? = nil) {
            clock.continuous += seconds
            clock.uptime += awake ?? seconds
            clock.date = clock.date.addingTimeInterval(seconds)
        }
        func deliverPending() {
            let callbacks = pending
            pending.removeAll()
            callbacks.forEach { $0() }
        }
    }
    private final class Clock {
        var continuous: TimeInterval = 1_000
        var uptime: TimeInterval = 500
        var date = Date(timeIntervalSince1970: 10_000)
        func read() -> SessionSafetyClock {
            SessionSafetyClock(continuous: continuous, uptime: uptime, date: date)
        }
    }
    private final class Battery: SessionBatteryReading {
        var value = BatteryReading(hasBattery: true, percent: 90, onAC: false, minutesToEmpty: nil)
        var reads = 0
        var onRead: (() -> Void)?
        func read() -> BatteryReading { reads += 1; onRead?(); return value }
    }
    private final class Power: SessionPowerManaging {
        struct Acquisition: Equatable { let screen: Bool; let timeout: TimeInterval }
        enum Failure: Error { case denied }
        var acquisitions: [Acquisition] = []
        var releases = 0
        var failNext = false
        var onAcquire: (() -> Void)?
        func acquire(keepScreenAwake: Bool, timeout: TimeInterval) throws {
            if failNext { failNext = false; throw Failure.denied }
            acquisitions.append(Acquisition(screen: keepScreenAwake, timeout: timeout))
            onAcquire?()
        }
        func release() { releases += 1 }
    }
}
