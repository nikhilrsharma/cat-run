import Foundation
import KeepAwakeCore
import XCTest
@testable import KeepAwake

final class AuditLoggerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_300_000)

    func testUnrecordedAppExitIsRecoveredWithoutInventingCrashCause() throws {
        let run = UUID()
        let store = Store(events: [.init(date: now.addingTimeInterval(-600), message: "Cat Run opened.", sessionID: run, kind: .applicationOpened)])
        let logger = AuditLogger(store: store, now: { self.now }, automaticallyPrune: false)
        logger.start(previousOutcome: nil) { _ in }
        XCTAssertTrue(logger.flush())
        let events = store.snapshot().events
        XCTAssertEqual(events.first?.kind, .applicationOpened)
        let recovered = try XCTUnwrap(events.first(where: { $0.kind == .applicationInterrupted }))
        XCTAssertEqual(recovered.sessionID, run)
        XCTAssertEqual(recovered.date, now)
        XCTAssertTrue(recovered.message.contains("exit time unknown"))
        XCTAssertFalse(recovered.message.contains("crash"))
    }

    func testCleanQuitDoesNotCreateFalseInterruptionOnNextLaunch() throws {
        let store = Store()
        let first = AuditLogger(store: store, now: { self.now }, automaticallyPrune: false)
        first.start(previousOutcome: nil) { _ in }
        XCTAssertTrue(first.finish())
        let second = AuditLogger(store: store, now: { self.now }, automaticallyPrune: false)
        second.start(previousOutcome: nil) { _ in }
        XCTAssertTrue(second.flush())
        XCTAssertFalse(store.snapshot().events.contains(where: { $0.kind == .applicationInterrupted }))
    }

    func testRecoveredTimerUsesDetectionTimeAndIsNotDuplicated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SessionJournal(url: root.appendingPathComponent("session.json"))
        let id = UUID()
        try journal.begin(id: id, startedAt: now.addingTimeInterval(-600))
        let record = try XCTUnwrap(journal.recoverInterrupted(at: now))
        let store = Store()
        for _ in 0..<2 {
            let logger = AuditLogger(store: store, now: { self.now }, automaticallyPrune: false)
            logger.start(previousOutcome: record) { _ in }
            XCTAssertTrue(logger.finish())
        }
        let recovered = store.snapshot().events.filter { $0.kind == .timerStopped }
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.date, now)
        XCTAssertEqual(recovered.first?.sessionID, id)
        XCTAssertTrue(recovered.first?.message.contains("cause and stop time unknown") == true)
    }

    func testFreshWriteFailureIsVisibleEvenWhenSnapshotIsEmptyAndRecoveryMarksGap() throws {
        let store = Store()
        store.fail = true
        let failed = expectation(description: "write failure is visible")
        let resumed = expectation(description: "recovery shows gap")
        var sawError = false
        let logger = AuditLogger(store: store, now: { self.now }, automaticallyPrune: false)
        logger.start(previousOutcome: nil) { snapshot in
            if snapshot.error != nil, !sawError { sawError = true; failed.fulfill() }
            if snapshot.error == nil, snapshot.events.first?.message == "After recovery." { resumed.fulfill() }
        }
        wait(for: [failed], timeout: 2)
        XCTAssertTrue(logger.flush())
        store.fail = false
        logger.record("After recovery.")
        wait(for: [resumed], timeout: 2)
        XCTAssertTrue(store.snapshot().events.contains(where: { $0.message.contains("events may be missing") }))
    }

    func testSlowAuditDiskDoesNotBlockCallerOrMakeQuitWaitIndefinitely() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let store = Store()
        store.beforeAppend = { entered.signal(); release.wait() }
        let logger = AuditLogger(store: store, now: { self.now }, automaticallyPrune: false)
        logger.record("Before stall.")
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        // A second safety event is enqueued without waiting for the blocked disk writer.
        logger.recordStop(.init(token: UUID(), reason: .lowBattery, continuousTime: 100, date: now, timeIsDetection: false))
        XCTAssertFalse(logger.finish(timeout: 0.01))
        store.beforeAppend = nil
        release.signal()
        XCTAssertTrue(logger.flush(timeout: 2))
        XCTAssertTrue(store.snapshot().events.contains(where: { $0.kind == .timerStopped }))
    }

    func testUnavailableLaunchRecordsRunMarkerWhenLoggingRecovers() throws {
        let store = Store()
        store.readError = .keyUnavailable
        let logger = AuditLogger(store: store, now: { self.now }, automaticallyPrune: false)
        logger.start(previousOutcome: nil) { _ in }
        XCTAssertTrue(logger.flush())
        XCTAssertTrue(store.snapshot().events.isEmpty)
        store.readError = nil
        logger.record("Screen awake changed.")
        XCTAssertTrue(logger.flush())
        let events = store.snapshot().events
        XCTAssertEqual(events.filter { $0.kind == .applicationOpened }.count, 1)
        XCTAssertTrue(events.contains { $0.message.contains("events may be missing") })
        XCTAssertTrue(events.contains { $0.message == "Cat Run session is active; logging resumed." })
    }

    func testPruningRunMarkerRenewsItAndStillDetectsLaterUnrecordedExit() throws {
        let store = Store()
        let first = AuditLogger(store: store, now: { self.now }, automaticallyPrune: false)
        first.start(previousOutcome: nil) { _ in }
        XCTAssertTrue(first.flush())
        let run = try XCTUnwrap(store.snapshot().events.first?.sessionID)
        store.removeAllEvents() // Simulates retention pruning an idle, week-long run.
        first.refresh()
        XCTAssertTrue(first.flush())
        XCTAssertEqual(store.snapshot().events.first?.message, "Cat Run is still open.")
        XCTAssertEqual(store.snapshot().events.first?.sessionID, run)
        let second = AuditLogger(store: store, now: { self.now }, automaticallyPrune: false)
        second.start(previousOutcome: nil) { _ in }
        XCTAssertTrue(second.flush())
        XCTAssertEqual(store.snapshot().events.first(where: { $0.kind == .applicationInterrupted })?.sessionID, run)
    }

    func testRefreshAfterUnavailableLaunchRecoversRunMarkerWithoutUserAction() throws {
        let store = Store()
        store.readError = .keyUnavailable
        let logger = AuditLogger(store: store, now: { self.now }, automaticallyPrune: false)
        logger.start(previousOutcome: nil) { _ in }
        XCTAssertTrue(logger.flush())
        store.readError = nil
        logger.refresh()
        XCTAssertTrue(logger.flush())
        XCTAssertEqual(store.snapshot().events.first?.kind, .applicationOpened)
        XCTAssertTrue(store.snapshot().events.contains { $0.message.contains("events may be missing") })
    }

    private final class Store: AuditLogPersisting {
        private let lock = NSLock()
        private var events: [AuditEvent]
        private var failure = false
        private var readFailure: AuditLogError?
        private var work: (() -> Void)?
        var fail: Bool { get { locked { failure } } set { locked { failure = newValue } } }
        var readError: AuditLogError? { get { locked { readFailure } } set { locked { readFailure = newValue } } }
        var beforeAppend: (() -> Void)? { get { locked { work } } set { locked { work = newValue } } }
        init(events: [AuditEvent] = []) { self.events = events }
        func append(_ event: AuditEvent) throws {
            let hook = beforeAppend; hook?()
            try locked {
                if failure { throw AuditLogError.storageUnavailable }
                events.insert(event, at: 0)
            }
        }
        func snapshot() -> AuditLogSnapshot { locked { .init(events: events, error: readFailure) } }
        func removeAllEvents() { locked { events.removeAll() } }
        private func locked<T>(_ work: () throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }; return try work()
        }
    }
}
