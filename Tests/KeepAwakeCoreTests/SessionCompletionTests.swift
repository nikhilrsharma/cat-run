import Foundation
import XCTest
@testable import KeepAwakeCore

final class SessionCompletionTests: XCTestCase {
    private let desktop = BatteryReading(hasBattery: false, percent: nil, onAC: true)
    private let finish = Date(timeIntervalSince1970: 1_792_110_600)

    func testExactExpiryCapturesOneStableCompletionInstant() throws {
        var model = SessionModel()
        try start(&model)
        XCTAssertFalse(model.advance(now: 999, battery: desktop, wallNow: finish.addingTimeInterval(-1)))
        XCTAssertNil(model.finishedAt)
        XCTAssertTrue(model.advance(now: 1_000, battery: desktop, wallNow: finish))
        XCTAssertEqual(model.stopReason, .expired)
        XCTAssertEqual(model.finishedAt, finish)

        XCTAssertFalse(model.advance(now: 2_000, battery: desktop, wallNow: finish.addingTimeInterval(1_000)))
        XCTAssertFalse(model.stop(reason: .manual))
        XCTAssertEqual(model.finishedAt, finish)
    }

    func testLateCallbackRecordsDeadlineInsteadOfCallbackTime() throws {
        var model = SessionModel()
        try start(&model)
        XCTAssertTrue(model.advance(now: 1_125, battery: desktop, wallNow: finish.addingTimeInterval(125)))
        XCTAssertEqual(model.finishedAt, finish)
    }

    func testFailedStartsPreserveCompletionUntilNewSessionSuccessfullyCommits() throws {
        var model = SessionModel()
        try start(&model)
        XCTAssertTrue(model.advance(now: 1_000, battery: desktop, wallNow: finish))
        let lowBattery = BatteryReading(hasBattery: true, percent: 14, onAC: true)
        XCTAssertEqual(model.prepareStart(battery: lowBattery, now: 1_100), .blocked(.lowBattery))
        XCTAssertEqual(model.finishedAt, finish)

        // Preparing without committing models a failed native wake-assertion acquisition.
        let uncommitted = try ready(model.prepareStart(durationMinutes: 30, battery: desktop, now: 1_100))
        XCTAssertEqual(model.finishedAt, finish)
        XCTAssertFalse(model.commit(uncommitted, now: 1_099))
        XCTAssertEqual(model.finishedAt, finish)
        XCTAssertTrue(model.commit(uncommitted, now: 1_100))
        XCTAssertNil(model.finishedAt)
        XCTAssertNil(model.stopReason)
    }

    func testExtensionMovesCompletionToExtendedDeadline() throws {
        var model = SessionModel()
        try start(&model)
        let extensionPlan = try ready(model.prepareExtension(battery: desktop, now: 700))
        XCTAssertTrue(model.commit(extensionPlan, now: 705))
        XCTAssertNil(model.finishedAt)
        XCTAssertFalse(model.advance(now: 1_000, battery: desktop, wallNow: finish))
        XCTAssertNil(model.finishedAt)
        XCTAssertTrue(model.advance(now: 1_930, battery: desktop, wallNow: finish.addingTimeInterval(930)))
        XCTAssertEqual(model.finishedAt, finish.addingTimeInterval(900))
    }

    func testManualAndSafetyStopsHaveNoCompletionTimestamp() throws {
        for reason in [SessionStopReason.manual, .systemSleep, .assertionFailure, .quit] {
            var model = SessionModel()
            try start(&model)
            XCTAssertTrue(model.stop(reason: reason))
            XCTAssertEqual(model.stopReason, reason)
            XCTAssertNil(model.finishedAt)
        }

        var lowBatteryModel = SessionModel()
        try start(&lowBatteryModel)
        XCTAssertTrue(lowBatteryModel.advance(now: 500, battery: BatteryReading(hasBattery: true, percent: 14, onAC: true), wallNow: finish))
        XCTAssertEqual(lowBatteryModel.stopReason, .lowBattery)
        XCTAssertNil(lowBatteryModel.finishedAt)

        var missingBatteryModel = SessionModel()
        try start(&missingBatteryModel)
        XCTAssertTrue(missingBatteryModel.advance(now: 500, battery: BatteryReading(hasBattery: true, percent: nil, onAC: false), wallNow: finish))
        XCTAssertEqual(missingBatteryModel.stopReason, .batteryUnavailable)
        XCTAssertNil(missingBatteryModel.finishedAt)

        var missingClockModel = SessionModel()
        try start(&missingClockModel)
        XCTAssertTrue(missingClockModel.advance(now: .nan, battery: desktop, wallNow: finish))
        XCTAssertEqual(missingClockModel.stopReason, .clockUnavailable)
        XCTAssertNil(missingClockModel.finishedAt)
    }

    private func start(_ model: inout SessionModel) throws {
        let plan = try ready(model.prepareStart(durationMinutes: 15, battery: desktop, now: 100))
        XCTAssertTrue(model.commit(plan, now: 100))
    }

    private func ready(_ preparation: SessionPreparation) throws -> SessionPlan {
        guard case .ready(let plan) = preparation else {
            XCTFail("Expected a prepared session, got \(preparation)")
            throw TestError.notReady
        }
        return plan
    }

    private enum TestError: Error { case notReady }
}
