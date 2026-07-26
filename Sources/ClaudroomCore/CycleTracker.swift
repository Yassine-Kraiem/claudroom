import Foundation

public struct CycleReconciliation: Sendable, Equatable {
    public let toClose: Cycle?
    public let open: Cycle
}

public enum CycleTracker {
    /// Tolerance for calling a close "observed" rather than "inferred": if the last
    /// sample landed within two poll intervals of the reset, the closing value is as
    /// accurate as polling can make it.
    static let observedToleranceMultiplier: Double = 2

    public static func reconcile(open: Cycle?,
                                 snapshot: UsageSnapshot,
                                 planTier: String,
                                 pollInterval: TimeInterval) -> CycleReconciliation {
        // A weekly window with no reset timestamp cannot identify a cycle.
        guard let weekly = snapshot.weekly, let weeklyResetsAt = weekly.resetsAt else {
            // No usable weekly window: change nothing rather than guess.
            let unchanged = open ?? Cycle(resetsAt: .distantPast, planTier: planTier,
                                          finalUtilizationFrac: nil, closed: false,
                                          inferred: false, lastObservedAt: nil)
            return CycleReconciliation(toClose: nil, open: unchanged)
        }

        let fresh = Cycle(resetsAt: weeklyResetsAt,
                          planTier: planTier,
                          finalUtilizationFrac: weekly.fraction,
                          closed: false,
                          inferred: false,
                          lastObservedAt: snapshot.observedAt)

        guard let open else {
            return CycleReconciliation(toClose: nil, open: fresh)
        }

        if open.resetsAt == weeklyResetsAt {
            var updated = open
            updated.finalUtilizationFrac = weekly.fraction
            updated.lastObservedAt = snapshot.observedAt
            return CycleReconciliation(toClose: nil, open: updated)
        }

        // resets_at moved: the prior cycle ended.
        var closing = open
        closing.closed = true
        let gap = open.lastObservedAt.map { open.resetsAt.timeIntervalSince($0) } ?? .infinity
        closing.inferred = gap > pollInterval * observedToleranceMultiplier
        return CycleReconciliation(toClose: closing, open: fresh)
    }
}
