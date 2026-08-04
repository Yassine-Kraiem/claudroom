import Testing
import Foundation
@testable import ClaudroomCore

// The Keychain round-trip itself is not unit-tested: it would write to the
// developer's real login Keychain and can raise an authorisation prompt, which a
// test suite must never do. The encoding is what carries the risk of silently
// losing a field, so that is what is covered here.

@Test func roundTripsAllCredentialFields() throws {
    let original = Credentials(accessToken: "sk-ant-oat01-example",
                               expiresAt: Date(timeIntervalSince1970: 1_785_000_000),
                               rawTier: "default_claude_max_5x")
    let restored = CredentialCache.decode(try CredentialCache.encode(original))
    #expect(restored?.accessToken == original.accessToken)
    #expect(restored?.rawTier == original.rawTier)
    #expect(restored?.expiresAt == original.expiresAt)
}

@Test func roundTripsWithoutAnExpiry() throws {
    let original = Credentials(accessToken: "token", expiresAt: nil, rawTier: nil)
    let restored = CredentialCache.decode(try CredentialCache.encode(original))
    #expect(restored?.accessToken == "token")
    #expect(restored?.expiresAt == nil)
    #expect(restored?.rawTier == nil)
}

@Test func rejectsAnEmptyToken() throws {
    // A blank token would otherwise look like a valid cache hit and stop the app
    // ever re-reading the real credential.
    let blank = Credentials(accessToken: "", expiresAt: nil, rawTier: nil)
    #expect(CredentialCache.decode(try CredentialCache.encode(blank)) == nil)
}

@Test func rejectsGarbage() {
    #expect(CredentialCache.decode(Data("not json".utf8)) == nil)
    #expect(CredentialCache.decode(Data()) == nil)
}

@Test func usesItsOwnServiceNotClaudeCodes() {
    // Writing anywhere near Claude Code's item is the one thing this must never do.
    #expect(CredentialCache.service != Keychain.service)
    #expect(CredentialCache.service.hasPrefix("com.yassinekraiem.claudroom"))
}

@Suite struct KeychainInteractionTests {

    /// `authorizationRequired` exists so callers can tell "you are signed out"
    /// from "I chose not to interrupt you". Collapsing them is what made the
    /// popover tell people to run `claude` when the real fix was one click.
    @Test func authorizationRequiredIsItsOwnState() {
        #expect(KeychainError.authorizationRequired != KeychainError.notFound)
        #expect(KeychainError.authorizationRequired != KeychainError.malformed)
    }

    // Neither read path is exercised here, on purpose.
    //
    // The interactive one raised a real Keychain dialog and hung the suite until
    // it was dismissed — which is precisely the behaviour this change keeps out of
    // the background, and the reason `swift test` must never reach it.
    //
    // The non-interactive one does not prompt, but it still queries the real
    // Keychain: 4s on a machine that has Claude Code installed, and a different
    // result on one that does not. A test whose outcome depends on whether the
    // developer uses Claude Code is not a test. The guarantee that matters —
    // background callers pass allowInteraction: false — is enforced by that
    // argument being required at every call site, and read at the one place it
    // is passed in AppModel.credentials(now:allowInteraction:).
}
