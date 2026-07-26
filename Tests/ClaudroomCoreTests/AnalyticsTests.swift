import Testing
import Foundation
@testable import ClaudroomCore

// MARK: - Right-sizing

private func cycle(_ frac: Double, _ index: Int,
                   tier: String = "default_claude_max_5x") -> Cycle {
    Cycle(resetsAt: Date(timeIntervalSince1970: 1_785_000_000 + Double(index) * 604800),
          planTier: tier, finalUtilizationFrac: frac,
          closed: true, inferred: false, lastObservedAt: nil)
}

@Test func fewerThanFourCyclesCollectsRatherThanGuesses() {
    let v = Analytics.rightSizing(
        closedCycles: [cycle(0.1, 0), cycle(0.1, 1), cycle(0.1, 2)],
        currentTier: .max5x)
    #expect(v == .collecting(have: 3, need: 4))
}

@Test func unknownTierSuppressesTheVerdict() {
    let v = Analytics.rightSizing(
        closedCycles: (0..<6).map { cycle(0.1, $0) },
        currentTier: nil)
    #expect(v == .unavailable(.unknownPlan))
}

@Test func lowSteadyUsageRecommendsDowngradeToPro() {
    // peak 15% on Max 5x -> 15 * 5 / 1 = 75% on Pro, under the 80% threshold
    let cycles = [cycle(0.15, 0), cycle(0.12, 1), cycle(0.10, 2), cycle(0.14, 3)]
    guard case .downgrade(let to, let projected) =
        Analytics.rightSizing(closedCycles: cycles, currentTier: .max5x)
    else { Issue.record("expected downgrade"); return }
    #expect(to == .pro)
    #expect(abs(projected - 75.0) < 0.001)
}

@Test func verdictFollowsPeakNotMean() {
    // Mean 15% would suggest a downgrade; peak 41% must not.
    let cycles = [cycle(0.41, 0), cycle(0.05, 1), cycle(0.07, 2), cycle(0.07, 3)]
    guard case .stay(let peak) =
        Analytics.rightSizing(closedCycles: cycles, currentTier: .max5x)
    else { Issue.record("expected stay"); return }
    #expect(abs(peak - 41.0) < 0.001)
}

@Test func repeatedCappingRecommendsUpgrade() {
    let cycles = [cycle(0.99, 0), cycle(0.97, 1), cycle(0.5, 2), cycle(0.4, 3)]
    guard case .upgrade(let to, let capped) =
        Analytics.rightSizing(closedCycles: cycles, currentTier: .max5x)
    else { Issue.record("expected upgrade"); return }
    #expect(to == .max20x)
    #expect(capped == 2)
}

@Test func cappingOnTheTopPlanHasNowhereToGo() {
    let cycles = [cycle(0.99, 0), cycle(0.98, 1), cycle(0.99, 2), cycle(0.97, 3)]
    guard case .stay = Analytics.rightSizing(
        closedCycles: cycles, currentTier: .max20x)
    else { Issue.record("expected stay on top plan"); return }
}

@Test func peakWindowIgnoresCyclesBeyondEight() {
    // A 90% spike ten cycles back must not block a downgrade today.
    var cycles = (0..<8).map { cycle(0.10, $0) }
    cycles.append(cycle(0.90, 8))
    cycles.append(cycle(0.90, 9))
    guard case .downgrade = Analytics.rightSizing(
        closedCycles: cycles, currentTier: .max5x)
    else { Issue.record("expected downgrade"); return }
}

@Test func cyclesMissingFinalValueAreExcluded() {
    var broken = cycle(0.0, 0)
    broken.finalUtilizationFrac = nil
    let v = Analytics.rightSizing(
        closedCycles: [broken, cycle(0.1, 1), cycle(0.1, 2), cycle(0.1, 3)],
        currentTier: .max5x)
    #expect(v == .collecting(have: 3, need: 4))
}

@Test func downgradePicksCheapestViableCandidate() {
    // peak 30% on Max 20x -> Pro is 600%, Max 5x is 120%: neither viable.
    let cycles = (0..<4).map { cycle(0.30, $0) }
    guard case .stay = Analytics.rightSizing(
        closedCycles: cycles, currentTier: .max20x)
    else { Issue.record("expected stay"); return }

    // peak 3% on Max 20x -> Pro is 60%, viable and cheapest.
    let low = (0..<4).map { cycle(0.03, $0) }
    guard case .downgrade(let to, _) = Analytics.rightSizing(
        closedCycles: low, currentTier: .max20x)
    else { Issue.record("expected downgrade"); return }
    #expect(to == .pro)
}

@Test func exactlyAtSafetyThresholdIsViable() {
    // peak 16% on Max 5x -> 80% on Pro, exactly the threshold.
    let cycles = (0..<4).map { cycle(0.16, $0) }
    guard case .downgrade(let to, let projected) = Analytics.rightSizing(
        closedCycles: cycles, currentTier: .max5x)
    else { Issue.record("expected downgrade at exactly 80%"); return }
    #expect(to == .pro)
    #expect(abs(projected - 80.0) < 0.001)
}

@Test func oneCappedCycleIsNotEnoughForUpgrade() {
    let cycles = [cycle(0.99, 0), cycle(0.50, 1), cycle(0.50, 2), cycle(0.50, 3)]
    guard case .stay = Analytics.rightSizing(
        closedCycles: cycles, currentTier: .max5x)
    else { Issue.record("expected stay"); return }
}

