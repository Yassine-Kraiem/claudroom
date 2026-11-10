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

    /// Marked deprecated itself so the call inside does not warn: the underlying
    /// API went away in 10.10 with no replacement for legacy ACL items, and this
    /// is the only mechanism that suppresses their prompt.
    @available(macOS, deprecated: 10.10,
               message: "SecKeychain is deprecated, but nothing replaces it for legacy ACL prompts.")
    private static func setInteractionAllowed(_ allowed: Bool) {
        SecKeychainSetUserInteractionAllowed(allowed)
    }

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        // `SecKeychainSetUserInteractionAllowed`, not `kSecUseAuthenticationUI`.
        //
        // The latter looks like the modern answer and does nothing here: it gates
        // kSecAccessControl prompts — Touch ID, passcode — while this item is
        // guarded by a legacy SecKeychain ACL, whose dialog predates that API.
        // Measured against this very item: with kSecUseAuthenticationUISkip the
        // read put a dialog on screen and returned success after 12.6 seconds;
        // with user interaction disallowed it returned in 9ms and drew nothing.
        //
        // Deprecated since 10.10 with no replacement for legacy ACL items, and
        // process-global — hence the defer, so one background read cannot leave
        // every later Keychain call unable to ask.
        // First choice: Apple's own `security` tool. Claude Code writes this item
        // through that tool, so the item's ACL trusts /usr/bin/security — and
        // keeps trusting it across every token refresh, because each rewrite is
        // done by the same tool. Measured: 0.15s, no dialog, on an item whose ACL
        // had just dropped Claudroom. This is what removes the Reconnect step.
        if let blob = readViaSecurityTool() {
            return try parse(blob: blob)
        }

        if !allowInteraction { setInteractionAllowed(false) }
        defer {
            if !allowInteraction { setInteractionAllowed(true) }
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        // errSecAuthFailed is what a suppressed ACL prompt actually returns here,
        // despite reading like a wrong password; errSecInteractionNotAllowed is
        // the documented one. Treat both as "needs the user".
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw KeychainError.authorizationRequired
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.notFound
        }
        return try parse(blob: data)
    }

    /// Set once the `security` tool is seen to stall — the sign that its read is
    /// waiting on a dialog, i.e. Claude Code no longer writes the item through it.
    /// From then on this run uses the Security framework path only, so a
    /// background poll never stalls on that dialog twice.
    nonisolated(unsafe) private static var securityToolUnavailable = false
    private static let securityToolTimeout: TimeInterval = 2

    /// Reads the item through `/usr/bin/security`, or returns nil to fall back.
    ///
    /// A trusted read finishes in well under a second. If the tool is *not*
    /// trusted it would sit behind an authorisation dialog, so it gets a short
    /// deadline: on expiry the process is terminated (taking the dialog with it)
    /// and the path is switched off for the rest of the run.
    static func readViaSecurityTool() -> Data? {
        guard !securityToolUnavailable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { securityToolUnavailable = true; return nil }

        // Drain the pipe while waiting, so a large item cannot fill the buffer
        // and deadlock the child.
        let reader = DispatchQueue(label: "claudroom.security-tool")
        nonisolated(unsafe) var data = Data()
        let drained = DispatchSemaphore(value: 0)
        reader.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        if done.wait(timeout: .now() + securityToolTimeout) == .timedOut {
            process.terminate()
            securityToolUnavailable = true
            return nil
        }
        drained.wait()
        guard process.terminationStatus == 0 else { return nil }
        // `-w` prints the secret followed by a newline.
        while data.last == 0x0A { data.removeLast() }
        return data.isEmpty ? nil : data
    }
}
