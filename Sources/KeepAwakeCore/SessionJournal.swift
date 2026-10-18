import Foundation
import CryptoKit
import Darwin

/// A single session's outcome. This record is never used to resume a timer.
public struct SessionRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case active, finished
    }

    public let id: UUID
    public let startedAt: Date
    public let state: State
    public let reason: String?
    /// An interrupted process cannot tell us when its session actually stopped.
    public let endedAt: Date?
    /// When an unknown stop was discovered; never presented as the stop instant.
    public let detectedAt: Date?

    private static let schemaVersion = 2
    private enum CodingKeys: String, CodingKey {
        case version, id, startedAt, state, reason, endedAt, detectedAt
    }

    fileprivate init(id: UUID, startedAt: Date, state: State, reason: String?, endedAt: Date?, detectedAt: Date? = nil) throws {
        self.id = id
        self.startedAt = startedAt
        self.state = state
        self.reason = reason
        self.endedAt = endedAt
        self.detectedAt = detectedAt
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == 1 || version == Self.schemaVersion else {
            throw SessionJournalError.unsupportedVersion
        }
        self.id = try values.decode(UUID.self, forKey: .id)
        self.startedAt = try values.decode(Date.self, forKey: .startedAt)
        self.state = try values.decode(State.self, forKey: .state)
        self.reason = try values.decodeIfPresent(String.self, forKey: .reason)
        self.endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        self.detectedAt = try values.decodeIfPresent(Date.self, forKey: .detectedAt)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.schemaVersion, forKey: .version)
        try values.encode(id, forKey: .id)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(state, forKey: .state)
        try values.encodeIfPresent(reason, forKey: .reason)
        try values.encodeIfPresent(endedAt, forKey: .endedAt)
        try values.encodeIfPresent(detectedAt, forKey: .detectedAt)
    }

    private func validate() throws {
        // Allow wall-clock corrections (including an end before the recorded start),
        // but reject non-finite or unusably remote dates from damaged files.
        func validDate(_ date: Date) -> Bool {
            let seconds = date.timeIntervalSince1970
            return seconds.isFinite && abs(seconds) <= 1_000_000_000_000
        }
        guard validDate(startedAt), endedAt.map(validDate) ?? true, detectedAt.map(validDate) ?? true else {
            throw SessionJournalError.invalidRecord
        }
        switch state {
        case .active:
            guard reason == nil, endedAt == nil, detectedAt == nil else { throw SessionJournalError.invalidRecord }
        case .finished:
            guard let reason, !reason.isEmpty, reason.utf8.count <= 64,
                  reason.utf8.allSatisfy({ byte in
                      (65...90).contains(byte) || (97...122).contains(byte) ||
                      (48...57).contains(byte) || byte == 95 || byte == 45
                  }) else {
                throw SessionJournalError.invalidRecord
            }
            if reason == "interrupted" {
                // Version 1 interruption records have neither timestamp.
                guard endedAt == nil else { throw SessionJournalError.invalidRecord }
            } else if endedAt == nil {
                guard reason == "systemSleep", detectedAt != nil else {
                    throw SessionJournalError.invalidRecord
                }
            }
        }
    }
}

public enum SessionJournalError: Error, Equatable {
    case invalidLocation, invalidRecord, unsupportedVersion, oversizedFile
    case sessionAlreadyActive, sessionMismatch
    case encryptionUnavailable, invalidEncryptionKey, authenticationFailed
}

/// A bounded, atomic journal containing only the most recent session.
/// Calls are serialized so the safety monitor and the UI can share one instance.
/// Writes occur at session boundaries; there is no polling or disk heartbeat.
public final class SessionJournal: @unchecked Sendable {
    public static let maximumFileBytes = 16 * 1_024
    public static let quarantineRetentionInterval: TimeInterval = 7 * 24 * 60 * 60
    public static let maximumQuarantineFiles = 3
    private static let maximumQuarantineFileBytes = maximumFileBytes + 128
    private let url: URL
    private let lock = NSLock()
    private let encryptionKeyProvider: ((Bool) throws -> Data)?
    private var hasEncryptedContent = false
    private static let encryptionHeader = Data("CatRunSession.v2\n".utf8)
    private static let authenticatedContext = Data("org.catrun.app.session-journal.v2".utf8)

    /// Production supplies a Keychain-backed 32-byte key. The Boolean reports whether
    /// encrypted data already exists, so a lost key can never be silently replaced.
    /// A nil provider supports the legacy format for migration and isolated tests only.
    public init(url: URL, encryptionKeyProvider: ((Bool) throws -> Data)? = nil) {
        self.url = url
        self.encryptionKeyProvider = encryptionKeyProvider
    }

    public static func isEncryptedData(_ data: Data) -> Bool {
        data.starts(with: encryptionHeader)
    }

    public func load() throws -> SessionRecord? {
        try synchronized { try loadUnlocked() }
    }

    public func begin(id: UUID, startedAt: Date) throws {
        try synchronized {
            if try loadUnlocked()?.state == .active {
                throw SessionJournalError.sessionAlreadyActive
            }
            try writeUnlocked(SessionRecord(id: id, startedAt: startedAt, state: .active,
                                            reason: nil, endedAt: nil))
        }
    }

    /// The first terminal outcome wins. Repeating a finish for that same session is safe;
    /// an older session's callback can never overwrite a newer session's record.
    public func finish(id: UUID, reason: String, endedAt: Date?, detectedAt: Date? = nil) throws {
        try synchronized {
            guard let record = try loadUnlocked(), record.id == id else {
                throw SessionJournalError.sessionMismatch
            }
            guard record.state == .active else { return }
            try writeUnlocked(SessionRecord(id: id, startedAt: record.startedAt, state: .finished,
                                            reason: reason, endedAt: endedAt, detectedAt: detectedAt))
        }
    }

    /// Call once at startup, before accepting a new timer. A leftover active record
    /// means interruption, not successful completion, even if its duration has elapsed.
    @discardableResult
    public func recoverInterrupted(at detectedAt: Date = Date()) throws -> SessionRecord? {
        try synchronized {
            guard let record = try loadUnlocked() else { return nil }
            guard record.state == .active else { return record }
            let recovered = try SessionRecord(id: record.id, startedAt: record.startedAt,
                                              state: .finished, reason: "interrupted", endedAt: nil,
                                              detectedAt: detectedAt)
            try writeUnlocked(recovered)
            return recovered
        }
    }

    /// Preserve a malformed regular file for diagnosis and allow a fresh journal.
    /// A healthy record, a permission failure, or an unexpected filesystem object
    /// is never discarded. Call only after reporting that prior status was unavailable.
    @discardableResult
    public func quarantineUnreadableRecord() throws -> Bool {
        try synchronized {
            do {
                _ = try loadUnlocked()
                return false
            } catch let error as SessionJournalError {
                switch error {
                case .invalidRecord, .unsupportedVersion, .oversizedFile: break
                default: throw error
                }
            } catch is DecodingError {
                // The bounded read succeeded but its contents could not be decoded.
            }
            var currentURL = url
            currentURL.removeAllCachedResourceValues()
            let values = try currentURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SessionJournalError.invalidRecord
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let quarantine = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
            if encryptionKeyProvider != nil, !hasEncryptedContent {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let legacy = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
                guard legacy.count <= Self.maximumFileBytes else { throw SessionJournalError.oversizedFile }
                let encrypted = try encrypt(legacy)
                try encrypted.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try FileManager.default.moveItem(at: url, to: quarantine)
            hasEncryptedContent = false
            return true
        }
    }

    /// Quarantines are never restored or displayed as session records. Keep at most
    /// three for seven days, encrypting old-format copies without extending their age.
    public func pruneQuarantines(now: Date = Date()) throws {
        try synchronized {
            try validateLocation()
            guard now.timeIntervalSince1970.isFinite else { throw SessionJournalError.invalidRecord }
            let directoryURL = url.deletingLastPathComponent()
            let directory = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else {
                if errno == ENOENT { return }
                throw SessionJournalError.invalidLocation
            }
            defer { close(directory) }
            var directoryInfo = stat()
            guard fstat(directory, &directoryInfo) == 0,
                  (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
                  directoryInfo.st_uid == getuid() else { throw SessionJournalError.invalidLocation }
            let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            let prefix = url.lastPathComponent + ".corrupt-"
            var candidates: [(name: String, metadata: stat)] = []
            var firstFailure: Error?
            for name in names where name.hasPrefix(prefix) {
                let suffix = String(name.dropFirst(prefix.count))
                guard let identifier = UUID(uuidString: suffix), identifier.uuidString.lowercased() == suffix.lowercased() else {
                    continue
                }
                var metadata = stat()
                guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                      (metadata.st_mode & S_IFMT) == S_IFREG,
                      metadata.st_nlink == 1, metadata.st_uid == getuid() else {
                    firstFailure = firstFailure ?? SessionJournalError.invalidRecord
                    continue
                }
                candidates.append((name, metadata))
            }
            candidates.sort {
                if $0.metadata.st_mtimespec.tv_sec != $1.metadata.st_mtimespec.tv_sec {
                    return $0.metadata.st_mtimespec.tv_sec > $1.metadata.st_mtimespec.tv_sec
                }
                if $0.metadata.st_mtimespec.tv_nsec != $1.metadata.st_mtimespec.tv_nsec {
                    return $0.metadata.st_mtimespec.tv_nsec > $1.metadata.st_mtimespec.tv_nsec
                }
                return $0.name < $1.name
            }
            var retained: [(name: String, metadata: stat)] = []
            for candidate in candidates {
                let modified = Double(candidate.metadata.st_mtimespec.tv_sec) +
                    Double(candidate.metadata.st_mtimespec.tv_nsec) / 1_000_000_000
                let expired = modified <= now.timeIntervalSince1970 - Self.quarantineRetentionInterval
                if expired || retained.count >= Self.maximumQuarantineFiles {
                    if unlinkat(directory, candidate.name, 0) != 0 {
                        firstFailure = firstFailure ?? SessionJournalError.invalidLocation
                    }
                } else {
                    retained.append(candidate)
                }
            }
            if encryptionKeyProvider != nil {
                // Inspect every retained header before migrating plaintext, so an existing
                // encrypted quarantine also prevents accidental key replacement.
                var stored: [(name: String, metadata: stat, data: Data)] = []
                var existingEncrypted = hasEncryptedContent
                for candidate in retained {
                    do {
                        let data = try readQuarantine(candidate.name, in: directory)
                        existingEncrypted = existingEncrypted || Self.isEncryptedData(data)
                        stored.append((candidate.name, candidate.metadata, data))
                    } catch { firstFailure = firstFailure ?? error }
                }
                for candidate in stored where !Self.isEncryptedData(candidate.data) {
                    do {
                        let encrypted = try encrypt(candidate.data, existingEncryptedContent: existingEncrypted)
                        try replaceQuarantine(candidate.name, in: directory, data: encrypted,
                                              originalTimes: [candidate.metadata.st_atimespec, candidate.metadata.st_mtimespec])
                        existingEncrypted = true
                    } catch { firstFailure = firstFailure ?? error }
                }
            }
            if let firstFailure { throw firstFailure }
        }
    }

    private func readQuarantine(_ name: String, in directory: Int32) throws -> Data {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw SessionJournalError.invalidLocation }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1, metadata.st_uid == getuid() else {
            throw SessionJournalError.invalidRecord
        }
        guard metadata.st_size >= 0, metadata.st_size <= Self.maximumQuarantineFileBytes else {
            throw SessionJournalError.oversizedFile
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw SessionJournalError.invalidLocation }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: Self.maximumQuarantineFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumQuarantineFileBytes,
              Self.isEncryptedData(data) || data.count <= Self.maximumFileBytes else {
            throw SessionJournalError.oversizedFile
        }
        return data
    }

    private func replaceQuarantine(_ name: String, in directory: Int32, data: Data,
                                   originalTimes: [timespec]) throws {
        // An interrupted temporary file has the same bounded retention policy.
        let temporary = url.lastPathComponent + ".corrupt-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SessionJournalError.invalidLocation }
        defer {
            close(descriptor)
            unlinkat(directory, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw SessionJournalError.invalidLocation }
                offset += written
            }
        }
        guard fsync(descriptor) == 0, futimens(descriptor, originalTimes) == 0,
              renameat(directory, temporary, directory, name) == 0 else {
            throw SessionJournalError.invalidLocation
        }
    }

    private func synchronized<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func validateLocation() throws {
        guard url.isFileURL, !url.hasDirectoryPath, url.pathComponents.count > 1 else {
            throw SessionJournalError.invalidLocation
        }
    }

    private func loadUnlocked() throws -> SessionRecord? {
        try validateLocation()
        hasEncryptedContent = false
        let values: URLResourceValues
        do {
            var currentURL = url
            currentURL.removeAllCachedResourceValues()
            values = try currentURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            hasEncryptedContent = false
            return nil
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SessionJournalError.invalidRecord
        }
        guard let size = values.fileSize, size > 0, size <= Self.maximumFileBytes else {
            throw values.fileSize == 0 ? SessionJournalError.invalidRecord : SessionJournalError.oversizedFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Bound the read as well as the metadata check if the file changes between them.
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else { throw SessionJournalError.oversizedFile }
        guard !data.isEmpty else { throw SessionJournalError.invalidRecord }
        hasEncryptedContent = Self.isEncryptedData(data)
        let plaintext: Data
        if hasEncryptedContent {
            guard let encryptionKeyProvider else { throw SessionJournalError.encryptionUnavailable }
            let key = try validatedKey(encryptionKeyProvider(true))
            do {
                let sealed = try AES.GCM.SealedBox(combined: Data(data.dropFirst(Self.encryptionHeader.count)))
                plaintext = try AES.GCM.open(sealed, using: key, authenticating: Self.authenticatedContext)
            } catch {
                // A lost or wrong key is not proof of a corrupt record. Preserve the ciphertext.
                throw SessionJournalError.authenticationFailed
            }
        } else {
            plaintext = data
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(SessionRecord.self, from: plaintext)
        if encryptionKeyProvider != nil, !hasEncryptedContent {
            // Upgrade a validated legacy record in place, without making a plaintext backup.
            try writeUnlocked(record)
        }
        return record
    }

    private func validatedKey(_ data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw SessionJournalError.invalidEncryptionKey }
        return SymmetricKey(data: data)
    }

    private func encrypt(_ plaintext: Data, existingEncryptedContent: Bool? = nil) throws -> Data {
        guard let encryptionKeyProvider else { throw SessionJournalError.encryptionUnavailable }
        let key = try validatedKey(encryptionKeyProvider(existingEncryptedContent ?? hasEncryptedContent))
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.authenticatedContext)
        guard let combined = sealed.combined else { throw SessionJournalError.encryptionUnavailable }
        return Self.encryptionHeader + combined
    }

    private func writeUnlocked(_ record: SessionRecord) throws {
        try validateLocation()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(record)
        let data: Data
        if encryptionKeyProvider == nil {
            data = plaintext
        } else {
            data = try encrypt(plaintext)
        }
        guard data.count <= Self.maximumFileBytes else { throw SessionJournalError.oversizedFile }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        hasEncryptedContent = Self.isEncryptedData(data)
    }
}
