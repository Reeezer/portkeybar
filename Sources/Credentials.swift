import Foundation
import Security

enum Credentials {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.portkeybar.usage",
         kSecAttrAccount as String: "analytics"]
    }

    static func read() throws -> String {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(attributes as CFDictionary, &value)
        if result == errSecItemNotFound { throw UsageError.noKey }
        guard result == errSecSuccess, let data = value as? Data,
              let key = String(data: data, encoding: .utf8) else { throw KeychainError(code: result) }
        return key
    }

    static func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw UsageError.noKey }
        let values = [kSecValueData as String: Data(key.utf8)]
        var result = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            var attributes = query.merging(values) { _, new in new }
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw KeychainError(code: result) }
    }
}

struct KeychainError: LocalizedError {
    let code: OSStatus
    var errorDescription: String? {
        "Keychain: \(SecCopyErrorMessageString(code, nil) as String? ?? String(code))"
    }
}
