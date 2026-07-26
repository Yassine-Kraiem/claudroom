import Testing
import Foundation
@testable import ClaudroomCore

@Suite struct PricingTests {

    @Test func noTableEntryIsAPrefixOfAnother() {
        // `price(for:)` returns the first prefix match, which is only unambiguous
        // while this holds. A new entry that violates it would silently shadow.
        for a in Pricing.table {
            for b in Pricing.table where a.prefix != b.prefix {
                #expect(!b.prefix.hasPrefix(a.prefix),
                        "\(b.prefix) is shadowed by \(a.prefix)")
            }
        }
    }

    @Test func datedSnapshotResolvesToTheAliasPrice() {
        #expect(Pricing.price(for: "claude-haiku-4-5-20251001")
                == Pricing.price(for: "claude-haiku-4-5"))
    }

    @Test func unknownModelIsUnpricedRatherThanFree() {
        #expect(Pricing.price(for: "claude-opus-3") == nil)
        #expect(Pricing.price(for: "<synthetic>") == nil)
        #expect(Pricing.cost(model: "gpt-4", input: 1000, output: 1000,
                             cacheRead: 0, cacheWrite: 0) == nil)
    }

    @Test func cacheMultipliersFollowInput() {
        let opus = Pricing.price(for: "claude-opus-5")!
        #expect(opus.cacheRead == 0.5)   // 0.1x
        #expect(opus.cacheWrite == 10)   // 2x, the one-hour TTL
    }

    /// The load-bearing test. These are the figures Claude Code's own `/usage`
    /// printed for a real Opus 5 session, and the total it put beside them. If a
    /// rate or a cache multiplier is wrong, this is what catches it.
    @Test func reproducesClaudeCodeReportedSessionCost() {
        let cost = Pricing.cost(model: "claude-opus-5",
                                input: 5_100,
                                output: 481_200,
                                cacheRead: 142_700_000,
                                cacheWrite: 4_000_000)!
        // /usage reported $123.74 against token counts it had already rounded to
        // one decimal place, so agreement is only meaningful to about a percent.
        #expect(abs(cost - 123.74) < 1.0)
    }

    /// The five-minute TTL multiplier (1.25x) is the plausible wrong answer. It
    /// is off by more than the tolerance above, so the test can tell them apart.
    @Test func fiveMinuteCacheMultiplierWouldNotReproduceThatTotal() {
        let opus = Pricing.price(for: "claude-opus-5")!
        let withShortTTL = (5_100 * opus.input
                            + 481_200 * opus.output
                            + 142_700_000 * opus.cacheRead
                            + 4_000_000 * opus.input * 1.25) / 1_000_000
        #expect(abs(withShortTTL - 123.74) > 10)
    }

    @Test func haikuSessionMatchesToTheCostOfItsWebSearches() {
        // 74.2k input, 2.8k output, no cache. /usage said $0.1280, which includes
        // 4 web searches billed outside the token rates.
        let cost = Pricing.cost(model: "claude-haiku-4-5",
                                input: 74_200, output: 2_800,
                                cacheRead: 0, cacheWrite: 0)!
        #expect(abs(cost - 0.0882) < 0.001)
    }

    @Test func moneyScalesToTheMagnitude() {
        #expect(Pricing.money(0) == "$0")
        #expect(Pricing.money(0.004) == "<$0.01")
        #expect(Pricing.money(4.2) == "$4.20")
        #expect(Pricing.money(123.74) == "$124")
        #expect(Pricing.money(19_780) == "$19.8k")
        #expect(Pricing.money(2_400_000) == "$2.4M")
    }

    @Test func modelUsageRowPricesItsOwnTokens() {
        let row = ModelUsageRow(model: "claude-opus-5", messages: 1,
                                inputTokens: 1_000_000, outputTokens: 0,
                                cacheReadTokens: 0, cacheCreationTokens: 0)
        #expect(row.apiCost == 5)
        #expect(row.totalTokens == 1_000_000)

        let unknown = ModelUsageRow(model: "claude-opus-3", messages: 1,
                                    inputTokens: 1_000_000, outputTokens: 0,
                                    cacheReadTokens: 0, cacheCreationTokens: 0)
        #expect(unknown.apiCost == nil)
    }
}

@Suite struct ProjectCostTests {

    private func makeStore() throws -> Store {
        let path = NSTemporaryDirectory() + "claudroom-cost-\(UUID().uuidString).sqlite"
        return try Store(database: try Database(path: path))
    }

    /// A project mixing an expensive and a cheap model must be priced per model.
    /// Applying one blended rate to the project total is the bug this guards.
    @Test func mixedModelProjectIsPricedPerModel() throws {
        let store = try makeStore()
        let hour = "2026-07-20T10"
        try store.record(events: [
            TranscriptEvent(hourBucket: hour, model: "claude-opus-5", project: "alpha",
                            inputTokens: 1_000_000, outputTokens: 0,
                            cacheReadTokens: 0, cacheCreationTokens: 0),
            TranscriptEvent(hourBucket: hour, model: "claude-haiku-4-5", project: "alpha",
                            inputTokens: 1_000_000, outputTokens: 0,
                            cacheReadTokens: 0, cacheCreationTokens: 0),
        ])

        let rows = try store.projectUsage(since: ISO.date("2026-07-01T00:00:00.000Z")!)
        #expect(rows.count == 1)
        // $5 for the Opus million, $1 for the Haiku million.
        #expect(abs(rows[0].apiCost - 6) < 0.0001)
        #expect(rows[0].totalTokens == 2_000_000)
        #expect(rows[0].unpricedTokens == 0)
    }

    @Test func unpricedModelTokensAreSetAsideNotCountedAsZero() throws {
        let store = try makeStore()
        try store.record(events: [
            TranscriptEvent(hourBucket: "2026-07-20T10", model: "claude-opus-5",
                            project: "beta", inputTokens: 1_000_000, outputTokens: 0,
                            cacheReadTokens: 0, cacheCreationTokens: 0),
            TranscriptEvent(hourBucket: "2026-07-20T10", model: "claude-opus-3",
                            project: "beta", inputTokens: 500_000, outputTokens: 0,
                            cacheReadTokens: 0, cacheCreationTokens: 0),
        ])

        let rows = try store.projectUsage(since: ISO.date("2026-07-01T00:00:00.000Z")!)
        #expect(abs(rows[0].apiCost - 5) < 0.0001)
        #expect(rows[0].unpricedTokens == 500_000)
        #expect(rows[0].totalTokens == 1_500_000)
    }

    @Test func detailIsNilForAProjectWithNothingRecorded() throws {
        let store = try makeStore()
        try store.record(events: [
            TranscriptEvent(hourBucket: "2026-07-20T10", model: "claude-opus-5",
                            project: "real", inputTokens: 10, outputTokens: 10,
                            cacheReadTokens: 0, cacheCreationTokens: 0),
        ])
        let since = ISO.date("2026-07-01T00:00:00.000Z")!
        #expect(try store.projectDetail(project: "never-touched", since: since) == nil)
        #expect(try store.projectDetail(project: "real", since: since) != nil)
    }

    @Test func breakdownRanksCacheReadsAboveOutputWhenTheyDominate() throws {
        let store = try makeStore()
        // The shape of a long agentic session: modest output, enormous cache reads.
        // Output costs 50x more per token and still loses.
        try store.record(events: [
            TranscriptEvent(hourBucket: "2026-07-20T10", model: "claude-opus-5",
                            project: "agentic", inputTokens: 0, outputTokens: 1_000_000,
                            cacheReadTokens: 500_000_000, cacheCreationTokens: 0),
        ])

        let detail = try #require(
            try store.projectDetail(project: "agentic",
                                    since: ISO.date("2026-07-01T00:00:00.000Z")!))
        #expect(detail.byTokenClass.first?.label == "cache read")
        #expect(abs(detail.byTokenClass[0].cost - 250) < 0.001)  // 500M x $0.50/M
        #expect(detail.byTokenClass[1].label == "output")
        #expect(abs(detail.byTokenClass[1].cost - 25) < 0.001)   // 1M x $25/M
        // Classes with no tokens are dropped rather than listed at zero.
        #expect(!detail.byTokenClass.contains { $0.label == "input" })
    }

    @Test func datedSnapshotAndAliasMergeIntoOneModelLine() throws {
        let store = try makeStore()
        try store.record(events: [
            TranscriptEvent(hourBucket: "2026-07-20T10", model: "claude-haiku-4-5",
                            project: "p", inputTokens: 1_000_000, outputTokens: 0,
                            cacheReadTokens: 0, cacheCreationTokens: 0),
            TranscriptEvent(hourBucket: "2026-07-20T11", model: "claude-haiku-4-5-20251001",
                            project: "p", inputTokens: 1_000_000, outputTokens: 0,
                            cacheReadTokens: 0, cacheCreationTokens: 0),
        ])

        let detail = try #require(
            try store.projectDetail(project: "p",
                                    since: ISO.date("2026-07-01T00:00:00.000Z")!))
        // Two store rows, one model on screen — a duplicate label would also
        // collide as a ForEach id.
        #expect(detail.byModel.count == 1)
        #expect(detail.byModel[0].label == "Haiku 4.5")
        #expect(abs(detail.byModel[0].cost - 2) < 0.0001)
    }

    @Test func detailTotalAgreesWithTheProjectRow() throws {
        let store = try makeStore()
        try store.record(events: [
            TranscriptEvent(hourBucket: "2026-07-20T10", model: "claude-opus-5",
                            project: "p", inputTokens: 12_345, outputTokens: 6_789,
                            cacheReadTokens: 9_000_000, cacheCreationTokens: 300_000),
            TranscriptEvent(hourBucket: "2026-07-21T11", model: "claude-sonnet-5",
                            project: "p", inputTokens: 500, outputTokens: 2_000,
                            cacheReadTokens: 40_000, cacheCreationTokens: 1_000),
        ])
        let since = ISO.date("2026-07-01T00:00:00.000Z")!

        let row = try #require(try store.projectUsage(since: since).first)
        let detail = try #require(try store.projectDetail(project: "p", since: since))
        #expect(abs(detail.totalCost - row.apiCost) < 0.0001)
        #expect(detail.totalTokens == row.totalTokens)
        #expect(detail.messages == row.messages)
        // And the classes account for the whole of it.
        #expect(abs(detail.byTokenClass.reduce(0) { $0 + $1.cost } - detail.totalCost) < 0.0001)
        #expect(abs(detail.byModel.reduce(0) { $0 + $1.cost } - detail.totalCost) < 0.0001)
    }

    @Test func projectsAreRankedByCostNotByOutput() throws {
        let store = try makeStore()
        // "cheap" generates ten times the output, on a model priced 5x lower,
        // against "pricey" whose cost is dominated by cache reads.
        try store.record(events: [
            TranscriptEvent(hourBucket: "2026-07-20T10", model: "claude-haiku-4-5",
                            project: "cheap", inputTokens: 0, outputTokens: 1_000_000,
                            cacheReadTokens: 0, cacheCreationTokens: 0),
            TranscriptEvent(hourBucket: "2026-07-20T10", model: "claude-opus-5",
                            project: "pricey", inputTokens: 0, outputTokens: 100_000,
                            cacheReadTokens: 100_000_000, cacheCreationTokens: 0),
        ])

        let rows = try store.projectUsage(since: ISO.date("2026-07-01T00:00:00.000Z")!)
        #expect(rows.first?.project == "pricey")
        #expect(rows.first!.outputTokens < rows.last!.outputTokens)
    }
}

@Suite struct DashboardRangeTests {
    private let now = ISO.date("2026-07-26T12:00:00.000Z")!

    @Test func allSpansTheWholeRecordedHistory() {
        let earliest = ISO.date("2026-05-29T00:00:00.000Z")!
        let latest = ISO.date("2026-07-26T11:00:00.000Z")!
        let w = DashboardRange.all.window(now: now, cycleStart: nil,
                                          earliest: earliest, latest: latest)
        #expect(w.from == earliest)
        #expect(w.to == latest)
    }

    @Test func trailingWindowsAreClampedToWhatWasActuallyRecorded() {
        // A two-week-old install asked for 30 days must report two weeks, not
        // imply a fortnight of silence that never happened.
        let earliest = ISO.date("2026-07-12T00:00:00.000Z")!
        let latest = ISO.date("2026-07-26T11:00:00.000Z")!
        let w = DashboardRange.month.window(now: now, cycleStart: nil,
                                            earliest: earliest, latest: latest)
        #expect(w.from == earliest)
    }

    @Test func sevenDaysIsNotClampedWhenTheHistoryIsLonger() {
        let earliest = ISO.date("2026-05-29T00:00:00.000Z")!
        let latest = ISO.date("2026-07-26T11:00:00.000Z")!
        let w = DashboardRange.week.window(now: now, cycleStart: nil,
                                           earliest: earliest, latest: latest)
        #expect(abs(w.from.timeIntervalSince(now.addingTimeInterval(-7 * 86400))) < 1)
    }

    @Test func cycleUsesTheOpenCycleStart() {
        let cycleStart = ISO.date("2026-07-24T14:00:00.000Z")!
        let w = DashboardRange.cycle.window(
            now: now, cycleStart: cycleStart,
            earliest: ISO.date("2026-05-29T00:00:00.000Z")!,
            latest: ISO.date("2026-07-26T11:00:00.000Z")!)
        #expect(w.from == cycleStart)
    }

    @Test func cycleFallsBackToSevenDaysWhenNoCycleIsRunning() {
        // Between a reset and the next successful poll there is no cycle to
        // anchor to; an approximate window beats an empty dashboard.
        let w = DashboardRange.cycle.window(
            now: now, cycleStart: nil,
            earliest: ISO.date("2026-05-29T00:00:00.000Z")!,
            latest: ISO.date("2026-07-26T11:00:00.000Z")!)
        #expect(abs(w.from.timeIntervalSince(now.addingTimeInterval(-7 * 86400))) < 1)
    }

    @Test func windowNeverEndsBeforeItStarts() {
        // A cycle that opened after the last recorded hour — nothing scanned yet
        // this cycle. The window must stay degenerate rather than inverted, or
        // the SQL range silently matches everything.
        let earliest = ISO.date("2026-07-26T09:00:00.000Z")!
        for range in DashboardRange.allCases {
            let w = range.window(now: now,
                                 cycleStart: ISO.date("2026-07-26T10:00:00.000Z")!,
                                 earliest: earliest,
                                 latest: ISO.date("2026-07-26T08:00:00.000Z")!)
            #expect(w.to >= w.from, "\(range) produced an inverted window")
        }
    }
}
