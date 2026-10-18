import Foundation
import CryptoKit
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

        let detected = start.addingTimeInterval(3_600)
        let recovered = try XCTUnwrap(relaunched.recoverInterrupted(at: detected))
        XCTAssertEqual(recovered.id, id)
        XCTAssertEqual(recovered.state, .finished)
        XCTAssertEqual(recovered.reason, "interrupted")
        XCTAssertNil(recovered.endedAt)
        XCTAssertEqual(recovered.detectedAt, detected)
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
            ["version": 3], ["id": "invalid"], ["state": "unknown"],
            ["reason": "manual"], ["endedAt": start.timeIntervalSince1970],
            ["detectedAt": start.timeIntervalSince1970],
            ["state": "finished", "reason": "systemSleep"],
            ["state": "finished", "reason": "systemSleep", "detectedAt": 1e100],
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

    func testMissedSleepRecordsDetectionWithoutInventingStopTime() throws {
        let journal = SessionJournal(url: url)
        let id = UUID()
        let detected = start.addingTimeInterval(10_800)
        try journal.begin(id: id, startedAt: start)
        try journal.finish(id: id, reason: "systemSleep", endedAt: nil, detectedAt: detected)
        let record = try XCTUnwrap(journal.load())
        XCTAssertEqual(record.reason, "systemSleep")
        XCTAssertNil(record.endedAt)
        XCTAssertEqual(record.detectedAt, detected)
        XCTAssertEqual(try SessionJournal(url: url).recoverInterrupted(at: detected.addingTimeInterval(60)), record)
    }

    func testDetectionTimeCannotReplaceKnownSafetyOrCompletionOutcomeTime() throws {
        let journal = SessionJournal(url: url)
        let id = UUID()
        try journal.begin(id: id, startedAt: start)
        for reason in ["expired", "manual", "lowBattery", "shutdown", "futureSafetyCondition"] {
            XCTAssertThrowsError(try journal.finish(id: id, reason: reason, endedAt: nil, detectedAt: start)) {
                XCTAssertEqual($0 as? SessionJournalError, .invalidRecord)
            }
        }
        XCTAssertEqual(try journal.load()?.state, .active)
    }

    func testEncryptedJournalRoundTripsWithoutPlaintextFieldsAndUsesFreshNonces() throws {
        let key = Data(repeating: 71, count: 32)
        var existingFlags: [Bool] = []
        let journal = SessionJournal(url: url) { encryptedExists in
            existingFlags.append(encryptedExists)
            return key
        }
        let id = UUID()
        try journal.begin(id: id, startedAt: start)
        let first = try Data(contentsOf: url)
        XCTAssertTrue(SessionJournal.isEncryptedData(first))
        for secret in [id.uuidString, "startedAt", "active", "endedAt"] {
            XCTAssertNil(first.range(of: Data(secret.utf8)))
        }
        XCTAssertEqual(existingFlags.first, false)
        XCTAssertEqual(try journal.load()?.id, id)
        XCTAssertEqual(existingFlags.last, true)
        try journal.finish(id: id, reason: "manual", endedAt: start.addingTimeInterval(60))
        XCTAssertEqual(try SessionJournal(url: url, encryptionKeyProvider: { _ in key }).load()?.reason, "manual")
        XCTAssertThrowsError(try SessionJournal(url: url).load()) {
            XCTAssertEqual($0 as? SessionJournalError, .encryptionUnavailable)
        }
        let secondURL = directory.appendingPathComponent("second.json")
        try SessionJournal(url: secondURL, encryptionKeyProvider: { _ in key }).begin(id: id, startedAt: start)
        XCTAssertNotEqual(first, try Data(contentsOf: secondURL), "Identical records must use independent encryption nonces")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLegacyJournalMigratesInPlaceWithoutPlaintextBackup() throws {
        let id = UUID()
        let legacy: [String: Any] = [
            "version": 1, "id": id.uuidString, "startedAt": start.timeIntervalSince1970,
            "state": "finished", "reason": "manual", "endedAt": start.addingTimeInterval(60).timeIntervalSince1970
        ]
        try write(JSONSerialization.data(withJSONObject: legacy))
        let key = Data(repeating: 72, count: 32)
        var flags: [Bool] = []
        let journal = SessionJournal(url: url) { existing in flags.append(existing); return key }
        let record = try XCTUnwrap(journal.load())
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.reason, "manual")
        XCTAssertNil(record.detectedAt)
        let migrated = try Data(contentsOf: url)
        XCTAssertTrue(SessionJournal.isEncryptedData(migrated))
        XCTAssertNil(migrated.range(of: Data(id.uuidString.utf8)))
        XCTAssertEqual(flags, [false])
        XCTAssertEqual(try journal.load(), record)
        XCTAssertEqual(try Data(contentsOf: url), migrated, "An ordinary read must not rewrite ciphertext")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["session.json"])
    }

    func testLostKeyNeverReplacesEncryptedJournalOrCreatesPlaintext() throws {
        let key = Data(repeating: 73, count: 32)
        try SessionJournal(url: url, encryptionKeyProvider: { _ in key }).begin(id: UUID(), startedAt: start)
        let original = try Data(contentsOf: url)
        let unavailable = SessionJournal(url: url) { existing in
            XCTAssertTrue(existing)
            throw TestKeyError.unavailable
        }
        XCTAssertThrowsError(try unavailable.load())
        XCTAssertThrowsError(try unavailable.recoverInterrupted())
        XCTAssertThrowsError(try unavailable.quarantineUnreadableRecord())
        XCTAssertThrowsError(try unavailable.begin(id: UUID(), startedAt: start))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["session.json"])
    }

    func testWrongKeyOrTamperedCiphertextIsPreservedForRecovery() throws {
        let key = Data(repeating: 74, count: 32)
        try SessionJournal(url: url, encryptionKeyProvider: { _ in key }).begin(id: UUID(), startedAt: start)
        let original = try Data(contentsOf: url)
        let wrongKey = SessionJournal(url: url, encryptionKeyProvider: { _ in Data(repeating: 75, count: 32) })
        XCTAssertThrowsError(try wrongKey.load()) {
            XCTAssertEqual($0 as? SessionJournalError, .authenticationFailed)
        }
        XCTAssertThrowsError(try wrongKey.quarantineUnreadableRecord()) {
            XCTAssertEqual($0 as? SessionJournalError, .authenticationFailed)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        var tampered = original
        tampered[tampered.count - 1] ^= 1
        try write(tampered)
        let originalKey = SessionJournal(url: url, encryptionKeyProvider: { _ in key })
        XCTAssertThrowsError(try originalKey.load()) {
            XCTAssertEqual($0 as? SessionJournalError, .authenticationFailed)
        }
        XCTAssertThrowsError(try originalKey.quarantineUnreadableRecord())
        XCTAssertEqual(try Data(contentsOf: url), tampered)
    }

    func testKeyFailureAndInvalidKeyNeverCreateAnUnencryptedNewJournal() throws {
        let unavailable = SessionJournal(url: url) { _ in throw TestKeyError.unavailable }
        XCTAssertThrowsError(try unavailable.begin(id: UUID(), startedAt: start))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        for length in [0, 16, 31, 33] {
            let invalid = SessionJournal(url: url, encryptionKeyProvider: { _ in Data(repeating: 1, count: length) })
            XCTAssertThrowsError(try invalid.begin(id: UUID(), startedAt: start)) {
                XCTAssertEqual($0 as? SessionJournalError, .invalidEncryptionKey)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testMigrationKeyFailurePreservesLegacyRecordWithoutCopyingIt() throws {
        try SessionJournal(url: url).begin(id: UUID(), startedAt: start)
        let original = try Data(contentsOf: url)
        let journal = SessionJournal(url: url) { _ in throw TestKeyError.unavailable }
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(try journal.quarantineUnreadableRecord())
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["session.json"])
    }

    func testQuarantineEncryptsMalformedLegacyBytesBeforePreservingThem() throws {
        let original = Data("not JSON but potentially private".utf8)
        try write(original)
        let key = Data(repeating: 76, count: 32)
        let journal = SessionJournal(url: url, encryptionKeyProvider: { _ in key })
        XCTAssertTrue(try journal.quarantineUnreadableRecord())
        let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let encrypted = try Data(contentsOf: XCTUnwrap(files.first))
        XCTAssertTrue(SessionJournal.isEncryptedData(encrypted))
        XCTAssertNil(encrypted.range(of: original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try journal.begin(id: UUID(), startedAt: start)
        XCTAssertTrue(SessionJournal.isEncryptedData(try Data(contentsOf: url)))
    }

    func testAuthenticatedMalformedRecordIsQuarantinedAsCiphertext() throws {
        let key = Data(repeating: 78, count: 32)
        let sealed = try AES.GCM.seal(Data("{broken".utf8), using: SymmetricKey(data: key),
                                      authenticating: Data("org.catrun.app.session-journal.v2".utf8))
        let ciphertext = Data("CatRunSession.v2\n".utf8) + (try XCTUnwrap(sealed.combined))
        try write(ciphertext)
        let journal = SessionJournal(url: url, encryptionKeyProvider: { _ in key })
        XCTAssertTrue(try journal.quarantineUnreadableRecord())
        let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), ciphertext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCiphertextFromAnotherContextCannotBecomeASession() throws {
        let key = Data(repeating: 77, count: 32)
        let sealed = try AES.GCM.seal(Data("{}".utf8), using: SymmetricKey(data: key),
                                      authenticating: Data("another-log-type".utf8))
        let ciphertext = Data("CatRunSession.v2\n".utf8) + (try XCTUnwrap(sealed.combined))
        try write(ciphertext)
        let journal = SessionJournal(url: url, encryptionKeyProvider: { _ in key })
        XCTAssertThrowsError(try journal.load()) {
            XCTAssertEqual($0 as? SessionJournalError, .authenticationFailed)
        }
        XCTAssertEqual(try Data(contentsOf: url), ciphertext)
    }

    func testQuarantinePruningRemovesExpiredPlaintextAndCiphertextBeforeAccessingKey() throws {
        let old = start.addingTimeInterval(-SessionJournal.quarantineRetentionInterval - 1)
        let plaintext = try makeQuarantine(data: Data("legacy private bytes".utf8), modifiedAt: old)
        let ciphertext = try makeQuarantine(data: Data("CatRunSession.v2\nopaque cipher".utf8), modifiedAt: old)
        let journal = SessionJournal(url: url) { _ in
            XCTFail("Expired quarantines must be deleted without needing their key")
            throw TestKeyError.unavailable
        }
        try journal.pruneQuarantines(now: start)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plaintext.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ciphertext.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecentLegacyQuarantineIsEncryptedWithoutResettingRetentionAge() throws {
        let key = Data(repeating: 81, count: 32)
        let original = Data("malformed legacy private session".utf8)
        let modified = start.addingTimeInterval(-86_400)
        let quarantine = try makeQuarantine(data: original, modifiedAt: modified)
        let journal = SessionJournal(url: url, encryptionKeyProvider: { _ in key })
        try journal.pruneQuarantines(now: start)
        let ciphertext = try Data(contentsOf: quarantine)
        XCTAssertTrue(SessionJournal.isEncryptedData(ciphertext))
        XCTAssertNil(ciphertext.range(of: original))
        let box = try AES.GCM.SealedBox(combined: Data(ciphertext.dropFirst(Data("CatRunSession.v2\n".utf8).count)))
        XCTAssertEqual(try AES.GCM.open(box, using: SymmetricKey(data: key),
                                        authenticating: Data("org.catrun.app.session-journal.v2".utf8)), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: quarantine.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, modified)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path),
                       [quarantine.lastPathComponent])
        try journal.pruneQuarantines(now: modified.addingTimeInterval(SessionJournal.quarantineRetentionInterval + 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
    }

    func testQuarantineRetentionKeepsOnlyTheThreeNewestCopies() throws {
        var quarantines: [URL] = []
        for index in 0..<6 {
            quarantines.append(try makeQuarantine(data: Data("sample \(index)".utf8),
                                                   modifiedAt: start.addingTimeInterval(-Double(index * 60))))
        }
        try SessionJournal(url: url).pruneQuarantines(now: start)
        for (index, quarantine) in quarantines.enumerated() {
            XCTAssertEqual(FileManager.default.fileExists(atPath: quarantine.path), index < 3)
        }
    }

    func testQuarantinePruningLeavesCurrentRecordAndForeignNamesUntouched() throws {
        try SessionJournal(url: url).begin(id: UUID(), startedAt: start)
        let current = try Data(contentsOf: url)
        let parent = url.deletingLastPathComponent()
        let foreignNames = ["notes.txt", "session.json.corrupt-not-a-uuid", "other.json.corrupt-\(UUID().uuidString)",
                            "session.json.corrupt-\(UUID().uuidString).backup"]
        for name in foreignNames {
            let file = parent.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-1_000_000)],
                                                  ofItemAtPath: file.path)
        }
        try SessionJournal(url: url).pruneQuarantines(now: start)
        XCTAssertEqual(try Data(contentsOf: url), current)
        for name in foreignNames {
            XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent(name)), Data(name.utf8))
        }
    }

    func testQuarantinePruningRejectsSymlinksAndDirectoriesWithoutFollowingThem() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("unrelated.txt")
        let original = Data("unrelated private data".utf8)
        try original.write(to: target)
        let link = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let subdirectory = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let old = try makeQuarantine(data: Data("old".utf8), modifiedAt: start.addingTimeInterval(-1_000_000))
        XCTAssertThrowsError(try SessionJournal(url: url).pruneQuarantines(now: start)) {
            XCTAssertEqual($0 as? SessionJournalError, .invalidRecord)
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertTrue(try subdirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testQuarantineMigrationDoesNotReplaceMissingKeyWhenAnotherCiphertextExists() throws {
        let original = Data("old plaintext".utf8)
        let legacy = try makeQuarantine(data: original, modifiedAt: start)
        let ciphertext = try makeQuarantine(data: Data("CatRunSession.v2\nexisting cipher".utf8),
                                            modifiedAt: start.addingTimeInterval(-1))
        let journal = SessionJournal(url: url) { existing in
            XCTAssertTrue(existing, "A retained encrypted quarantine must prevent key regeneration")
            throw TestKeyError.unavailable
        }
        XCTAssertThrowsError(try journal.pruneQuarantines(now: start))
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ciphertext.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count, 2)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: legacy.path)[.posixPermissions] as? NSNumber)?.intValue,
                       0o600)
    }

    func testQuarantinePruningRejectsOversizedRecentCopyButDeletesExpiredOversizedCopy() throws {
        let huge = Data(repeating: 42, count: SessionJournal.maximumFileBytes + 1)
        let recent = try makeQuarantine(data: huge, modifiedAt: start)
        let old = try makeQuarantine(data: huge, modifiedAt: start.addingTimeInterval(-1_000_000))
        let journal = SessionJournal(url: url, encryptionKeyProvider: { _ in Data(repeating: 82, count: 32) })
        XCTAssertThrowsError(try journal.pruneQuarantines(now: start)) {
            XCTAssertEqual($0 as? SessionJournalError, .oversizedFile)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try Data(contentsOf: recent), huge)
    }

    func testQuarantineMaintenanceDoesNotCreateAbsentDirectory() throws {
        try SessionJournal(url: url).pruneQuarantines(now: start)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeQuarantine(data: Data, modifiedAt: Date) throws -> URL {
        let quarantine = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: quarantine)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: quarantine.path)
        return quarantine
    }

    private enum TestKeyError: Error { case unavailable }

    private func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
