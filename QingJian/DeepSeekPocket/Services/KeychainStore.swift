import Foundation
import Security

enum KeychainStore {
    private static let account = "personal"
    static func read(service: String = "qingjian.deepseek.api-key") throws -> String {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        SecItemUpdate(baseQuery(service: service) as CFDictionary,
                      [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        return key
    }
    static func save(_ value: String, service: String = "qingjian.deepseek.api-key") throws {
        let baseQuery = baseQuery(service: service)
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(key.utf8)
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }
    private static func baseQuery(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    private struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法读取或保存钥匙串（\(status)），请解锁手机后重试。" }
    }
}
