import Testing
import Foundation
@testable import ClaudroomCore

private let cycleStart = Date(timeIntervalSince1970: 1_784_800_000)
private let cycleEnd = cycleStart.addingTimeInterval(7 * 86400)

// MARK: - Cycle pace

@Test func projectsCloseFromPaceSoFar() {
    // Halfway through the cycle at 25% -> heading for 50%.
    let pace = UsageInsights.cyclePace(cycleStart: cycleStart, cycleEnd: cycleEnd,
                                       now: cycleStart.addingTimeInterval(3.5 * 86400),
                                       utilization: 0.25)
    #expect(pace != nil)
    #expect(abs((pace?.projectedClose ?? 0) - 0.5) < 0.01)
    #expect(abs((pace?.elapsedFraction ?? 0) - 0.5) < 0.01)
}

@Test func refusesToProjectTooEarlyInTheCycle() {
    // Two hours in, extrapolation would be absurd — better to say nothing.
    #expect(UsageInsights.cyclePace(cycleStart: cycleStart, cycleEnd: cycleEnd,
                                    now: cycleStart.addingTimeInterval(7200),
                                    utilization: 0.05) == nil)
}

@Test func projectionCanExceedFullCapacity() {
    // Burning fast: this must report >100%, not silently clamp to a safe-looking value.
    let pace = UsageInsights.cyclePace(cycleStart: cycleStart, cycleEnd: cycleEnd,
                                       now: cycleStart.addingTimeInterval(3.5 * 86400),
                                       utilization: 0.80)
    #expect((pace?.projectedClose ?? 0) > 1.5)
}

@Test func zeroLengthCycleYieldsNoProjection() {
    #expect(UsageInsights.cyclePace(cycleStart: cycleStart, cycleEnd: cycleStart,
                                    now: cycleStart, utilization: 0.5) == nil)
}

// MARK: - Cache health

private func row(read: Int, created: Int) -> ModelUsageRow {
    ModelUsageRow(model: "claude-opus-5", messages: 1, inputTokens: 0, outputTokens: 1,
                  cacheReadTokens: read, cacheCreationTokens: created)
}

@Test func computesCacheReuseShare() {
    let health = UsageInsights.cacheHealth([row(read: 900, created: 100)])
    #expect(abs((health?.reuseFraction ?? 0) - 0.9) < 0.0001)
    #expect(health?.isHealthy == true)
}

@Test func flagsHeavyCacheRebuilding() {
    let health = UsageInsights.cacheHealth([row(read: 100, created: 900)])
    #expect(health?.isHealthy == false)
}

@Test func noCacheTrafficYieldsNoVerdict() {
    #expect(UsageInsights.cacheHealth([row(read: 0, created: 0)]) == nil)
    #expect(UsageInsights.cacheHealth([]) == nil)
}

// MARK: - Hour-of-day profile

private func utcCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

@Test func bucketsActivityByHourOfDay() {
    let cal = utcCalendar()
    let day = Date(timeIntervalSince1970: 1_784_800_000)
    let activity = [
        cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)!: 100,
        cal.date(bySettingHour: 9, minute: 0, second: 0,
                 of: day.addingTimeInterval(86400))!: 50,
        cal.date(bySettingHour: 14, minute: 0, second: 0, of: day)!: 200,
    ]
    let profile = UsageInsights.hourOfDayProfile(activity, calendar: cal)
    #expect(profile.count == 24)
    #expect(profile[9] == 150)     // same hour on two days accumulates
    #expect(profile[14] == 200)
    #expect(profile[3] == 0)
}

@Test func findsTheBusiestContiguousStretch() {
    var profile = [Int](repeating: 0, count: 24)
    for h in 13...17 { profile[h] = 1000 }
    let peak = UsageInsights.peakWindow(profile, width: 5)
    #expect(peak?.start == 13)
    #expect(peak?.end == 17)
}

@Test func peakWindowWrapsAroundMidnight() {
    var profile = [Int](repeating: 0, count: 24)
    for h in [22, 23, 0, 1, 2] { profile[h] = 1000 }
    let peak = UsageInsights.peakWindow(profile, width: 5)
    #expect(peak?.start == 22)
    #expect(peak?.end == 2)
}

@Test func flatActivityHasNoMeaningfulPeak() {
    // Evenly spread work: naming any five hours "your peak" would be noise.
    let profile = [Int](repeating: 100, count: 24)
    #expect(UsageInsights.peakWindow(profile, width: 5) == nil)
}

@Test func emptyProfileHasNoPeak() {
    #expect(UsageInsights.peakWindow([Int](repeating: 0, count: 24)) == nil)
}

// MARK: - Idle days

@Test func countsDaysWithNoActivity() {
    let cal = utcCalendar()
    let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_784_800_000))
    let end = cal.date(byAdding: .day, value: 6, to: start)!   // 7-day span
    let active: Set<Date> = [start, cal.date(byAdding: .day, value: 3, to: start)!]

    #expect(UsageInsights.idleDays(activeDays: active, from: start, to: end,
                                   calendar: cal) == 5)
}

@Test func everyDayActiveMeansNoIdleDays() {
    let cal = utcCalendar()
    let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_784_800_000))
    let end = cal.date(byAdding: .day, value: 2, to: start)!
    let active = Set((0...2).map { cal.date(byAdding: .day, value: $0, to: start)! })
    #expect(UsageInsights.idleDays(activeDays: active, from: start, to: end,
                                   calendar: cal) == 0)
}

@Test func invertedRangeCountsNothing() {
    let cal = utcCalendar()
    let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_784_800_000))
    #expect(UsageInsights.idleDays(activeDays: [], from: start,
                                   to: start.addingTimeInterval(-86400),
                                   calendar: cal) == 0)
}

// MARK: - Session alerts

private let now = Date(timeIntervalSince1970: 1_785_000_000)

private func fiveHour(_ pct: Double, resetsInMinutes: Double) -> UsageSnapshot.Window {
    .init(fraction: pct / 100, resetsAt: now.addingTimeInterval(resetsInMinutes * 60))
}

@Test func warnsAtEightyPercent() {
    let alerts = AlertEngine.evaluateSession(
        fiveHour: fiveHour(82, resetsInMinutes: 90), weeklyFraction: 0.20,
        now: now, dominantModel: "Opus 5",
        thresholds: .default, alreadyFired: [])
    #expect(alerts.map(\.rule) == [.session80])
    #expect(alerts[0].title.contains("80%"))
    #expect(alerts[0].body.contains("Opus 5"))
    #expect(alerts[0].body.contains("rate limiter"))
}

@Test func warnsAgainAtNinetyPercent() {
    // 80% already went out for this window; 90% is a separate event.
    let alerts = AlertEngine.evaluateSession(
        fiveHour: fiveHour(91, resetsInMinutes: 40), weeklyFraction: 0.20,
        now: now, dominantModel: nil,
        thresholds: .default, alreadyFired: [.session80])
    #expect(alerts.map(\.rule) == [.session90])
    #expect(alerts[0].title.contains("90%"))
}

@Test func nothingBetweenTheTwoThresholds() {
    // 85% used to be the single threshold. Having already warned at 80, it must
    // stay quiet until 90 rather than nagging on every poll.
    #expect(AlertEngine.evaluateSession(
        fiveHour: fiveHour(85, resetsInMinutes: 60), weeklyFraction: 0.20,
        now: now, dominantModel: nil,
        thresholds: .default, alreadyFired: [.session80]).isEmpty)
}

/// Usage can jump between polls. One event should send one notification, and the
/// lower threshold must not arrive afterwards reading as though usage fell back.
@Test func aJumpPastBothThresholdsSendsOnlyTheHigherOne() {
    let alerts = AlertEngine.evaluateSession(
        fiveHour: fiveHour(92, resetsInMinutes: 40), weeklyFraction: 0.20,
        now: now, dominantModel: nil,
        thresholds: .default, alreadyFired: [])
    #expect(alerts.map(\.rule) == [.session90])
    #expect(alerts[0].supersedes == [.session80])
}

@Test func aStretchedWeekChangesTheAdvice() {
    let alerts = AlertEngine.evaluateSession(
        fiveHour: fiveHour(82, resetsInMinutes: 90), weeklyFraction: 0.85,
        now: now, dominantModel: "Opus 5",
        thresholds: .default, alreadyFired: [])
    #expect(alerts[0].body.contains("ceiling"))
    #expect(!alerts[0].body.contains("rate limiter"))
}

@Test func cappedOutTakesPrecedenceAndConsumesBothThresholds() {
    let alerts = AlertEngine.evaluateSession(
        fiveHour: fiveHour(100, resetsInMinutes: 30), weeklyFraction: 0.20,
        now: now, dominantModel: nil,
        thresholds: .default, alreadyFired: [])
    #expect(alerts.map(\.rule) == [.sessionCapped])
    #expect(Set(alerts[0].supersedes) == [.session80, .session90])
}

@Test func quietWindowsRaiseNothing() {
    #expect(AlertEngine.evaluateSession(
        fiveHour: fiveHour(40, resetsInMinutes: 200), weeklyFraction: 0.20,
        now: now, dominantModel: nil,
        thresholds: .default, alreadyFired: []).isEmpty)
}

@Test func sevenNinePercentIsBelowTheBar() {
    #expect(AlertEngine.evaluateSession(
        fiveHour: fiveHour(79, resetsInMinutes: 120), weeklyFraction: 0.20,
        now: now, dominantModel: nil,
        thresholds: .default, alreadyFired: []).isEmpty)
}

@Test func eachThresholdFiresOncePerWindow() {
    #expect(AlertEngine.evaluateSession(
        fiveHour: fiveHour(95, resetsInMinutes: 90), weeklyFraction: 0.20,
        now: now, dominantModel: nil,
        thresholds: .default,
        alreadyFired: [.session80, .session90]).isEmpty)
}

@Test func noSessionAlertsWithoutARunningWindow() {
    #expect(AlertEngine.evaluateSession(
        fiveHour: .init(fraction: 0, resetsAt: nil), weeklyFraction: 0.20,
        now: now, dominantModel: nil,
        thresholds: .default, alreadyFired: []).isEmpty)
}

@Test func sessionAlertsCanBeTurnedOff() {
    var thresholds = AlertThresholds.default
    thresholds.sessionAlertsEnabled = false
    #expect(AlertEngine.evaluateSession(
        fiveHour: fiveHour(95, resetsInMinutes: 60), weeklyFraction: 0.20,
        now: now, dominantModel: nil,
        thresholds: thresholds, alreadyFired: []).isEmpty)
}
