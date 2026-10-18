import Foundation
import XCTest
@testable import KeepAwake

final class AuditKeyVaultTests: XCTestCase {
    func testKeyIsReadOnceAndReusedWithoutKeychainWorkDuringEvents() throws {
        var calls: [Bool] = []
        let key = Data(repeating: 7, count: 32)
        let vault = AuditKeyVault(hasEncryptedData: { false }, readOrCreate: { calls.append($0); return key })
        XCTAssertEqual(try vault.key(existingEncryptedData: false), key)
        XCTAssertEqual(try vault.key(existingEncryptedData: true), key)
        XCTAssertEqual(calls, [true])
    }

    func testCiphertextInEitherConsumerForbidsReplacementKey() throws {
        for (local, other) in [(true, false), (false, true), (true, true)] {
            var creationAllowed: Bool?
            let vault = AuditKeyVault(hasEncryptedData: { other }, readOrCreate: {
                creationAllowed = $0; throw AuditKeyError.missing
            })
            XCTAssertThrowsError(try vault.key(existingEncryptedData: local))
            XCTAssertEqual(creationAllowed, false)
        }
    }

    func testInvalidKeyIsNotCachedOrSilentlyReplaced() throws {
        var calls = 0
        let vault = AuditKeyVault(hasEncryptedData: { true }, readOrCreate: { allowed in
            XCTAssertFalse(allowed); calls += 1; return Data(repeating: 2, count: 16)
        })
        XCTAssertThrowsError(try vault.key(existingEncryptedData: true))
        XCTAssertThrowsError(try vault.key(existingEncryptedData: true))
        XCTAssertEqual(calls, 2)
    }

    func testDataPresenceIncludesQuarantinesAndRejectsUnexpectedLogLocations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(AuditKeyVault.hasEncryptedHistory(in: directory))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = directory.appendingPathComponent("session.json")
        try Data("{\"version\":1}".utf8).write(to: session)
        XCTAssertFalse(AuditKeyVault.hasEncryptedHistory(in: directory))
        let quarantine = directory.appendingPathComponent("session.json.corrupt-fixture")
        try Data("CatRunSession.v2\nopaque ciphertext".utf8).write(to: quarantine)
        XCTAssertTrue(AuditKeyVault.hasEncryptedHistory(in: directory))
        try FileManager.default.removeItem(at: quarantine)
        let logs = directory.appendingPathComponent("Logs")
        try Data("not a directory".utf8).write(to: logs)
        XCTAssertTrue(AuditKeyVault.hasEncryptedHistory(in: directory))
        try FileManager.default.removeItem(at: logs)
        try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: directory)
        XCTAssertTrue(AuditKeyVault.hasEncryptedHistory(in: directory))
    }
}
