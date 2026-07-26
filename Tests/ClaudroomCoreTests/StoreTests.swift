import Testing
import Foundation
@testable import ClaudroomCore

private func tempStore() throws -> Store {
    let path = NSTemporaryDirectory() + "clautrack-test-\(UUID().uuidString).sqlite"
    return try Store(database: try Database(path: path))
}

private let t0 = Date(timeIntervalSince1970: 1_785_000_000)

private func makeSnapshot(five: Double? = nil, weekly: Double?,
                          observedAt: Date = t0) -> UsageSnapshot {
    UsageSnapshot(
        observedAt: observedAt,
        fiveHour: five.map { .init(fraction: $0, resetsAt: observedAt.addingTimeInterval(3600)) },
        weekly: weekly.map { .init(fraction: $0, resetsAt: observedAt.addingTimeInterval(86400)) },
        scopedLimits: [], extraUsageEnabled: false, schemaOK: true, rawJSON: "{}")
}

@Test func schemaCreatesOnInit() throws {
    let store = try tempStore()
    #expect(try store.recentSamples(limit: 10).isEmpty)
    #expect(try store.closedCycles(limit: 10).isEmpty)
}

@Test func roundTripsASample() throws {
    let store = try tempStore()
    try store.insert(sample: makeSnapshot(five: 0.31, weekly: 0.14),
                     planTier: "default_claude_max_5x")

    let rows = try store.recentSamples(limit: 10)
    #expect(rows.count == 1)
    #expect(rows[0].weeklyFrac == 0.14)
    #expect(rows[0].fiveHourFrac == 0.31)
    #expect(rows[0].observedAt == t0)
}

@Test func storesFractionNotPercent() throws {
    let store = try tempStore()
    try store.insert(sample: makeSnapshot(weekly: 0.14), planTier: "t")
    #expect(try store.recentSamples(limit: 1)[0].weeklyFrac! <= 1.0)
}

@Test func nilWindowsRoundTripAsNil() throws {
    let store = try tempStore()
    try store.insert(sample: makeSnapshot(five: nil, weekly: nil), planTier: "t")
    let row = try store.recentSamples(limit: 1)[0]
    #expect(row.fiveHourFrac == nil)
    #expect(row.weeklyFrac == nil)
}

@Test func upsertsCycleByResetsAt() throws {
    let store = try tempStore()
    let reset = t0.addingTimeInterval(86400)
    try store.upsert(cycle: Cycle(resetsAt: reset, planTier: "t",
        finalUtilizationFrac: 0.1, closed: false, inferred: false, lastObservedAt: t0))
    try store.upsert(cycle: Cycle(resetsAt: reset, planTier: "t",
        finalUtilizationFrac: 0.4, closed: true, inferred: true, lastObservedAt: t0))

    let closed = try store.closedCycles(limit: 10)
    #expect(closed.count == 1)
    #expect(closed[0].finalUtilizationFrac == 0.4)
    #expect(closed[0].inferred)
}

@Test func openCycleExcludesClosed() throws {
    let store = try tempStore()
    try store.upsert(cycle: Cycle(resetsAt: t0, planTier: "t",
        finalUtilizationFrac: 0.4, closed: true, inferred: false, lastObservedAt: t0))
    #expect(try store.openCycle() == nil)

    let open = t0.addingTimeInterval(86400)
    try store.upsert(cycle: Cycle(resetsAt: open, planTier: "t",
        finalUtilizationFrac: 0.2, closed: false, inferred: false, lastObservedAt: t0))
    #expect(try store.openCycle()?.resetsAt == open)
}

@Test func closedCyclesAreNewestFirst() throws {
    let store = try tempStore()
    for i in 0..<3 {
        try store.upsert(cycle: Cycle(
            resetsAt: t0.addingTimeInterval(Double(i) * 604800), planTier: "t",
            finalUtilizationFrac: Double(i) / 10, closed: true,
            inferred: false, lastObservedAt: nil))
    }
    let closed = try store.closedCycles(limit: 10)
    #expect(closed.count == 3)
    #expect(closed[0].resetsAt > closed[1].resetsAt)
    #expect(closed[1].resetsAt > closed[2].resetsAt)
}

@Test func settingsRoundTrip() throws {
    let store = try tempStore()
    #expect(try store.setting("monthly_price") == nil)
    try store.setSetting("monthly_price", "100")
    #expect(try store.setting("monthly_price") == "100")
    try store.setSetting("monthly_price", "200")
    #expect(try store.setting("monthly_price") == "200")
}

@Test func alertDedupeIsPerCycleAndRule() throws {
    let store = try tempStore()
    #expect(try store.hasFired(rule: "closing_48h", cycleResetsAt: t0) == false)
    try store.markFired(rule: "closing_48h", cycleResetsAt: t0, at: t0)
    #expect(try store.hasFired(rule: "closing_48h", cycleResetsAt: t0))
    #expect(try store.hasFired(rule: "closing_24h", cycleResetsAt: t0) == false)
    let other = t0.addingTimeInterval(604800)
    #expect(try store.hasFired(rule: "closing_48h", cycleResetsAt: other) == false)
}

@Test func markFiredTwiceDoesNotThrow() throws {
    let store = try tempStore()
    try store.markFired(rule: "closing_48h", cycleResetsAt: t0, at: t0)
    try store.markFired(rule: "closing_48h", cycleResetsAt: t0, at: t0)
    #expect(try store.hasFired(rule: "closing_48h", cycleResetsAt: t0))
}

@Test func prunesOldSamplesOnly() throws {
    let store = try tempStore()
    try store.insert(sample: makeSnapshot(weekly: 0.1,
        observedAt: t0.addingTimeInterval(-10 * 86400)), planTier: "t")
    try store.insert(sample: makeSnapshot(weekly: 0.2, observedAt: t0), planTier: "t")
    try store.pruneSamples(olderThan: t0.addingTimeInterval(-7 * 86400))

    let rows = try store.recentSamples(limit: 10)
    #expect(rows.count == 1)
    #expect(rows[0].weeklyFrac == 0.2)
}

// MARK: - Per-model usage

private func event(_ hour: String, _ model: String, out: Int) -> TranscriptEvent {
    TranscriptEvent(hourBucket: hour, model: model, project: "~/demo", inputTokens: 1, outputTokens: out,
                    cacheReadTokens: 2, cacheCreationTokens: 3)
}

@Test func recordsAndAggregatesModelUsage() throws {
    let store = try tempStore()
    try store.record(events: [
        event("2026-07-25T07", "claude-opus-5", out: 100),
        event("2026-07-25T07", "claude-opus-5", out: 50),
        event("2026-07-25T08", "claude-sonnet-5", out: 30),
    ])
    let rows = try store.modelUsage(since: Date(timeIntervalSince1970: 0))
    #expect(rows.count == 2)
    #expect(rows[0].model == "claude-opus-5")
    #expect(rows[0].outputTokens == 150)
    #expect(rows[0].messages == 2)
    #expect(rows[1].outputTokens == 30)
}

@Test func recordingTwiceAccumulatesRatherThanReplaces() throws {
    let store = try tempStore()
    try store.record(events: [event("2026-07-25T07", "claude-opus-5", out: 100)])
    try store.record(events: [event("2026-07-25T07", "claude-opus-5", out: 25)])
    let rows = try store.modelUsage(since: Date(timeIntervalSince1970: 0))
    #expect(rows[0].outputTokens == 125)
    #expect(rows[0].messages == 2)
}

@Test func modelUsageIsScopedToTheCycleWindow() throws {
    let store = try tempStore()
    try store.record(events: [
        event("2026-07-20T07", "claude-opus-5", out: 999),   // before the cycle
        event("2026-07-25T07", "claude-opus-5", out: 10),    // inside it
    ])
    let cycleStart = ISO.date("2026-07-24T12:00:00.000Z")!
    let rows = try store.modelUsage(since: cycleStart)
    #expect(rows.count == 1)
    #expect(rows[0].outputTokens == 10)
}

@Test func recordingNothingIsANoop() throws {
    let store = try tempStore()
    try store.record(events: [])
    #expect(try store.modelUsage(since: Date(timeIntervalSince1970: 0)).isEmpty)
}

@Test func scanOffsetsRoundTrip() throws {
    let store = try tempStore()
    #expect(try store.scanOffsets().isEmpty)
    try store.setScanOffsets(["/a.jsonl": 100, "/b.jsonl": 200])
    #expect(try store.scanOffsets() == ["/a.jsonl": 100, "/b.jsonl": 200])
    try store.setScanOffsets(["/a.jsonl": 500])
    #expect(try store.scanOffsets()["/a.jsonl"] == 500)
    #expect(try store.scanOffsets()["/b.jsonl"] == 200)
}

@Test func hourBucketMatchesTranscriptTimestampPrefix() {
    let d = ISO.date("2026-07-25T07:41:10.705Z")!
    #expect(ISO.hourBucket(d) == "2026-07-25T07")
}
