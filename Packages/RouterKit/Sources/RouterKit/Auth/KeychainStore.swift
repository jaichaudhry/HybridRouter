import Foundation
import Security
import Synchronization

/// Storage for small secrets such as the user's Claude API key.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> String?
    func write(_ value: String, for account: String) throws
    func delete(_ account: String) throws
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain error \(status)" }
}

/// Generic-password Keychain storage, readable only on this device after first unlock.
public struct KeychainStore: SecretStore {
    public static let claudeAPIKeyAccount = "claude-api-key"

    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(_ account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// In-memory store for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private let values: Mutex<[String: String]>

    public init(_ values: [String: String] = [:]) {
        self.values = Mutex(values)
    }

    public func read(_ account: String) throws -> String? {
        values.withLock { $0[account] }
    }

    public func write(_ value: String, for account: String) throws {
        values.withLock { $0[account] = value }
    }

    public func delete(_ account: String) throws {
        _ = values.withLock { $0.removeValue(forKey: account) }
    }
}
