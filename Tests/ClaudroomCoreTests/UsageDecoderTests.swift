import Testing
import Foundation
@testable import ClaudroomCore

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json",
                                subdirectory: "Fixtures")!
    return try Data(contentsOf: url)
}

private let t0 = Date(timeIntervalSince1970: 1_785_000_000)

@Test func decodesRealPayload() throws {
    let snap = try UsageDecoder.decode(data: fixture("usage-max5x-normal"), observedAt: t0)
    #expect(snap.schemaOK)
    #expect(snap.fiveHour?.fraction == 0.45)
    #expect(snap.weekly?.fraction == 0.15)
    #expect(snap.extraUsageEnabled == false)
    #expect(snap.observedAt == t0)
}

@Test func convertsPercentToFractionExactlyOnce() throws {
    let snap = try UsageDecoder.decode(data: fixture("usage-max5x-normal"), observedAt: t0)
    // 45.0 in the payload must become 0.45 — not 45.0, and not 0.0045.
    #expect(snap.weekly.map { $0.fraction > 0 && $0.fraction <= 1 } == true)
    #expect(snap.fiveHour.map { $0.fraction > 0 && $0.fraction <= 1 } == true)
}

@Test func capturesScopedModelLimits() throws {
    let snap = try UsageDecoder.decode(data: fixture("usage-max5x-normal"), observedAt: t0)
    let scoped = snap.scopedLimits.first { $0.kind == "weekly_scoped" }
    #expect(scoped?.modelDisplayName == "Fable")
    #expect(scoped?.fraction == 0.19)
}

@Test func parsesFractionalSecondTimestamps() throws {
    let snap = try UsageDecoder.decode(data: fixture("usage-max5x-normal"), observedAt: t0)
    #expect(snap.weekly?.resetsAt != nil)
    #expect(snap.fiveHour?.resetsAt != nil)
}

@Test func missingWeeklyDegradesRatherThanThrows() throws {
    let json = #"{"five_hour":{"utilization":31.0,"resets_at":"2026-07-25T11:00:00+00:00"},"limits":[]}"#
    let snap = try UsageDecoder.decode(data: Data(json.utf8), observedAt: t0)
    #expect(snap.weekly == nil)
    #expect(snap.fiveHour?.fraction == 0.31)
    #expect(snap.schemaOK == false)
}

@Test func wrongTypedUtilizationDegrades() throws {
    let json = #"{"five_hour":{"utilization":"31.0","resets_at":"2026-07-25T11:00:00+00:00"},"seven_day":{"utilization":14.0,"resets_at":"2026-07-31T12:00:00+00:00"},"limits":[]}"#
    let snap = try UsageDecoder.decode(data: Data(json.utf8), observedAt: t0)
    #expect(snap.fiveHour == nil)
    #expect(snap.weekly?.fraction == 0.14)
    #expect(snap.schemaOK == false)
}

@Test func nullResetsAtKeepsTheWindowButWithoutAReset() throws {
    // Was previously treated as drift and dropped, which made the 5-hour row
    // vanish from the UI at every reset boundary. A null reset with a valid
    // utilization is a running-window-absent state, not corruption.
    let json = #"{"seven_day":{"utilization":14.0,"resets_at":null},"limits":[]}"#
    let snap = try UsageDecoder.decode(data: Data(json.utf8), observedAt: t0)
    #expect(snap.weekly?.fraction == 0.14)
    #expect(snap.weekly?.resetsAt == nil)
    // schemaOK is not asserted here: this fixture also omits five_hour entirely,
    // which is a genuine drift signal. The both-keys-present case is covered by
    // nullResetsAtWithZeroUsageIsAValidIdleWindow.
}

@Test func unknownCodenameFieldsAreIgnored() throws {
    let json = #"{"seven_day":{"utilization":14.0,"resets_at":"2026-07-31T12:00:00+00:00"},"five_hour":{"utilization":1.0,"resets_at":"2026-07-25T11:00:00+00:00"},"limits":[],"tangelo":{"anything":1},"brand_new_field":[1,2,3]}"#
    let snap = try UsageDecoder.decode(data: Data(json.utf8), observedAt: t0)
    #expect(snap.schemaOK)
    #expect(snap.weekly?.fraction == 0.14)
}

@Test func extraUsageEnabledIsDetected() throws {
    let json = #"{"seven_day":{"utilization":14.0,"resets_at":"2026-07-31T12:00:00+00:00"},"five_hour":{"utilization":1.0,"resets_at":"2026-07-25T11:00:00+00:00"},"limits":[],"extra_usage":{"is_enabled":true}}"#
    let snap = try UsageDecoder.decode(data: Data(json.utf8), observedAt: t0)
    #expect(snap.extraUsageEnabled)
}

@Test func malformedJSONThrows() {
    #expect(throws: (any Error).self) {
        try UsageDecoder.decode(data: Data("not json".utf8), observedAt: t0)
    }
}

@Test func rawJSONIsRetainedVerbatim() throws {
    let data = try fixture("usage-max5x-normal")
    let snap = try UsageDecoder.decode(data: data, observedAt: t0)
    #expect(snap.rawJSON == String(decoding: data, as: UTF8.self))
}

@Test func decodesProfile() throws {
    let json = #"{"account":{"email":"a@b.c"},"organization":{"rate_limit_tier":"default_claude_max_5x","subscription_created_at":"2026-05-07T08:55:00.072343Z"}}"#
    let p = try ProfileDecoder.decode(data: Data(json.utf8))
    #expect(p.tier == .max5x)
    #expect(p.rawTier == "default_claude_max_5x")
    #expect(p.email == "a@b.c")
    #expect(p.subscriptionCreatedAt != nil)
}

@Test func unknownTierYieldsNilTierButKeepsRawString() throws {
    let json = #"{"organization":{"rate_limit_tier":"default_claude_max_50x"}}"#
    let p = try ProfileDecoder.decode(data: Data(json.utf8))
    #expect(p.tier == nil)
    #expect(p.rawTier == "default_claude_max_50x")
}

@Test func missingOrganizationDegrades() throws {
    let p = try ProfileDecoder.decode(data: Data(#"{}"#.utf8))
    #expect(p.tier == nil)
    #expect(p.rawTier == "")
}

@Test func parsesCredentialBlob() throws {
    let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","expiresAt":1784978095744,"rateLimitTier":"default_claude_max_5x"}}"#
    let c = try Keychain.parse(blob: Data(json.utf8))
    #expect(c.accessToken == "sk-ant-oat01-x")
    #expect(c.rawTier == "default_claude_max_5x")
    #expect(c.expiresAt == Date(timeIntervalSince1970: 1784978095.744))
}

@Test func missingOauthSectionThrows() {
    #expect(throws: KeychainError.malformed) {
        try Keychain.parse(blob: Data(#"{"mcpOAuth":{}}"#.utf8))
    }
}

@Test func missingAccessTokenThrows() {
    #expect(throws: KeychainError.malformed) {
        try Keychain.parse(blob: Data(#"{"claudeAiOauth":{"expiresAt":1}}"#.utf8))
    }
}

// MARK: - Reset timestamp jitter

@Test func resetTimestampsAreNormalisedToTheMinute() throws {
    // The server recomputes resets_at per request; these three are the same cycle.
    let variants = [
        "2026-07-31T11:59:59.316000+00:00",
        "2026-07-31T12:00:00.135000+00:00",
        "2026-07-31T12:00:00.995000+00:00",
    ]
    let resets = try variants.map { ts -> Date in
        let json = #"{"seven_day":{"utilization":19.0,"resets_at":"\#(ts)"},"limits":[]}"#
        return try UsageDecoder.decode(data: Data(json.utf8), observedAt: t0).weekly!.resetsAt!
    }
    #expect(Set(resets).count == 1)
}

@Test func genuinelyDifferentCyclesStayDistinct() throws {
    func reset(_ ts: String) throws -> Date {
        let json = #"{"seven_day":{"utilization":19.0,"resets_at":"\#(ts)"},"limits":[]}"#
        return try UsageDecoder.decode(data: Data(json.utf8), observedAt: t0).weekly!.resetsAt!
    }
    let thisWeek = try reset("2026-07-31T12:00:00.135000+00:00")
    let nextWeek = try reset("2026-08-07T12:00:00.881000+00:00")
    #expect(thisWeek != nextWeek)
    #expect(nextWeek.timeIntervalSince(thisWeek) == 7 * 86400)
}

@Test func jitterDoesNotFabricateCycles() {
    // The regression this guards: one cycle, polled repeatedly, must never close.
    func snap(_ ts: String, _ frac: Double) throws -> UsageSnapshot {
        let json = #"{"seven_day":{"utilization":\#(frac * 100),"resets_at":"\#(ts)"},"limits":[]}"#
        return try UsageDecoder.decode(data: Data(json.utf8), observedAt: t0)
    }
    var open: Cycle?
    var closedCount = 0
    let polls = [
        ("2026-07-31T11:59:59.316000+00:00", 0.16),
        ("2026-07-31T12:00:00.135000+00:00", 0.18),
        ("2026-07-31T12:00:00.191000+00:00", 0.19),
        ("2026-07-31T12:00:00.995000+00:00", 0.19),
    ]
    for (ts, frac) in polls {
        guard let s = try? snap(ts, frac) else { continue }
        let r = CycleTracker.reconcile(open: open, snapshot: s,
                                       planTier: "t", pollInterval: 60)
        if r.toClose != nil { closedCount += 1 }
        open = r.open
    }
    #expect(closedCount == 0)
    #expect(open?.finalUtilizationFrac == 0.19)
}

// MARK: - Windows that are not running

@Test func nullResetsAtWithZeroUsageIsAValidIdleWindow() throws {
    // Exactly what the API returns in the instant after a 5-hour window resets
    // and before the next request starts a new one. Not drift — a real state.
    let json = #"{"five_hour":{"utilization":0.0,"resets_at":null},"seven_day":{"utilization":20.0,"resets_at":"2026-07-31T12:00:00.000000+00:00"},"limits":[]}"#
    let snap = try UsageDecoder.decode(data: Data(json.utf8), observedAt: t0)

    #expect(snap.fiveHour != nil)          // must not vanish
    #expect(snap.fiveHour?.fraction == 0)
    #expect(snap.fiveHour?.resetsAt == nil)
    #expect(snap.schemaOK)                 // and must not be flagged as drift
    #expect(snap.weekly?.fraction == 0.20)
}

@Test func anIdleWindowIsNotActive() throws {
    let json = #"{"five_hour":{"utilization":0.0,"resets_at":null},"limits":[]}"#
    let snap = try UsageDecoder.decode(data: Data(json.utf8), observedAt: t0)
    #expect(snap.fiveHour?.isActive(at: t0) == false)
}

@Test func aRunningWindowIsActive() {
    let w = UsageSnapshot.Window(fraction: 0.5, resetsAt: t0.addingTimeInterval(3600))
    #expect(w.isActive(at: t0))
    // ...but not once its reset has passed.
    #expect(w.isActive(at: t0.addingTimeInterval(7200)) == false)
}

@Test func anUnparseableResetIsStillTreatedAsDrift() throws {
    let json = #"{"five_hour":{"utilization":10.0,"resets_at":"not-a-date"},"limits":[]}"#
    let snap = try UsageDecoder.decode(data: Data(json.utf8), observedAt: t0)
    #expect(snap.schemaOK == false)
    #expect(snap.fiveHour?.resetsAt == nil)
}
