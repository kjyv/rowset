import Foundation
import Security

/// Keeps the passwords of the bookmarks in the login keychain.
///
/// The bookmark file holds no secret, so a password goes here instead. One item per bookmark, keyed
/// by the id of that bookmark.
enum KeychainStore {
    static let service = "tech.alcemy.Rowset"

    private static func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    static func password(for id: UUID) -> String? {
        var request = query(for: id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes the password, or removes it when the value is empty.
    static func setPassword(_ value: String, for id: UUID) {
        let trimmed = value
        guard !trimmed.isEmpty else {
            removePassword(for: id)
            return
        }

        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(for: id) as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }

        var item = query(for: id)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(item as CFDictionary, nil)
    }

    static func removePassword(for id: UUID) {
        SecItemDelete(query(for: id) as CFDictionary)
    }

    static func hasPassword(for id: UUID) -> Bool {
        password(for: id) != nil
    }
}
