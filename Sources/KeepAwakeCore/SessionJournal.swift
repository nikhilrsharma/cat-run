import Foundation

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

    private static let schemaVersion = 1
    private enum CodingKeys: String, CodingKey {
        case version, id, startedAt, state, reason, endedAt
    }

    fileprivate init(id: UUID, startedAt: Date, state: State, reason: String?, endedAt: Date?) throws {
        self.id = id
        self.startedAt = startedAt
        self.state = state
        self.reason = reason
        self.endedAt = endedAt
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.schemaVersion else {
            throw SessionJournalError.unsupportedVersion
        }
        self.id = try values.decode(UUID.self, forKey: .id)
        self.startedAt = try values.decode(Date.self, forKey: .startedAt)
        self.state = try values.decode(State.self, forKey: .state)
        self.reason = try values.decodeIfPresent(String.self, forKey: .reason)
        self.endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
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
    }

    private func validate() throws {
        // Allow wall-clock corrections (including an end before the recorded start),
        // but reject non-finite or unusably remote dates from damaged files.
        func validDate(_ date: Date) -> Bool {
            let seconds = date.timeIntervalSince1970
            return seconds.isFinite && abs(seconds) <= 1_000_000_000_000
        }
        guard validDate(startedAt), endedAt.map(validDate) ?? true else {
            throw SessionJournalError.invalidRecord
        }
        switch state {
        case .active:
            guard reason == nil, endedAt == nil else { throw SessionJournalError.invalidRecord }
        case .finished:
            guard let reason, !reason.isEmpty, reason.utf8.count <= 64,
                  reason.utf8.allSatisfy({ byte in
                      (65...90).contains(byte) || (97...122).contains(byte) ||
                      (48...57).contains(byte) || byte == 95 || byte == 45
                  }), (reason == "interrupted" ? endedAt == nil : endedAt != nil) else {
                throw SessionJournalError.invalidRecord
            }
        }
    }
}

public enum SessionJournalError: Error, Equatable {
    case invalidLocation, invalidRecord, unsupportedVersion, oversizedFile
    case sessionAlreadyActive, sessionMismatch
}

/// A bounded, atomic journal containing only the most recent session.
/// Calls are serialized so the safety monitor and the UI can share one instance.
/// Writes occur at session boundaries; there is no polling or disk heartbeat.
public final class SessionJournal: @unchecked Sendable {
    public static let maximumFileBytes = 16 * 1_024
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
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
    public func finish(id: UUID, reason: String, endedAt: Date?) throws {
        try synchronized {
            guard let record = try loadUnlocked(), record.id == id else {
                throw SessionJournalError.sessionMismatch
            }
            guard record.state == .active else { return }
            try writeUnlocked(SessionRecord(id: id, startedAt: record.startedAt, state: .finished,
                                            reason: reason, endedAt: endedAt))
        }
    }

    /// Call once at startup, before accepting a new timer. A leftover active record
    /// means interruption, not successful completion, even if its duration has elapsed.
    @discardableResult
    public func recoverInterrupted() throws -> SessionRecord? {
        try synchronized {
            guard let record = try loadUnlocked() else { return nil }
            guard record.state == .active else { return record }
            let recovered = try SessionRecord(id: record.id, startedAt: record.startedAt,
                                              state: .finished, reason: "interrupted", endedAt: nil)
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
            try FileManager.default.moveItem(at: url, to: quarantine)
            return true
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
        let values: URLResourceValues
        do {
            var currentURL = url
            currentURL.removeAllCachedResourceValues()
            values = try currentURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(SessionRecord.self, from: data)
    }

    private func writeUnlocked(_ record: SessionRecord) throws {
        try validateLocation()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumFileBytes else { throw SessionJournalError.oversizedFile }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
