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
