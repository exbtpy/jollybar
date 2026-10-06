import Foundation
import Security

protocol SecretStoring {
    func save(_ secret: String, account: String) throws
    func load(account: String) -> String?
    func delete(account: String)
}

enum ManagementSecret {
    static let account = "management-api-key"
    static let service = "com.exbtpy.GrokUsageBar"
}

enum CursorSecret {
    /// Keychain account for the Cursor Admin or Organization API key.
    /// Same keychain service as the management key; a different account.
    static let account = "cursor-api-key"
}

enum SecretStoreError: Error {
    case saveFailed
}

/// In-memory stand-in used by tests. The app uses `KeychainSecretStore`.
final class MemorySecretStore: SecretStoring {
    private var values: [String: String] = [:]

    func save(_ secret: String, account: String) throws {
        values[account] = secret
    }

    func load(account: String) -> String? {
        values[account]
    }

    func delete(account: String) {
        values.removeValue(forKey: account)
    }
}

final class KeychainSecretStore: SecretStoring {
    private let service: String

    init(service: String = ManagementSecret.service) {
        self.service = service
    }

    func save(_ secret: String, account: String) throws {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.saveFailed
        }
    }

    func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
