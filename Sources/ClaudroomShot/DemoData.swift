import Foundation
import ClaudroomCore

/// Synthetic usage for the documentation screenshots.
///
/// The README used to be rendered from the author's real database, which put
/// actual client and project names, working hours and spend into a public image —
/// and re-rendered them every time the layout changed. Demo data keeps the
/// screenshots honest about the *app* without publishing anything about whoever
/// happens to be running it.
///
/// Deterministic on purpose: a fixed seed means re-rendering after a layout change
/// produces the same numbers, so image diffs show design changes rather than noise.
enum DemoData {

    /// Plain `lrand48`-style LCG. Foundation's RNG is fine but not reproducible
    /// across runs, which is the one property this needs.
    struct Seeded: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// Ordinary-looking work: a couple of long-running efforts, some short-lived
    /// side projects, a scratch directory. Weighted so the ranking has a clear
    /// head and a long tail, which is what the panel is designed to show.
    static let projects: [(name: String, weight: Double)] = [
        ("payments-service", 1.00),
        ("web-storefront",   0.86),
        ("Documents/rfc-drafts", 0.14),
        ("~",                0.11),
        ("infra-terraform",  0.09),
        ("Desktop/scratch",  0.05),
        ("data-pipeline",    0.04),
        ("mobile-client",    0.03),
        ("design-tokens",    0.012),
        ("cli-tooling",      0.008),
        ("docs-site",        0.004),
        ("sandbox",          0.002),
    ]

    static let models: [(id: String, weight: Double)] = [
        ("claude-opus-4-8", 0.80),
        ("claude-sonnet-5", 0.11),
        ("claude-opus-5",   0.06),
        ("claude-fable-5",  0.02),
        ("claude-haiku-4-5-20251001", 0.01),
    ]

    /// 57 days ending now, matching the span a real install accumulates before the
    /// dashboard has anything interesting to say.
    static let days = 57

    /// `ClaudroomCore.ISO` is internal, so this target formats its own.
    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    private static func hourBucket(_ d: Date) -> String { String(iso(d).prefix(13)) }

    /// Seeds a fresh store with samples and per-hour usage.
    ///
    /// Returns the weekly reset used, so the caller can keep the snapshot and the
    /// hourly rows describing the same cycle.
    @discardableResult
    static func seed(into store: Store, now: Date) throws -> Date {
        var rng = Seeded(seed: 20_260_726)

        // Cycle boundaries land on the hour, as the real ones do.
        let hour: TimeInterval = 3600
        let weeklyResetsAt = Date(timeIntervalSince1970:
            (now.addingTimeInterval(2 * 86400).timeIntervalSince1970 / hour).rounded(.down) * hour)
        let fiveHourResetsAt = now.addingTimeInterval(2 * hour + 48 * 60)

        var events: [TranscriptEvent] = []
        let startOfToday = Calendar.current.startOfDay(for: now)

        for dayOffset in stride(from: days - 1, through: 0, by: -1) {
            let day = startOfToday.addingTimeInterval(-Double(dayOffset) * 86400)
            let weekday = Calendar.current.component(.weekday, from: day)
            let isWeekend = weekday == 1 || weekday == 7

            // Idle days exist and are the point of the app — roughly one weekday
            // in seven plus most weekends.
            if isWeekend && Double.random(in: 0...1, using: &rng) < 0.75 { continue }
            if !isWeekend && Double.random(in: 0...1, using: &rng) < 0.14 { continue }

            // Effort ramps over the period, so the chart has a shape rather than
            // a flat wall of identical bars.
            let ramp = 0.35 + 0.65 * Double(days - dayOffset) / Double(days)
            let intensity = ramp * Double.random(in: 0.45...1.25, using: &rng)
                          * (isWeekend ? 0.4 : 1)

            for clockHour in 0..<24 {
                // Working hours with a lunch dip, plus a thin evening tail.
                let shape: Double
                switch clockHour {
                case 9...11:  shape = 1.0
                case 12:      shape = 0.45
                case 13...17: shape = 0.95
                case 18...20: shape = 0.35
                case 8, 21:   shape = 0.18
                default:      shape = 0.03
                }
                if Double.random(in: 0...1, using: &rng) > shape * 0.85 { continue }

                let bucket = day.addingTimeInterval(Double(clockHour) * hour)
                let project = pick(projects, using: &rng)
                let model = pick(models, using: &rng)

                // Real transcripts are overwhelmingly cache reads. Reproducing that
                // ratio is what makes the cost breakdown show anything true.
                // One event is one assistant message, which is how the scanner
                // produces them and how `record` counts them.
                let messages = Int(Double.random(in: 60...200, using: &rng) * intensity) + 1
                for _ in 0..<messages {
                    let output = Int(Double.random(in: 400...2_400, using: &rng) * intensity)
                    events.append(TranscriptEvent(
                        hourBucket: hourBucket(bucket),
                        model: model,
                        project: project,
                        inputTokens: Int(Double(output) * Double.random(in: 0.05...0.14, using: &rng)),
                        outputTokens: output,
                        cacheReadTokens: Int(Double(output) * Double.random(in: 280...460, using: &rng)),
                        cacheCreationTokens: Int(Double(output) * Double.random(in: 4...9, using: &rng))))
                }
            }
        }
        try store.record(events: events)

        // A short run of samples so pace has a slope to fit rather than one point.
        for minutesAgo in stride(from: 240, through: 0, by: -20) {
            let observedAt = now.addingTimeInterval(-Double(minutesAgo) * 60)
            let progress = 1 - Double(minutesAgo) / 240
            let weekly = 0.40 + 0.03 * progress
            let five = 0.16 + 0.25 * progress
            let snapshot = UsageSnapshot(
                observedAt: observedAt,
                fiveHour: .init(fraction: five, resetsAt: fiveHourResetsAt),
                weekly: .init(fraction: weekly, resetsAt: weeklyResetsAt),
                scopedLimits: [],
                extraUsageEnabled: false,
                schemaOK: true,
                rawJSON: rawJSON(five: five, fiveResetsAt: fiveHourResetsAt,
                                 weekly: weekly, weeklyResetsAt: weeklyResetsAt))
            try store.insert(sample: snapshot, planTier: "default_claude_max_5x")
        }
        // Otherwise the masthead offers "Load full history", which is true of the
        // demo store but reads as an unfinished setup in a screenshot.
        try store.setSetting("backfill_done", "1")
        return weeklyResetsAt
    }

    private static func pick(_ table: [(String, Double)],
                             using rng: inout Seeded) -> String {
        let total = table.reduce(0) { $0 + $1.1 }
        var roll = Double.random(in: 0...total, using: &rng)
        for entry in table {
            roll -= entry.1
            if roll <= 0 { return entry.0 }
        }
        return table[0].0
    }

    /// Matches the real endpoint's shape, since the decoder is what reads it back.
    private static func rawJSON(five: Double, fiveResetsAt: Date,
                                weekly: Double, weeklyResetsAt: Date) -> String {
        """
        {"five_hour":{"utilization":\(five * 100),"resets_at":"\(iso(fiveResetsAt))",
        "limit_dollars":null,"used_dollars":null,"remaining_dollars":null},
        "seven_day":{"utilization":\(weekly * 100),"resets_at":"\(iso(weeklyResetsAt))",
        "limit_dollars":null,"used_dollars":null,"remaining_dollars":null},
        "seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":null}
        """
    }
}
