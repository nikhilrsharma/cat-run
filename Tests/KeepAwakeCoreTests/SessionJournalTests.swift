import Foundation
import XCTest
@testable import KeepAwakeCore

final class SessionJournalTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private let start = Date(timeIntervalSince1970: 1_792_180_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("CatRun/session.json")
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testFreshInstallHasNoSessionAndCreatesNoFileWhenRead() throws {
        let journal = SessionJournal(url: url)
        XCTAssertNil(try journal.load())
        XCTAssertNil(try journal.recoverInterrupted())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testNewProcessRecoversActiveSessionAsInterruptedWithUnknownEnd() throws {
        let id = UUID()
        try SessionJournal(url: url).begin(id: id, startedAt: start)

        let relaunched = SessionJournal(url: url)
        let active = try XCTUnwrap(relaunched.load())
        XCTAssertEqual(active.id, id)
        XCTAssertEqual(active.startedAt, start)
        XCTAssertEqual(active.state, .active)
        XCTAssertNil(active.reason)
        XCTAssertNil(active.endedAt)

        let recovered = try XCTUnwrap(relaunched.recoverInterrupted())
        XCTAssertEqual(recovered.id, id)
        XCTAssertEqual(recovered.state, .finished)
        XCTAssertEqual(recovered.reason, "interrupted")
        XCTAssertNil(recovered.endedAt)
        XCTAssertEqual(try SessionJournal(url: url).load(), recovered)
        XCTAssertEqual(try SessionJournal(url: url).recoverInterrupted(), recovered)
    }

    func testKnownStopsRetainOriginalReasonAndObservedTimeAcrossRelaunch() throws {
        let journal = SessionJournal(url: url)
        for reason in ["expired", "manual", "systemSleep", "quit", "lowBattery", "batteryUnavailable"] {
            let id = UUID()
            let end = start.addingTimeInterval(900)
            try journal.begin(id: id, startedAt: start)
            try journal.finish(id: id, reason: reason, endedAt: end)
            let recovered = try XCTUnwrap(SessionJournal(url: url).recoverInterrupted())
            XCTAssertEqual(recovered.id, id)
            XCTAssertEqual(recovered.startedAt, start)
            XCTAssertEqual(recovered.state, .finished)
            XCTAssertEqual(recovered.reason, reason)
            XCTAssertEqual(recovered.endedAt, end)
        }
    }

    func testRecoveryAllowsNewSessionWithoutKeepingGrowingHistory() throws {
        let journal = SessionJournal(url: url)
        try journal.begin(id: UUID(), startedAt: start)
        _ = try journal.recoverInterrupted()
        let latestID = UUID()
        try journal.begin(id: latestID, startedAt: start.addingTimeInterval(2_000))
        let record = try XCTUnwrap(journal.load())
        XCTAssertEqual(record.id, latestID)
        XCTAssertEqual(record.state, .active)
        XCTAssertNil(record.reason)
        XCTAssertNil(record.endedAt)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(files, ["session.json"])
        XCTAssertLessThan(try Data(contentsOf: url).count, 1_024)
    }

    func testOldSessionCannotOverwriteNewSessionOutcome() throws {
        let journal = SessionJournal(url: url)
        let oldID = UUID()
        try journal.begin(id: oldID, startedAt: start)
        try journal.finish(id: oldID, reason: "manual", endedAt: start.addingTimeInterval(60))
        let newID = UUID()
        try journal.begin(id: newID, startedAt: start.addingTimeInterval(120))
        let before = try journal.load()
        XCTAssertThrowsError(try journal.finish(id: oldID, reason: "expired", endedAt: start.addingTimeInterval(900))) {
            XCTAssertEqual($0 as? SessionJournalError, .sessionMismatch)
        }
        XCTAssertEqual(try journal.load(), before)
    }

    func testFirstTerminalOutcomeWinsForDuplicateCallbacks() throws {
        let journal = SessionJournal(url: url)
        let id = UUID()
        try journal.begin(id: id, startedAt: start)
        try journal.finish(id: id, reason: "lowBattery", endedAt: start.addingTimeInterval(900))
        let first = try journal.load()
        try journal.finish(id: id, reason: "expired", endedAt: start.addingTimeInterval(901))
        XCTAssertEqual(try journal.load(), first)
    }

    func testActiveRecordCannotBeOverwrittenWithoutRecovery() throws {
        let journal = SessionJournal(url: url)
        try journal.begin(id: UUID(), startedAt: start)
        let original = try journal.load()
        XCTAssertThrowsError(try journal.begin(id: UUID(), startedAt: start.addingTimeInterval(10))) {
            XCTAssertEqual($0 as? SessionJournalError, .sessionAlreadyActive)
        }
        XCTAssertEqual(try journal.load(), original)
    }

    func testFinishWithoutSessionDoesNotInventRecord() throws {
        let journal = SessionJournal(url: url)
        XCTAssertThrowsError(try journal.finish(id: UUID(), reason: "expired", endedAt: start)) {
            XCTAssertEqual($0 as? SessionJournalError, .sessionMismatch)
        }
        XCTAssertNil(try journal.load())
    }

    func testWallClockMovingBackDoesNotCorruptKnownOutcome() throws {
        let journal = SessionJournal(url: url)
        let id = UUID()
        let end = start.addingTimeInterval(-3_600)
        try journal.begin(id: id, startedAt: start)
        try journal.finish(id: id, reason: "manual", endedAt: end)
        XCTAssertEqual(try journal.load()?.endedAt, end)
    }

    func testAtomicWritesKeepSessionFileAndNewDirectoryPrivate() throws {
        let journal = SessionJournal(url: url)
        let id = UUID()
        try journal.begin(id: id, startedAt: start)
        try journal.finish(id: id, reason: "quit", endedAt: start.addingTimeInterval(30))
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertNotNil(try SessionJournal(url: url).load())
    }

    func testUnreadableJSONAndEmptyFileAreNotTreatedAsSuccessfulSessions() throws {
        for data in [Data(), Data("not JSON".utf8), Data("{}".utf8)] {
            try write(data)
            let journal = SessionJournal(url: url)
            XCTAssertThrowsError(try journal.load())
            XCTAssertThrowsError(try journal.recoverInterrupted())
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testOversizedJournalIsRejectedBeforeDecoding() throws {
        let data = Data(repeating: 32, count: SessionJournal.maximumFileBytes + 1)
        try write(data)
        XCTAssertThrowsError(try SessionJournal(url: url).load()) {
            XCTAssertEqual($0 as? SessionJournalError, .oversizedFile)
        }
    }

    func testDecoderRejectsContradictoryOrUnsupportedRecords() throws {
        let base: [String: Any] = [
            "version": 1, "id": UUID().uuidString,
            "startedAt": start.timeIntervalSince1970, "state": "active"
        ]
        let invalidChanges: [[String: Any]] = [
            ["version": 2], ["id": "invalid"], ["state": "unknown"],
            ["reason": "manual"], ["endedAt": start.timeIntervalSince1970],
            ["state": "finished"], ["state": "finished", "reason": ""],
            ["state": "finished", "reason": String(repeating: "a", count: 65)],
            ["state": "finished", "reason": "line\nbreak"],
            ["state": "finished", "reason": "interrupted", "endedAt": start.timeIntervalSince1970],
            ["startedAt": 1e100]
        ]
        for changes in invalidChanges {
            let record = base.merging(changes) { _, replacement in replacement }
            try write(JSONSerialization.data(withJSONObject: record))
            XCTAssertThrowsError(try SessionJournal(url: url).load(), "Unexpectedly accepted \(changes)")
        }
    }

    func testInvalidFinishPreservesActiveRecordForHonestRecovery() throws {
        let journal = SessionJournal(url: url)
        let id = UUID()
        try journal.begin(id: id, startedAt: start)
        let original = try journal.load()
        XCTAssertThrowsError(try journal.finish(id: id, reason: "", endedAt: start))
        XCTAssertThrowsError(try journal.finish(id: id, reason: "interrupted", endedAt: start))
        XCTAssertEqual(try journal.load(), original)
        XCTAssertEqual(try journal.recoverInterrupted()?.reason, "interrupted")
    }

    func testMissingTerminalTimestampCannotBecomeARecordedSuccessfulOutcome() throws {
        let journal = SessionJournal(url: url)
        for reason in ["expired", "manual", "unresponsive", "futureSafetyCondition"] {
            let id = UUID()
            try journal.begin(id: id, startedAt: start)
            XCTAssertThrowsError(try journal.finish(id: id, reason: reason, endedAt: nil)) {
                XCTAssertEqual($0 as? SessionJournalError, .invalidRecord)
            }
            XCTAssertEqual(try journal.load()?.state, .active)
            try journal.finish(id: id, reason: reason, endedAt: start.addingTimeInterval(900))
            var corrupted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            corrupted.removeValue(forKey: "endedAt")
            try write(JSONSerialization.data(withJSONObject: corrupted))
            XCTAssertThrowsError(try journal.load()) {
                XCTAssertEqual($0 as? SessionJournalError, .invalidRecord)
            }
            XCTAssertThrowsError(try journal.recoverInterrupted())
            XCTAssertTrue(try journal.quarantineUnreadableRecord())
        }
    }

    func testSymbolicLinkIsNotFollowedOrOverwritten() throws {
        let target = directory.appendingPathComponent("unrelated.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unrelated = Data("private unrelated data".utf8)
        try unrelated.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let journal = SessionJournal(url: url)
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(try journal.begin(id: UUID(), startedAt: start))
        XCTAssertThrowsError(try journal.quarantineUnreadableRecord())
        XCTAssertEqual(try Data(contentsOf: target), unrelated)
    }

    func testCorruptFutureVersionAndOversizedFilesAreQuarantinedBeforeNewSession() throws {
        let unsupported = try JSONSerialization.data(withJSONObject: ["version": 999])
        for data in [Data("not JSON".utf8), unsupported,
                     Data(repeating: 32, count: SessionJournal.maximumFileBytes + 1)] {
            try write(data)
            let journal = SessionJournal(url: url)
            XCTAssertTrue(try journal.quarantineUnreadableRecord())
            XCTAssertNil(try journal.load())
            let quarantines = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                                          includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("session.json.corrupt-") }
            XCTAssertTrue(try quarantines.contains { try Data(contentsOf: $0) == data })
            for quarantine in quarantines {
                let attributes = try FileManager.default.attributesOfItem(atPath: quarantine.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
            let id = UUID()
            try journal.begin(id: id, startedAt: start)
            XCTAssertEqual(try journal.load()?.id, id)
        }
    }

    func testHealthyAndAbsentRecordsAreNeverQuarantined() throws {
        let journal = SessionJournal(url: url)
        XCTAssertFalse(try journal.quarantineUnreadableRecord())
        let id = UUID()
        try journal.begin(id: id, startedAt: start)
        let active = try journal.load()
        XCTAssertFalse(try journal.quarantineUnreadableRecord())
        XCTAssertEqual(try journal.load(), active)
        try journal.finish(id: id, reason: "quit", endedAt: start)
        let finished = try journal.load()
        XCTAssertFalse(try journal.quarantineUnreadableRecord())
        XCTAssertEqual(try journal.load(), finished)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["session.json"])
    }

    func testUnexpectedDirectoryIsNeverQuarantined() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let journal = SessionJournal(url: url)
        XCTAssertThrowsError(try journal.quarantineUnreadableRecord())
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    private func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
