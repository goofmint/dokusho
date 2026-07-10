import Foundation
import Security

/// Errors surfaced by ``CredentialStore``.
///
/// No operation returns a fallback/default value on failure — callers must
/// handle these explicitly (per CLAUDE.md "no silent fallback" rule).
enum CredentialStoreError: Error, LocalizedError {
    /// Keychain returned an OSStatus other than success / itemNotFound.
    case keychain(OSStatus)
    /// A stored item existed but its data was not valid UTF-8.
    case invalidData

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "不明なエラー"
            return "キーチェーン操作に失敗しました (コード \(status)): \(message)"
        case .invalidData:
            return "保存されたAPIキーを読み取れませんでした。"
        }
    }
}

/// Stores the Komga API key in the Keychain.
///
/// Design.md §2.2 / §6.1: `kSecClassGenericPassword` with
/// `kSecAttrAccessibleAfterFirstUnlock`. The API key is the only secret; all
/// other connection info lives in SwiftData (`ServerConfig`).
struct CredentialStore: Sendable {
    /// Keychain service identifier. Tied to the bundle ID so it is unique to this app.
    private let service: String
    /// Fixed account label — the app registers a single server, so a single key.
    private let account: String

    init(service: String = "jp.moongift.dokusho.apikey", account: String = "komga-api-key") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Saves (or replaces) the API key.
    func saveAPIKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw CredentialStoreError.invalidData
        }

        // Delete any existing item first so this is an upsert.
        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(deleteStatus)
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
    }

    /// Loads the API key, or `nil` if none has been stored.
    ///
    /// A missing key returns `nil` (a valid "not connected" state). Any other
    /// Keychain failure throws — it must not be mistaken for "no key".
    func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.invalidData
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychain(status)
        }
    }

    /// Deletes the stored API key. A missing key is treated as success.
    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }
}
