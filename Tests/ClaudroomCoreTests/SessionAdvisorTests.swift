import Testing
import Foundation
@testable import ClaudroomCore

private let now = Date(timeIntervalSince1970: 1_785_000_000)

// MARK: - Burn estimation

private func series(_ points: [(minutes: Double, pct: Double)]) -> [(at: Date, fraction: Double)] {
    points.map { (now.addingTimeInterval(-$0.minutes * 60), $0.pct / 100) }
}

@Test func estimatesASteadyBurn() {
    // 10% over 30 minutes == 20 %/h
    let s = series([(30, 50), (20, 53.3), (10, 56.6), (0, 60)])
    let burn = BurnEstimator.estimate(samples: s, now: now)
    #expect(burn != nil)
    #expect(abs((burn?.perHour ?? 0) - 0.20) < 0.01)
}

@Test func flatUsageBurnsNothing() {
    let s = series([(30, 40), (20, 40), (10, 40), (0, 40)])
    #expect(abs(BurnEstimator.estimate(samples: s, now: now)?.perHour ?? 1) < 0.001)
}

@Test func tooFewSamplesYieldsNoEstimate() {
    #expect(BurnEstimator.estimate(samples: series([(10, 40), (0, 50)]), now: now) == nil)
}

@Test func tooShortASpanYieldsNoEstimate() {
    // Three samples but only two minutes apart.
    let s = series([(2, 40), (1, 42), (0, 44)])
    #expect(BurnEstimator.estimate(samples: s, now: now) == nil)
}

@Test func samplesOutsideLookbackAreIgnored() {
    // The old points imply a huge burn; only the recent flat ones should count.
    let s = series([(600, 0), (500, 40), (30, 80), (20, 80), (10, 80), (0, 80)])
    let burn = BurnEstimator.estimate(samples: s, now: now, lookback: 45 * 60)
    #expect(abs(burn?.perHour ?? 1) < 0.01)
}

@Test func regressionSurvivesIntegerQuantisation() {
    // The API reports whole percents, so real series are step functions.
    // Endpoint subtraction would read 0 %/h between many pairs; the slope should not.
    let s = series([(40, 80), (35, 80), (30, 81), (25, 81), (20, 82),
                    (15, 82), (10, 83), (5, 83), (0, 84)])
    let burn = BurnEstimator.estimate(samples: s, now: now)
    #expect((burn?.perHour ?? 0) > 0.04)   // roughly 6 %/h
    #expect((burn?.perHour ?? 0) < 0.09)
}

// MARK: - Binding limiter

private func window(_ pct: Double, resetsInHours: Double) -> UsageSnapshot.Window {
    .init(fraction: pct / 100, resetsAt: now.addingTimeInterval(resetsInHours * 3600))
}

@Test func sessionCappingWithAQuietWeekIsRateLimited() {
    let advice = SessionAdvisor.advise(
        fiveHour: window(88, resetsInHours: 2.5),
        weekly: window(19, resetsInHours: 140),
        burn: BurnRate(perHour: 0.023, sampleCount: 10, spanHours: 0.5),
        now: now, dominantModel: "Opus 4.8")
    #expect(advice.limiter == .rateLimited)
    #expect(advice.detail.contains("Opus 4.8"))
    #expect(advice.detail.contains("Sonnet") || advice.detail.contains("Haiku"))
}

@Test func bothStretchedIsAPlanCeiling() {
    let advice = SessionAdvisor.advise(
        fiveHour: window(90, resetsInHours: 1),
        weekly: window(85, resetsInHours: 40),
        burn: nil, now: now, dominantModel: nil)
    #expect(advice.limiter == .planCeiling)
}

@Test func neitherStretchedMeansCapacityGoingSpare() {
    let advice = SessionAdvisor.advise(
        fiveHour: window(20, resetsInHours: 4),
        weekly: window(15, resetsInHours: 140),
        burn: nil, now: now, dominantModel: nil)
    #expect(advice.limiter == .underUsing)
}

@Test func quietSessionWithASpentWeekIsFrontLoaded() {
    let advice = SessionAdvisor.advise(
        fiveHour: window(10, resetsInHours: 4),
        weekly: window(78, resetsInHours: 40),
        burn: nil, now: now, dominantModel: nil)
    #expect(advice.limiter == .frontLoaded)
}

@Test func missingWindowsYieldUnknownRatherThanAGuess() {
    let advice = SessionAdvisor.advise(fiveHour: nil, weekly: window(50, resetsInHours: 40),
                                       burn: nil, now: now, dominantModel: nil)
    #expect(advice.limiter == .unknown)
    #expect(advice.projectedCapAt == nil)
}

// MARK: - Projection

@Test func projectsWhenTheWindowWillCap() {
    // 60% used, 20 %/h burn, resets in 4h -> hits 100% in 2h, before the reset.
    let advice = SessionAdvisor.advise(
        fiveHour: window(60, resetsInHours: 4),
        weekly: window(20, resetsInHours: 140),
        burn: BurnRate(perHour: 0.20, sampleCount: 8, spanHours: 0.5),
        now: now, dominantModel: nil)
    let capAt = try? #require(advice.projectedCapAt)
    #expect(capAt != nil)
    if let capAt {
        #expect(abs(capAt.timeIntervalSince(now) / 3600 - 2.0) < 0.05)
    }
}

@Test func noProjectionWhenTheWindowResetsFirst() {
    // 60% used, 2 %/h burn, resets in 1h -> only reaches 62%.
    let advice = SessionAdvisor.advise(
        fiveHour: window(60, resetsInHours: 1),
        weekly: window(20, resetsInHours: 140),
        burn: BurnRate(perHour: 0.02, sampleCount: 8, spanHours: 0.5),
        now: now, dominantModel: nil)
    #expect(advice.projectedCapAt == nil)
    #expect(advice.limiter == .underUsing)
}

@Test func aProjectedCapCountsAsAtRiskEvenWhenCurrentUsageIsModest() {
    // 40% now but burning fast enough to blow through before the reset.
    let advice = SessionAdvisor.advise(
        fiveHour: window(40, resetsInHours: 4),
        weekly: window(20, resetsInHours: 140),
        burn: BurnRate(perHour: 0.30, sampleCount: 8, spanHours: 0.5),
        now: now, dominantModel: "Opus 5")
    #expect(advice.limiter == .rateLimited)
    #expect(advice.projectedCapAt != nil)
}

@Test func noBurnMeansNoProjectionButStillADiagnosis() {
    let advice = SessionAdvisor.advise(
        fiveHour: window(88, resetsInHours: 2),
        weekly: window(19, resetsInHours: 140),
        burn: nil, now: now, dominantModel: nil)
    #expect(advice.projectedCapAt == nil)
    #expect(advice.limiter == .rateLimited)   // 88% is over the risk threshold on its own
}

@Test func adviceNeverSuggestsDownshiftWhenNothingIsBinding() {
    let advice = SessionAdvisor.advise(
        fiveHour: window(10, resetsInHours: 4),
        weekly: window(10, resetsInHours: 140),
        burn: nil, now: now, dominantModel: "Opus 4.8")
    #expect(!advice.detail.contains("Sonnet"))
    #expect(!advice.detail.contains("Haiku"))
}
