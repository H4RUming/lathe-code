import Foundation
import LatheLocalization
import Security

public protocol CredentialStore: Sendable {
    func get(id: UUID) throws -> String?
    func set(id: UUID, value: String) throws
    func delete(id: UUID) throws
}

public struct CredentialStoreError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? { L10n.format("provider.credentials.storeFailure", table: "ProviderErrors", String(status)) }
}

public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    public init(service: String = "io.lathe.provider-credentials") { self.service = service }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }

    public func get(id: UUID) throws -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError(status: status == errSecSuccess ? errSecDecode : status)
        }
        return value
    }

    public func set(id: UUID, value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 16384, !value.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else {
            throw ProviderError.invalidRequest(L10n.text("provider.credentials.invalidKey", table: "ProviderErrors"))
        }
        let query = query(id)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
    }

    public func delete(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError(status: status) }
    }
}

/// Explicit injection for tests; never reads environment variables or the user's Keychain.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    public init() {}
    public func get(id: UUID) throws -> String? { lock.withLock { values[id] } }
    public func set(id: UUID, value: String) throws { lock.withLock { values[id] = value } }
    public func delete(id: UUID) throws { lock.withLock { _ = values.removeValue(forKey: id) } }
}
