import Foundation
import Security

/// API key 存在 Keychain 里：每个 Connection 一条通用密码，service 是 `com.linem7.Chatbot.apikey`，
/// account 是 Connection ID（ARCHITECTURE §5.1）。第一次读取后缓存在内存里。
@MainActor
final class APIKeyStore {
    private static let service = "com.linem7.Chatbot.apikey"
    private var cache: [String: String] = [:]

    func apiKey(for connectionID: UUID) throws(KeychainError) -> String? {
        let account = connectionID.uuidString
        if let cached = cache[account] { return cached }

        var query = Self.baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        cache[account] = key
        return key
    }

    func setAPIKey(_ key: String, for connectionID: UUID) throws(KeychainError) {
        let account = connectionID.uuidString
        let query = Self.baseQuery(account: account)
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        cache[account] = key
    }

    func deleteAPIKey(for connectionID: UUID) throws(KeychainError) {
        let account = connectionID.uuidString
        let status = SecItemDelete(Self.baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        cache[account] = nil
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct KeychainError: Error {
    let status: OSStatus
}
