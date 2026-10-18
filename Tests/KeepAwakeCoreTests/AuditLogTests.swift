import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import KeepAwakeCore

final class AuditLogTests: XCTestCase {
    private var directory: URL!
    private var instant = Date(timeIntervalSince1970: 1_792_240_000)
    private let key = Data(repeating: 0x79, count: 32)
    private var file: URL { directory.appendingPathComponent(EncryptedAuditLog.fileName) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CatRun-audit-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(provider: ((Bool) throws -> Data)? = nil) -> EncryptedAuditLog {
        EncryptedAuditLog(directoryURL: directory, keyProvider: provider ?? { [key] _ in key }, now: { [unowned self] in self.instant })
    }

    private func event(_ message: String, date: Date? = nil, id: UUID = UUID(),
                       sessionID: UUID? = nil, kind: AuditEventKind = .activity) -> AuditEvent {
        AuditEvent(id: id, date: date ?? instant, message: message, sessionID: sessionID, kind: kind)
    }

    func testFreshReadDoesNotCreateDirectoryOrKey() throws {
        var requests = 0
        let log = store { [key] _ in requests += 1; return key }
        XCTAssertEqual(log.snapshot(), AuditLogSnapshot(events: []))
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRoundTripIsEncryptedAndPreservesKindsAndSessionIdentifiers() throws {
        let runID = UUID(), timerID = UUID()
        let events = [event("App opened.", sessionID: runID, kind: .applicationOpened),
                      event("Timer started for 15m.", sessionID: timerID, kind: .timerStarted),
                      event("Timer stopped · Stopped by you.", sessionID: timerID, kind: .timerStopped)]
        let log = store()
        for entry in events { try log.append(entry) }
        let disk = try Data(contentsOf: file)
        for message in events.map(\.message) {
            XCTAssertNil(disk.range(of: Data(message.utf8)))
        }
        XCTAssertNil(disk.range(of: Data(timerID.uuidString.utf8)))
        XCTAssertEqual(store().load().events, Array(events.reversed()))
        XCTAssertNil(store().load().error)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [EncryptedAuditLog.fileName])
    }

    func testEachWriteUsesANewNonce() throws {
        let log = store(), entry = event("App opened.")
        try log.append(entry)
        let first = try Data(contentsOf: file)
        try log.append(entry)
        XCTAssertNotEqual(first, try Data(contentsOf: file))
        XCTAssertEqual(log.snapshot().events, [entry])
    }

    func testEqualTimesAndClockRollbackPreserveRecordingOrder() throws {
        let log = store()
        let first = event("First activity.")
        let second = event("Second activity.")
        try log.append(first)
        try log.append(second)
        instant = instant.addingTimeInterval(-3_600)
        let third = event("Activity after a clock correction.")
        try log.append(third)
        XCTAssertEqual(store().snapshot().events, [third, second, first])
    }

    func testTamperedCiphertextIsUnavailableAndNeverOverwritten() throws {
        try store().append(event("App opened."))
        var damaged = try Data(contentsOf: file)
        damaged[damaged.count - 1] ^= 0x80
        try damaged.write(to: file)
        let log = store()
        XCTAssertEqual(log.snapshot().error, .corruptedData)
        XCTAssertThrowsError(try log.append(event("New activity.")))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testWrongKeyDoesNotReturnPartialHistoryOrReplaceCiphertext() throws {
        try store().append(event("Timer started."))
        let original = try Data(contentsOf: file)
        let wrong = store { _ in Data(repeating: 0x31, count: 32) }
        XCTAssertEqual(wrong.snapshot(), .init(events: [], error: .corruptedData))
        XCTAssertThrowsError(try wrong.append(event("Timer stopped.")))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testMissingKeyIsNeverRequestedAsFreshWhenHistoryExists() throws {
        try store().append(event("App opened."))
        let original = try Data(contentsOf: file)
        var requests: [Bool] = []
        let log = store { existing in
            requests.append(existing)
            throw AuditLogError.keyUnavailable
        }
        XCTAssertEqual(log.snapshot().error, .keyUnavailable)
        XCTAssertThrowsError(try log.append(event("Timer started.")))
        XCTAssertEqual(requests, [true, true])
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testKeyFailureNeverWritesPlaintextAndCanRecoverWhenUnlocked() throws {
        var unavailable = true
        let log = store { [key] _ in
            if unavailable { throw AuditLogError.keyUnavailable }
            return key
        }
        let entry = event("Timer started.")
        XCTAssertThrowsError(try log.append(entry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        unavailable = false
        try log.append(entry)
        XCTAssertEqual(log.snapshot().events, [entry])
    }

    func testRetentionExpiresAtSevenDaysAndPersistsPruningAcrossRelaunch() throws {
        let log = store()
        let old = event("Old activity.")
        try log.append(old)
        instant = instant.addingTimeInterval(EncryptedAuditLog.retentionInterval - 1)
        let recent = event("Recent activity.")
        try log.append(recent)
        XCTAssertEqual(log.snapshot().events, [recent, old])
        instant = instant.addingTimeInterval(1)
        XCTAssertEqual(log.snapshot().events, [recent])
        XCTAssertEqual(store().snapshot().events, [recent])
        instant = instant.addingTimeInterval(-3_600)
        XCTAssertEqual(store().snapshot().events, [recent], "A backward clock change must not resurrect expired entries")
    }

    func testAuthenticatedRetentionReferenceSurvivesClockRollback() throws {
        let log = store()
        let originalDate = instant
        try log.append(event("First activity."))
        instant = instant.addingTimeInterval(3 * 24 * 3_600)
        try log.append(event("Later activity."))
        instant = originalDate
        let tooOld = event("Outdated activity.", date: originalDate.addingTimeInterval(-5 * 24 * 3_600))
        try store().append(tooOld)
        XCTAssertFalse(store().snapshot().events.contains(tooOld))
    }

    func testUnreadableHistoryIsPreservedThenExpiresWithoutSilentlyStartingOver() throws {
        try store().append(event("App opened."))
        try FileManager.default.setAttributes([.modificationDate: instant], ofItemAtPath: file.path)
        let log = store { _ in throw AuditLogError.keyUnavailable }
        XCTAssertEqual(log.snapshot().error, .keyUnavailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        instant = instant.addingTimeInterval(EncryptedAuditLog.retentionInterval)
        XCTAssertEqual(log.snapshot().error, .expiredUnreadableHistory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try log.append(event("New activity.")))
        XCTAssertEqual(log.snapshot().error, .expiredUnreadableHistory)
        XCTAssertNil(store().snapshot().error, "The next app launch can begin a new encrypted history")
    }

    func testMalformedAndOversizedFilesAreBoundedAndPreservedUntilExpiry() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for contents in [Data(), Data("not an encrypted log".utf8), Data(repeating: 0, count: EncryptedAuditLog.maximumFileBytes + 1)] {
            try contents.write(to: file)
            let expected: AuditLogError = contents.count > EncryptedAuditLog.maximumFileBytes ? .oversizedData : .corruptedData
            XCTAssertEqual(store().snapshot().error, expected)
            XCTAssertEqual(try Data(contentsOf: file), contents)
        }
        try FileManager.default.setAttributes([.modificationDate: instant.addingTimeInterval(-EncryptedAuditLog.retentionInterval)], ofItemAtPath: file.path)
        XCTAssertEqual(store().snapshot().error, .expiredUnreadableHistory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDirectoryAndFilesArePrivateAndOrphanCiphertextIsRemoved() throws {
        try store().append(event("App opened."))
        let orphan = directory.appendingPathComponent(".audit-abandoned.tmp")
        try Data([1, 2, 3]).write(to: orphan)
        _ = store().snapshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSymlinkHardLinkAndUnexpectedFileTypesAreRejected() throws {
        let external = directory.appendingPathExtension("external")
        defer { try? FileManager.default.removeItem(at: external) }
        try Data("untouched".utf8).write(to: external)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        XCTAssertEqual(store().snapshot().error, .invalidLocation)
        XCTAssertThrowsError(try store().append(event("Activity.")))
        XCTAssertEqual(try Data(contentsOf: external), Data("untouched".utf8))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: external, to: file)
        XCTAssertEqual(store().snapshot().error, .invalidLocation)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertEqual(store().snapshot().error, .invalidLocation)
    }

    func testDirectorySymlinkIsRejectedWithoutChangingItsTarget() throws {
        let target = directory.appendingPathExtension("target")
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        XCTAssertEqual(store().snapshot().error, .invalidLocation)
        XCTAssertThrowsError(try store().append(event("Activity.")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testUnsafeMessagesAndDatesCannotReachDisk() throws {
        let log = store()
        for message in ["", "   ", "First line\nSecond line", "Null\0character", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try log.append(event(message))) {
                XCTAssertEqual($0 as? AuditLogError, .invalidEvent)
            }
        }
        XCTAssertThrowsError(try log.append(event("Activity.", date: Date(timeIntervalSince1970: .infinity))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testEventLimitDropsOldestRecordedEntries() throws {
        let events = (0..<EncryptedAuditLog.maximumEvents).map { event("Activity \($0).") }
        try writeAuthenticatedFixture(events: events)
        let latest = event("Newest activity.")
        try store().append(latest)
        let snapshot = store().snapshot()
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.events.count, EncryptedAuditLog.maximumEvents)
        XCTAssertEqual(snapshot.events.first, latest)
        XCTAssertEqual(snapshot.events.last, events[events.count - 2])
        XCTAssertFalse(snapshot.events.contains(events.last!))
        XCTAssertLessThan(try Data(contentsOf: file).count, EncryptedAuditLog.maximumFileBytes)
    }

    func testAuthenticatedMalformedPayloadStillFailsValidation() throws {
        try writeAuthenticatedFixture(events: [event("Safe message.")], version: 2)
        XCTAssertEqual(store().snapshot().error, .unsupportedVersion)
        let duplicate = event("Duplicated activity.")
        try writeAuthenticatedFixture(events: [duplicate, duplicate])
        XCTAssertEqual(store().snapshot().error, .corruptedData)
        try writeAuthenticatedFixture(events: [event("Message with\ncontrol text.")])
        XCTAssertEqual(store().snapshot().error, .invalidEvent)
    }


    func testConcurrentDeliveryIsSerializedWithoutLostOrDuplicateEvents() throws {
        let log = store()
        let entries = (0..<24).map { event("Concurrent activity \($0).") }
        let failures = NSLock()
        var failedWrites = 0
        DispatchQueue.concurrentPerform(iterations: entries.count) { index in
            do { try log.append(entries[index]) }
            catch {
                failures.lock()
                failedWrites += 1
                failures.unlock()
            }
        }
        let snapshot = log.snapshot()
        XCTAssertEqual(failedWrites, 0)
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(Set(snapshot.events.map(\.id)), Set(entries.map(\.id)))
        XCTAssertEqual(snapshot.events.count, entries.count)
    }

    /// Construct authenticated fixtures to exercise read validation and capacity without
    /// thousands of unrelated disk writes. This is the on-disk version-one contract.
    private func writeAuthenticatedFixture(events: [AuditEvent], version: Int = 1) throws {
        struct Fixture: Encodable { let version: Int; let retentionReference: Date; let events: [AuditEvent] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let plaintext = try encoder.encode(Fixture(version: version, retentionReference: instant, events: events))
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                      authenticating: Data("Cat Run local activity log, version 1".utf8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (Data("CATRUNLOG1\0".utf8) + XCTUnwrap(sealed.combined)).write(to: file)
    }
}
