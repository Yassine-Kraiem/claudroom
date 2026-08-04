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
    /// The item exists but reading it needs the user to authorise, and the caller
    /// asked not to show UI. Distinct from `notFound`: nothing is wrong, we simply
    /// declined to interrupt.
    case authorizationRequired
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
    ///
    /// `allowInteraction` decides whether macOS may put an authorisation dialog on
    /// screen. It must be `false` for anything a timer started.
    ///
    /// Claude Code rewrites this item whenever it refreshes its token, and the
    /// rewrite drops Claudroom from the item's ACL — so "Always Allow" genuinely
    /// does not stick, and authorisation is needed again every few hours. A
    /// background poll that asks for it produces exactly the failure people report:
    /// a password dialog appearing over whatever they were doing, for an app they
    /// were not using. Declining to show UI turns that into a state the app can
    /// display and the user can resolve when it suits them.
    public static func readClaudeCodeCredentials(
        allowInteraction: Bool = true
    ) throws -> Credentials {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowInteraction {
            // Fails with errSecInteractionNotAllowed rather than prompting.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw KeychainError.authorizationRequired
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.notFound
        }
        return try parse(blob: data)
    }
}
