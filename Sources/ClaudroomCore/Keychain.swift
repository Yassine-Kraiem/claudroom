import Foundation
import Security

public struct Credentials: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date?
    public let rawTier: String?

    public init(accessToken: String, expiresAt: Date?, rawTier: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.rawTier = rawTier
    }
}

public enum KeychainError: Error, Equatable, Sendable {
    case notFound
    case malformed
}

public enum Keychain {
    public static let service = "Claude Code-credentials"

    static func parse(blob: Data) throws -> Credentials {
        guard let root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { throw KeychainError.malformed }

        let expires = (oauth["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000.0)
        }
        return Credentials(accessToken: token,
                           expiresAt: expires,
                           rawTier: oauth["rateLimitTier"] as? String)
    }

    /// Read-only by design. This package never writes to the Keychain and never
    /// refreshes a token: if Anthropic rotates refresh tokens on use, refreshing
    /// here would invalidate Claude Code's own credentials and log the user out.
    public static func readClaudeCodeCredentials() throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.notFound
        }
        return try parse(blob: data)
    }
}
