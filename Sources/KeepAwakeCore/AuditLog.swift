import CryptoKit
import Darwin
import Foundation

public enum AuditEventKind: String, Codable, Sendable {
    case applicationOpened, applicationClosed, applicationInterrupted
    case timerStarted, timerStopped, activity
}

/// App-owned descriptions only. No paths, user names, or device identifiers are collected.
public struct AuditEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let message: String
    public let sessionID: UUID?
    public let kind: AuditEventKind

    public init(id: UUID = UUID(), date: Date, message: String, sessionID: UUID? = nil,
                kind: AuditEventKind = .activity) {
        self.id = id
        self.date = date
        self.message = message
        self.sessionID = sessionID
        self.kind = kind
    }
}

public enum AuditLogError: Error, Equatable, Sendable {
    case invalidLocation, invalidEvent, unsupportedVersion, oversizedData
    case keyUnavailable, corruptedData, storageUnavailable, expiredUnreadableHistory

    public var message: String {
        switch self {
        case .keyUnavailable:
            return "Logs unavailable. The encryption key could not be accessed."
        case .corruptedData, .unsupportedVersion:
            return "Logs unavailable. The saved history could not be verified."
        case .expiredUnreadableHistory:
            return "Older unreadable logs expired and were removed. Reopen Cat Run to resume logging."
        case .invalidEvent:
            return "Logs unavailable. An activity could not be recorded."
        case .invalidLocation, .oversizedData, .storageUnavailable:
            return "Logs unavailable. The saved history could not be accessed safely."
        }
    }
}

public struct AuditLogSnapshot: Equatable, Sendable {
    /// In recording order, most recently recorded first, even after a clock correction.
    public let events: [AuditEvent]
    public let error: AuditLogError?
    public var isAvailable: Bool { error == nil }

    public init(events: [AuditEvent], error: AuditLogError? = nil) {
        self.events = events
        self.error = error
    }
}

/// A small authenticated local history. The native caller runs this synchronous store
/// on its own queue, so Keychain and disk access never delay timer safety handling.
public final class EncryptedAuditLog: @unchecked Sendable {
    public static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    public static let maximumEvents = 4_000
    public static let maximumFileBytes = 2 * 1_024 * 1_024
    public static let maximumMessageBytes = 256
    public static let fileName = "activity.encrypted"

    private struct Envelope: Codable {
        var version: Int = 1
        var retentionReference: Date
        var events: [AuditEvent]
    }

    private struct StoredFile {
        let data: Data
        let modifiedAt: Date
    }

    private static let header = Data("CATRUNLOG1\0".utf8)
    private static let authentication = Data("Cat Run local activity log, version 1".utf8)
    private let directoryURL: URL
    private let keyProvider: (Bool) throws -> Data
    private let now: () -> Date
    private let lock = NSLock()
    private var stickyError: AuditLogError?

    /// The provider receives true whenever ciphertext already exists. It must not
    /// create a replacement key in that case; a missing key makes history unavailable.
    public init(directoryURL: URL, keyProvider: @escaping (Bool) throws -> Data,
                now: @escaping () -> Date = Date.init) {
        self.directoryURL = directoryURL
        self.keyProvider = keyProvider
        self.now = now
    }

    public func load() -> AuditLogSnapshot { snapshot() }

    public func snapshot() -> AuditLogSnapshot {
        synchronized {
            guard stickyError == nil else { return .init(events: [], error: stickyError) }
            do {
                let instant = now()
                try validateDate(instant)
                guard let directory = try openDirectory(create: false) else { return .init(events: []) }
                defer { close(directory) }
                try cleanTemporaryFiles(in: directory)
                let stored = try readFile(in: directory, now: instant)
                guard let stored else { return .init(events: []) }
                var envelope = try decode(stored, in: directory, now: instant)
                let before = envelope.events
                prune(&envelope, now: instant)
                // A read only writes when retention actually removes an entry.
                if before != envelope.events {
                    try persist(envelope, in: directory, existingData: true)
                }
                return .init(events: envelope.events)
            } catch {
                return .init(events: [], error: normalized(error))
            }
        }
    }

    public func append(_ event: AuditEvent) throws {
        try synchronized {
            if let stickyError { throw stickyError }
            try validate(event)
            let instant = now()
            try validateDate(instant)
            guard let directory = try openDirectory(create: true) else { throw AuditLogError.invalidLocation }
            defer { close(directory) }
            try cleanTemporaryFiles(in: directory)
            let stored = try readFile(in: directory, now: instant)
            var envelope = try stored.map { try decode($0, in: directory, now: instant) }
                ?? Envelope(retentionReference: instant, events: [])
            prune(&envelope, now: instant)
            // Retried delivery of the same event must not create a duplicate entry.
            if !envelope.events.contains(where: { $0.id == event.id }) {
                envelope.events.insert(event, at: 0)
            }
            prune(&envelope, now: instant)
            try persist(envelope, in: directory, existingData: stored != nil)
        }
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func normalized(_ error: Error) -> AuditLogError {
        error as? AuditLogError ?? .storageUnavailable
    }

    private func validateDate(_ date: Date) throws {
        let value = date.timeIntervalSince1970
        guard value.isFinite, abs(value) <= 1_000_000_000_000 else { throw AuditLogError.invalidEvent }
    }

    private func validate(_ event: AuditEvent) throws {
        try validateDate(event.date)
        guard !event.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              event.message.utf8.count <= Self.maximumMessageBytes,
              !event.message.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AuditLogError.invalidEvent
        }
    }

    private func prune(_ envelope: inout Envelope, now: Date) {
        envelope.retentionReference = max(envelope.retentionReference, now)
        let oldest = envelope.retentionReference.addingTimeInterval(-Self.retentionInterval)
        envelope.events.removeAll { $0.date <= oldest }
        if envelope.events.count > Self.maximumEvents {
            envelope.events.removeLast(envelope.events.count - Self.maximumEvents)
        }
    }

    private func key(existingData: Bool) throws -> SymmetricKey {
        do {
            let data = try keyProvider(existingData)
            guard data.count == 32 else { throw AuditLogError.keyUnavailable }
            return SymmetricKey(data: data)
        } catch {
            throw AuditLogError.keyUnavailable
        }
    }

    private func decode(_ stored: StoredFile, in directory: Int32, now: Date) throws -> Envelope {
        do {
            guard stored.data.starts(with: Self.header) else { throw AuditLogError.corruptedData }
            let symmetricKey = try key(existingData: true)
            let payload = stored.data.dropFirst(Self.header.count)
            let box = try AES.GCM.SealedBox(combined: payload)
            let plaintext = try AES.GCM.open(box, using: symmetricKey, authenticating: Self.authentication)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let envelope = try decoder.decode(Envelope.self, from: plaintext)
            guard envelope.version == 1 else { throw AuditLogError.unsupportedVersion }
            try validateDate(envelope.retentionReference)
            guard envelope.events.count <= Self.maximumEvents else { throw AuditLogError.oversizedData }
            var identifiers = Set<UUID>()
            for event in envelope.events {
                try validate(event)
                guard identifiers.insert(event.id).inserted else { throw AuditLogError.corruptedData }
            }
            return envelope
        } catch {
            // Unreadable ciphertext is preserved for key recovery, but it does not
            // become an indefinite archive. Its age is all we can inspect safely.
            if stored.modifiedAt <= now.addingTimeInterval(-Self.retentionInterval) {
                guard unlinkat(directory, Self.fileName, 0) == 0 else { throw AuditLogError.storageUnavailable }
                stickyError = .expiredUnreadableHistory
                throw AuditLogError.expiredUnreadableHistory
            }
            if let error = error as? AuditLogError { throw error }
            throw AuditLogError.corruptedData
        }
    }

    private func persist(_ envelope: Envelope, in directory: Int32, existingData: Bool) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(envelope)
        guard plaintext.count < Self.maximumFileBytes - 128 else { throw AuditLogError.oversizedData }
        let box = try AES.GCM.seal(plaintext, using: key(existingData: existingData), authenticating: Self.authentication)
        guard let combined = box.combined else { throw AuditLogError.storageUnavailable }
        let ciphertext = Self.header + combined
        guard ciphertext.count <= Self.maximumFileBytes else { throw AuditLogError.oversizedData }
        let temporary = ".audit-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AuditLogError.storageUnavailable }
        defer {
            close(descriptor)
            unlinkat(directory, temporary, 0)
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw AuditLogError.storageUnavailable }
        try ciphertext.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw AuditLogError.storageUnavailable }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AuditLogError.storageUnavailable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              renameat(directory, temporary, directory, Self.fileName) == 0 else {
            throw AuditLogError.storageUnavailable
        }
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        guard directoryURL.isFileURL, directoryURL.pathComponents.count > 1 else {
            throw AuditLogError.invalidLocation
        }
        var metadata = stat()
        if lstat(directoryURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw AuditLogError.invalidLocation }
            if !create { return nil }
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch { throw AuditLogError.storageUnavailable }
        }
        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AuditLogError.invalidLocation }
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              fchmod(descriptor, 0o700) == 0 else {
            close(descriptor)
            throw AuditLogError.invalidLocation
        }
        return descriptor
    }

    private func readFile(in directory: Int32, now: Date) throws -> StoredFile? {
        let descriptor = openat(directory, Self.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AuditLogError.invalidLocation
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1, metadata.st_uid == getuid() else {
            throw AuditLogError.invalidLocation
        }
        let modified = Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000)
        guard metadata.st_size >= 0, metadata.st_size <= Self.maximumFileBytes else {
            if modified <= now.addingTimeInterval(-Self.retentionInterval) {
                guard unlinkat(directory, Self.fileName, 0) == 0 else { throw AuditLogError.storageUnavailable }
                stickyError = .expiredUnreadableHistory
                throw AuditLogError.expiredUnreadableHistory
            }
            throw AuditLogError.oversizedData
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw AuditLogError.storageUnavailable }
        var data = Data(count: Int(metadata.st_size))
        try data.withUnsafeMutableBytes { raw in
            guard raw.count > 0, let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.read(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AuditLogError.storageUnavailable }
                offset += count
            }
        }
        // Detect growth between metadata inspection and reading without unbounded allocation.
        var extra: UInt8 = 0
        guard Darwin.read(descriptor, &extra, 1) == 0 else { throw AuditLogError.oversizedData }
        return StoredFile(data: data, modifiedAt: modified)
    }

    private func cleanTemporaryFiles(in directory: Int32) throws {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path) }
        catch { throw AuditLogError.storageUnavailable }
        // Only the committed history and ciphertext from an interrupted atomic write
        // belong here. Never follow a link or touch unrelated application files.
        guard names.count <= 32 else { throw AuditLogError.invalidLocation }
        for name in names where name != Self.fileName {
            guard name.hasPrefix(".audit-"), name.hasSuffix(".tmp") else { throw AuditLogError.invalidLocation }
            var metadata = stat()
            guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_nlink == 1,
                  metadata.st_uid == getuid() else { throw AuditLogError.invalidLocation }
            guard unlinkat(directory, name, 0) == 0 else { throw AuditLogError.storageUnavailable }
        }
    }
}
