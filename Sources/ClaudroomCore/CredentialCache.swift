import Foundation
import Security

/// A private copy of the Claude Code token, in a Keychain item Claudroom owns.
///
/// Why this exists: Claude Code rewrites its own credential item whenever it
/// refreshes the OAuth token, and that resets the item's ACL — which drops
/// Claudroom from the trusted list and makes macOS ask for authorisation again.
/// Nothing the app does can prevent that. But an item Claudroom *creates* lists
/// Claudroom in its ACL from the start, so reading it back never prompts.
///
/// The trade-off, stated plainly: your token then exists in two places rather than
/// one. Both are inside your login Keychain under the same encryption, and this
/// copy is only ever written by Claudroom and only ever read by Claudroom.
///
/// What has *not* changed: Claude Code's item is still read-only to us, and we
/// still never perform a token refresh. Refreshing could rotate the token and log
/// you out of Claude Code, which remains unacceptable for a passive monitor.
public enum CredentialCache {
    public static let service = "com.yassinekraiem.claudroom.credential"
    public static let account = "claude-code-token"

    private struct Payload: Codable {
        let accessToken: String
        let expiresAt: Date?
        let rawTier: String?
    }

    static func encode(_ credentials: Credentials) throws -> Data {
        try JSONEncoder().encode(Payload(accessToken: credentials.accessToken,
                                         expiresAt: credentials.expiresAt,
                                         rawTier: credentials.rawTier))
    }

    static func decode(_ data: Data) -> Credentials? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.accessToken.isEmpty else { return nil }
        return Credentials(accessToken: payload.accessToken,
                           expiresAt: payload.expiresAt,
                           rawTier: payload.rawTier)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    public static func save(_ credentials: Credentials) -> Bool {
        guard let data = try? encode(credentials) else { return false }

        // Update in place when possible: deleting and re-adding would reset our own
        // ACL, which is the exact failure mode this cache exists to avoid.
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    public static func load() -> Credentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return decode(data)
    }

    /// Removes Claudroom's copy. Claude Code's own credential is untouched.
    @discardableResult
    public static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
