import Testing
import Foundation
@testable import ClaudroomCore

private let reset = Date(timeIntervalSince1970: 1_785_000_000)
private func hoursBefore(_ h: Double) -> Date { reset.addingTimeInterval(-h * 3600) }

private func evaluate(frac: Double?, now: Date,
                      fired: Set<AlertRule> = [],
                      thresholds: AlertThresholds = .default) -> [PendingAlert] {
    AlertEngine.evaluate(weeklyFraction: frac, resetsAt: reset, now: now,
                         thresholds: thresholds, alreadyFired: fired)
}

@Test func firesAt48hWhenUnderThreshold() {
    #expect(evaluate(frac: 0.22, now: hoursBefore(47)).map(\.rule) == [.closing48h])
}

@Test func silentAt48hWhenOnTrack() {
    #expect(evaluate(frac: 0.80, now: hoursBefore(47)).isEmpty)
}

@Test func silentBefore48h() {
    #expect(evaluate(frac: 0.05, now: hoursBefore(72)).isEmpty)
}

@Test func firesAt24hWhenUnderItsThreshold() {
    let alerts = evaluate(frac: 0.60, now: hoursBefore(23), fired: [.closing48h])
    #expect(alerts.map(\.rule) == [.closing24h])
}

@Test func alreadyFiredRulesAreNotRepeated() {
    #expect(evaluate(frac: 0.22, now: hoursBefore(47), fired: [.closing48h]).isEmpty)
}

@Test func bothRulesCanFireOnTheSamePollAfterAGap() {
    // Machine asleep from 72h to 20h before the reset.
    let alerts = evaluate(frac: 0.10, now: hoursBefore(20))
    #expect(Set(alerts.map(\.rule)) == [.closing48h, .closing24h])
}

@Test func silentAfterTheResetHasPassed() {
    #expect(evaluate(frac: 0.10, now: reset.addingTimeInterval(60)).isEmpty)
}

@Test func missingFractionFiresNothing() {
    #expect(evaluate(frac: nil, now: hoursBefore(23)).isEmpty)
}

@Test func missingResetsAtFiresNothing() {
    let alerts = AlertEngine.evaluate(
        weeklyFraction: 0.1, resetsAt: nil, now: hoursBefore(23),
        thresholds: .default, alreadyFired: [])
    #expect(alerts.isEmpty)
}

@Test func headroomRuleIsOffByDefault() {
    #expect(AlertThresholds.default.headroomEnabled == false)
}



@Test func customThresholdsAreRespected() {
    var t = AlertThresholds.default
    t.closing48hPct = 10
    #expect(evaluate(frac: 0.22, now: hoursBefore(47), thresholds: t).isEmpty)
}
