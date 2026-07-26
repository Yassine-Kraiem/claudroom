import Foundation

public struct ActivityBucket: Sendable, Equatable {
    public let hour: Date
    public let outputTokens: Int
    /// Hours that have not happened yet. Drawn differently from hours that elapsed
    /// with nothing in them — unused future capacity is not yet waste.
    public let isFuture: Bool

    public var isActive: Bool { outputTokens > 0 }

    public init(hour: Date, outputTokens: Int, isFuture: Bool) {
        self.hour = hour
        self.outputTokens = outputTokens
        self.isFuture = isFuture
    }
}

public struct DailyActivity: Sendable, Equatable, Identifiable {
    public let day: Date
    public let model: String
    public let outputTokens: Int
    public let messages: Int

    public var displayName: String { ModelName.display(for: model) }
    public var id: String { "\(day.timeIntervalSince1970)-\(model)" }

    public init(day: Date, model: String, outputTokens: Int, messages: Int) {
        self.day = day
        self.model = model
        self.outputTokens = outputTokens
        self.messages = messages
    }
}

public struct ProjectUsageRow: Sendable, Equatable, Identifiable {
    public let project: String
    public let messages: Int
    public let outputTokens: Int
    /// Input, output and both cache classes. Two or three orders of magnitude
    /// larger than `outputTokens` on any cache-heavy workload, which is most of
    /// them — the two numbers answer different questions and neither substitutes
    /// for the other.
    public let totalTokens: Int
    /// Summed per (project, model) rather than applied as one blended rate: a
    /// project that mixes Opus and Haiku has no single meaningful rate.
    public let apiCost: Double
    /// Tokens belonging to models with no published price on file. Excluded from
    /// `apiCost` rather than assumed free.
    public let unpricedTokens: Int

    public var id: String { project }

    public init(project: String,
                messages: Int,
                outputTokens: Int,
                totalTokens: Int = 0,
                apiCost: Double = 0,
                unpricedTokens: Int = 0) {
        self.project = project
        self.messages = messages
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.apiCost = apiCost
        self.unpricedTokens = unpricedTokens
    }
}

/// The window the dashboard is reporting on.
///
/// Every panel reads from one window, so the cost figures, the chart and the
/// project ranking always describe the same span. Panels that quietly used
/// different ranges would put two incompatible numbers on one screen.
public enum DashboardRange: String, CaseIterable, Sendable, Identifiable {
    case cycle, week, month, all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cycle: return "Cycle"
        case .week:  return "7 days"
        case .month: return "30 days"
        case .all:   return "All"
        }
    }

    /// Resolved against the data actually on hand. `from` is clamped to the first
    /// recorded hour, so "30 days" on a two-week-old install reports two weeks
    /// rather than implying a fortnight of silence that never happened.
    ///
    /// `.cycle` falls back to a trailing seven days when no cycle is running —
    /// between a reset and the next successful poll there is no cycle start to
    /// anchor to, and an empty dashboard would be worse than an approximate one.
    public func window(now: Date,
                       cycleStart: Date?,
                       earliest: Date,
                       latest: Date) -> (from: Date, to: Date) {
        let start: Date
        switch self {
        case .cycle: start = cycleStart ?? now.addingTimeInterval(-7 * 86400)
        case .week:  start = now.addingTimeInterval(-7 * 86400)
        case .month: start = now.addingTimeInterval(-30 * 86400)
        case .all:   start = earliest
        }
        // `to` is pushed out to meet `from`, never the reverse. A cycle that
        // opened after the last recorded hour has genuinely no data in it, and
        // collapsing `from` backwards instead would report the hour before the
        // cycle started as if it belonged to the cycle.
        let from = max(start, earliest)
        return (from, max(latest, from))
    }
}

/// One project opened up: where its cost came from, by token class and by model.
///
/// The token-class split is the part worth looking at. Output is the number people
/// expect to dominate and rarely does — on a long agentic session cache reads are
/// two orders of magnitude larger, and at a tenth of the input rate they still end
/// up the biggest line.
public struct ProjectDetail: Sendable, Equatable {
    public let project: String
    public let totalCost: Double
    public let totalTokens: Int
    public let messages: Int
    /// Input, output, cache write, cache read — costliest first.
    public let byTokenClass: [Pricing.Line]
    /// Costliest model first. `tokens` on each line is output tokens.
    public let byModel: [Pricing.Line]
    public let unpricedTokens: Int

    public init(project: String, totalCost: Double, totalTokens: Int, messages: Int,
                byTokenClass: [Pricing.Line], byModel: [Pricing.Line],
                unpricedTokens: Int) {
        self.project = project
        self.totalCost = totalCost
        self.totalTokens = totalTokens
        self.messages = messages
        self.byTokenClass = byTokenClass
        self.byModel = byModel
        self.unpricedTokens = unpricedTokens
    }
}

public enum ActivityTimeline {
    /// Guards against an absurd bucket count if a bad reset timestamp ever slips
    /// through — a weekly cycle is 168 hours.
    static let maximumBuckets = 200

    /// One bucket per hour across the cycle, zero-filled, so idle stretches occupy
    /// space rather than being silently collapsed. The empty bars are the point.
    public static func buckets(from start: Date,
                               to end: Date,
                               now: Date,
                               usage: [Date: Int]) -> [ActivityBucket] {
        guard end > start else { return [] }
        let hours = Int((end.timeIntervalSince(start) / 3600).rounded())
        guard hours > 0, hours <= maximumBuckets else { return [] }

        return (0..<hours).map { offset in
            let hour = start.addingTimeInterval(Double(offset) * 3600)
            return ActivityBucket(hour: hour,
                                  outputTokens: usage[hour] ?? 0,
                                  isFuture: hour > now)
        }
    }

    /// Hours that have elapsed with no activity at all. The literal idle count.
    public static func idleElapsedHours(_ buckets: [ActivityBucket]) -> Int {
        buckets.filter { !$0.isFuture && !$0.isActive }.count
    }

    public static func activeHours(_ buckets: [ActivityBucket]) -> Int {
        buckets.filter(\.isActive).count
    }

    public static func peakTokens(_ buckets: [ActivityBucket]) -> Int {
        buckets.map(\.outputTokens).max() ?? 0
    }
}
