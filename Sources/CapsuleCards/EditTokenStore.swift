import Foundation
import Security

/// Keeps each capsule's edit token, which is returned only once, when the capsule is created.
protocol EditTokenStore: Sendable {
    func token(for publicID: String) throws -> String?
    func save(_ token: String, for publicID: String) throws
    func remove(for publicID: String) throws
}

struct KeychainError: Error, Equatable {
    let status: OSStatus
}

struct KeychainEditTokenStore: EditTokenStore {
    var service = "cards.capsule.edit-token"

    private func query(for publicID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: publicID,
        ]
    }

    func token(for publicID: String) throws -> String? {
        var query = query(for: publicID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func save(_ token: String, for publicID: String) throws {
        try remove(for: publicID)
        var attributes = query(for: publicID)
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    func remove(for publicID: String) throws {
        let status = SecItemDelete(query(for: publicID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
