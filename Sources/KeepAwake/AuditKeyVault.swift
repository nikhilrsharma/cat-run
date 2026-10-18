import CryptoKit
import Foundation
import Security

enum AuditKeyError: Error {
    case unavailable, missing, invalid
}

/// Reads only Cat Run's own key. Never widens its Keychain ACL or writes a key beside the data.
final class AuditKeyVault: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: Data?
    private let hasEncryptedData: () -> Bool
    private let readOrCreate: (Bool) throws -> Data

    init(hasEncryptedData: @escaping () -> Bool,
         readOrCreate: @escaping (Bool) throws -> Data = AuditKeyVault.keychainKey) {
        self.hasEncryptedData = hasEncryptedData
        self.readOrCreate = readOrCreate
    }

    func key(existingEncryptedData: Bool) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let value = try readOrCreate(!(existingEncryptedData || hasEncryptedData()))
        guard value.count == 32 else { throw AuditKeyError.invalid }
        cached = value
        return value
    }

    /// Missing data permits a first key; inaccessible or uncertain data never does.
    static func hasEncryptedHistory(in directory: URL) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue,
              let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true,
              let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { return true }
        let logs = directory.appendingPathComponent("Logs", isDirectory: true)
        if files.contains(where: { $0.lastPathComponent == "Logs" }) {
            guard let values = try? logs.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink != true, values.isDirectory == true,
                  let entries = try? manager.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil) else { return true }
            if !entries.isEmpty { return true }
        }
        for file in files where file.lastPathComponent == "session.json" || file.lastPathComponent.hasPrefix("session.json.corrupt-") {
            guard let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
                  values.isSymbolicLink != true, values.isRegularFile == true,
                  let handle = try? FileHandle(forReadingFrom: file) else { return true }
            defer { try? handle.close() }
            guard let prefix = try? handle.read(upToCount: 32), prefix.first == UInt8(ascii: "{") else { return true }
        }
        return false
    }

    static func keychainKey(createIfMissing: Bool) throws -> Data {
        // The login Keychain supports the local ad-hoc build. Its default ACL is
        // restricted to this app; a future signing change may require macOS approval.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.catrun.app.local-history",
            kSecAttrAccount as String: "encryption-key-v1",
            kSecUseDataProtectionKeychain as String: false
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, data.count == 32 else { throw AuditKeyError.invalid }
            return data
        }
        guard status == errSecItemNotFound else { throw AuditKeyError.unavailable }
        guard createIfMissing else { throw AuditKeyError.missing }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var access: SecAccess?
        guard SecAccessCreate("Cat Run encrypted activity" as CFString, nil, &access) == errSecSuccess,
              let access else { throw AuditKeyError.unavailable }
        var attributes = query
        attributes[kSecValueData as String] = key
        attributes[kSecAttrLabel as String] = "Cat Run encrypted activity"
        attributes[kSecAttrAccess as String] = access
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecDuplicateItem { return try keychainKey(createIfMissing: false) }
        guard added == errSecSuccess else { throw AuditKeyError.unavailable }
        return key
    }
}
