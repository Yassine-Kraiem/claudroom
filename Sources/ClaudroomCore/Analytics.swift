import Foundation

public enum SuppressionReason: Sendable, Equatable {
    case unknownPlan
    case insufficientHistory
}

public enum RightSizingVerdict: Sendable, Equatable {
    case collecting(have: Int, need: Int)
    case stay(peakPct: Double)
    case downgrade(to: PlanTier, projectedPct: Double)
    case upgrade(to: PlanTier, cappedCycles: Int)
    case unavailable(SuppressionReason)
}

/// Plan right-sizing. Money conversion used to live here too and was removed: the
/// plan is a flat monthly licence, so allocating a share of the fee to each weekly
/// cycle was an invention layered on top of the honest number, which is utilization.
public enum Analytics {
    public static let minimumCycles = 4
    public static let peakWindow = 8
    /// Projected utilization must stay below this on a cheaper plan. A downgrade
    /// that breaks the busiest week is worse than no recommendation.
    public static let safetyThresholdPct: Double = 80
    /// A cycle at or above this counts as capped out.
    public static let cappedThresholdPct: Double = 95

    /// `closedCycles` is newest-first, as returned by `Store.closedCycles(limit:)`.
    public static func rightSizing(closedCycles: [Cycle],
                                   currentTier: PlanTier?) -> RightSizingVerdict {
        guard let current = currentTier else { return .unavailable(.unknownPlan) }

        let usable = closedCycles.compactMap { $0.finalUtilizationFrac }
        guard usable.count >= minimumCycles else {
            return .collecting(have: usable.count, need: minimumCycles)
        }

        let window = Array(usable.prefix(peakWindow))
        let peakPct = (window.max() ?? 0) * 100

        // Upgrade takes precedence: capping out is a live problem, not a saving.
        let recent = Array(usable.prefix(4))
        let capped = recent.filter { $0 * 100 >= cappedThresholdPct }.count
        if capped >= 2 {
            let bigger = PlanTier.allCases
                .filter { $0.multiplier > current.multiplier }
                .min { $0.multiplier < $1.multiplier }
            if let bigger { return .upgrade(to: bigger, cappedCycles: capped) }
            return .stay(peakPct: peakPct)
        }

        let candidates = PlanTier.allCases
            .filter { $0.multiplier < current.multiplier }
            .sorted { $0.multiplier < $1.multiplier }   // cheapest first

        for candidate in candidates {
            let projected = peakPct * current.multiplier / candidate.multiplier
            if projected <= safetyThresholdPct {
                return .downgrade(to: candidate, projectedPct: projected)
            }
        }

        return .stay(peakPct: peakPct)
    }
}
