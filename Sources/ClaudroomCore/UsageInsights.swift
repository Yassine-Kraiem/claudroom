import Foundation

/// Where a cycle is heading, extrapolated from how much of it has elapsed.
public struct CyclePace: Sendable, Equatable {
    public let elapsedFraction: Double
    public let observedUtilization: Double
    /// Utilization at close if the rest of the cycle matches the pace so far.
    public let projectedClose: Double

    public init(elapsedFraction: Double, observedUtilization: Double, projectedClose: Double) {
        self.elapsedFraction = elapsedFraction
        self.observedUtilization = observedUtilization
        self.projectedClose = projectedClose
    }
}

public struct CacheHealth: Sendable, Equatable {
    public let readTokens: Int
    public let createdTokens: Int
    /// Share of cached input that was reused rather than rebuilt.
    public let reuseFraction: Double

    /// Rebuilding context repeatedly is the wasteful pattern; above this it is not
    /// worth mentioning. Deliberately high — healthy setups sit above 95%.
    public static let healthyThreshold = 0.90

    public var isHealthy: Bool { reuseFraction >= Self.healthyThreshold }

    public init(readTokens: Int, createdTokens: Int, reuseFraction: Double) {
        self.readTokens = readTokens
        self.createdTokens = createdTokens
        self.reuseFraction = reuseFraction
    }
}

public enum UsageInsights {
    /// Below this much of the cycle elapsed, extrapolation is meaningless: two busy
    /// hours on a Friday would project to 400%. Returns nil rather than a number
    /// that would look authoritative and be nonsense.
    public static let minimumElapsedForProjection = 0.20

    public static func cyclePace(cycleStart: Date,
                                 cycleEnd: Date,
                                 now: Date,
                                 utilization: Double) -> CyclePace? {
        let total = cycleEnd.timeIntervalSince(cycleStart)
        guard total > 0 else { return nil }

        let elapsed = min(1, max(0, now.timeIntervalSince(cycleStart) / total))
        guard elapsed >= minimumElapsedForProjection else { return nil }

        return CyclePace(elapsedFraction: elapsed,
                         observedUtilization: utilization,
                         projectedClose: utilization / elapsed)
    }

    public static func cacheHealth(_ rows: [ModelUsageRow]) -> CacheHealth? {
        let read = rows.reduce(0) { $0 + $1.cacheReadTokens }
        let created = rows.reduce(0) { $0 + $1.cacheCreationTokens }
        let total = read + created
        guard total > 0 else { return nil }
        return CacheHealth(readTokens: read,
                           createdTokens: created,
                           reuseFraction: Double(read) / Double(total))
    }

    /// Output tokens per hour-of-day slot, 0…23, in the given calendar.
    /// Used to show when work actually happens — which is what determines when
    /// 5-hour windows open.
    public static func hourOfDayProfile(_ activity: [Date: Int],
                                        calendar: Calendar = .current) -> [Int] {
        var slots = [Int](repeating: 0, count: 24)
        for (date, tokens) in activity {
            let hour = calendar.component(.hour, from: date)
            guard (0..<24).contains(hour) else { continue }
            slots[hour] += tokens
        }
        return slots
    }

    /// The contiguous run of hours holding most of the work, as a (start, end) pair
    /// in hour-of-day terms. Nil when activity is too flat for a peak to mean
    /// anything.
    public static func peakWindow(_ profile: [Int], width: Int = 5) -> (start: Int, end: Int)? {
        guard profile.count == 24, profile.contains(where: { $0 > 0 }), width > 0, width <= 24
        else { return nil }

        var bestStart = 0
        var bestSum = -1
        for start in 0..<24 {
            var sum = 0
            for offset in 0..<width { sum += profile[(start + offset) % 24] }
            if sum > bestSum { bestSum = sum; bestStart = start }
        }
        let total = profile.reduce(0, +)
        // A flat profile has no meaningful peak: width/24 of the total is chance.
        guard total > 0, Double(bestSum) / Double(total) > Double(width) / 24 * 1.25
        else { return nil }

        return (bestStart, (bestStart + width - 1) % 24)
    }

    /// Days in the range with no recorded activity at all.
    public static func idleDays(activeDays: Set<Date>,
                                from: Date,
                                to: Date,
                                calendar: Calendar = .current) -> Int {
        guard to >= from else { return 0 }
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        guard let span = calendar.dateComponents([.day], from: start, to: end).day
        else { return 0 }

        let normalisedActive = Set(activeDays.map { calendar.startOfDay(for: $0) })
        var idle = 0
        for offset in 0...max(0, span) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if !normalisedActive.contains(day) { idle += 1 }
        }
        return idle
    }
}
