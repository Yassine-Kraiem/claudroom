import Testing
import Foundation
@testable import ClaudroomCore

private let now = Date(timeIntervalSince1970: 1_785_000_000)

private func snapshot(five: Double?, fiveResets: Date?,
                      weekly: Double?, weeklyResets: Date?) -> UsageSnapshot {
    UsageSnapshot(
        observedAt: now,
        fiveHour: (five != nil && fiveResets != nil)
            ? .init(fraction: five!, resetsAt: fiveResets!) : nil,
        weekly: (weekly != nil && weeklyResets != nil)
            ? .init(fraction: weekly!, resetsAt: weeklyResets!) : nil,
        scopedLimits: [], extraUsageEnabled: false, schemaOK: true, rawJSON: "{}")
}

private func input(_ snap: UsageSnapshot?, stale: Bool = false,
                   creds: Bool = true) -> LabelInput {
    LabelInput(snapshot: snap, now: now, isStale: stale,
               hasCredentials: creds, underusedThresholdPct: 70)
}

@Test func noCredentialsShowsSignInState() {
    #expect(MenuBarLabelSelector.select(input(nil, creds: false)) == .notSignedIn)
}

@Test func staleWinsOverEverythingButCredentials() {
    let s = snapshot(five: 0.31, fiveResets: now.addingTimeInterval(3600),
                     weekly: 0.14, weeklyResets: now.addingTimeInterval(86400))
    #expect(MenuBarLabelSelector.select(input(s, stale: true)) == .stale)
}

@Test func activeSessionShowsSessionRemaining() {
    let resets = now.addingTimeInterval(2 * 3600 + 14 * 60)
    let s = snapshot(five: 0.31, fiveResets: resets,
                     weekly: 0.14, weeklyResets: now.addingTimeInterval(5 * 86400))
    let remaining: Double = 1 - 0.31
    #expect(MenuBarLabelSelector.select(input(s))
            == .sessionActive(remaining: remaining, resetsAt: resets))
}

@Test func expiredSessionWindowReportsNoSession() {
    let s = snapshot(five: 0.31, fiveResets: now.addingTimeInterval(-60),
                     weekly: 0.14, weeklyResets: now.addingTimeInterval(5 * 86400))
    #expect(MenuBarLabelSelector.select(input(s)) == .noSession)
}

@Test func zeroSessionUsageReportsNoSession() {
    let s = snapshot(five: 0.0, fiveResets: now.addingTimeInterval(3600),
                     weekly: 0.14, weeklyResets: now.addingTimeInterval(5 * 86400))
    #expect(MenuBarLabelSelector.select(input(s)) == .noSession)
}

/// The menu bar never reports the week as its number, however much of it is left.
@Test func aHealthyWeekWithNoSessionIsStillADash() {
    let s = snapshot(five: nil, fiveResets: nil,
                     weekly: 0.14, weeklyResets: now.addingTimeInterval(5 * 86400))
    let label = MenuBarLabelSelector.select(input(s))
    #expect(label == .noSession)
    #expect(label.text == "\u{2014}")
}

@Test func finalDayUnderThresholdShowsWarning() {
    let resets = now.addingTimeInterval(20 * 3600)
    let s = snapshot(five: nil, fiveResets: nil, weekly: 0.22, weeklyResets: resets)
    let weeklyRemaining: Double = 1 - 0.22
    #expect(MenuBarLabelSelector.select(input(s))
            == .weekClosingUnderused(sessionRemaining: nil,
                                     weeklyRemaining: weeklyRemaining,
                                     resetsAt: resets))
}

/// The warning is the more urgent fact, so an open session must not hide it —
/// but the number stays the session's.
@Test func warningSurvivesAnOpenSessionAndStillReportsTheSession() {
    let resets = now.addingTimeInterval(20 * 3600)
    let s = snapshot(five: 0.40, fiveResets: now.addingTimeInterval(3600),
                     weekly: 0.22, weeklyResets: resets)
    let label = MenuBarLabelSelector.select(input(s))
    let sessionRemaining: Double = 1 - 0.40
    let weeklyRemaining: Double = 1 - 0.22
    let expected = MenuBarLabel.weekClosingUnderused(sessionRemaining: sessionRemaining,
                                                     weeklyRemaining: weeklyRemaining,
                                                     resetsAt: resets)
    #expect(label == expected)
    #expect(label.text == "60% left")
}

@Test func finalDayOnTrackDoesNotWarn() {
    let s = snapshot(five: nil, fiveResets: nil,
                     weekly: 0.85, weeklyResets: now.addingTimeInterval(20 * 3600))
    #expect(MenuBarLabelSelector.select(input(s)) == .noSession)
}

@Test func warningDoesNotFireMoreThanADayOut() {
    let s = snapshot(five: nil, fiveResets: nil,
                     weekly: 0.10, weeklyResets: now.addingTimeInterval(3 * 86400))
    #expect(MenuBarLabelSelector.select(input(s)) == .noSession)
}

@Test func labelReportsRemainingNotSpend() {
    #expect(MenuBarLabel.sessionActive(remaining: 0.69, resetsAt: now).text == "69% left")
    #expect(MenuBarLabel.notSignedIn.text == "\u{2014}")
    #expect(MenuBarLabel.stale.text == "\u{2014}")
    #expect(MenuBarLabel.noSession.text == "\u{2014}")
}

@Test func labelCarriesNoMoneyFigure() {
    let texts = [
        MenuBarLabel.sessionActive(remaining: 0.5, resetsAt: now).text,
        MenuBarLabel.noSession.text,
        MenuBarLabel.weekClosingUnderused(sessionRemaining: 0.5, weeklyRemaining: 0.5,
                                          resetsAt: now).text,
    ]
    #expect(texts.allSatisfy { !$0.contains("$") && !$0.contains("\u{20AC}") })
}

@Test func percentIsClampedToSaneRange() {
    #expect(MenuBarLabel.sessionActive(remaining: -0.2, resetsAt: now).text == "0% left")
    #expect(MenuBarLabel.sessionActive(remaining: 1.4, resetsAt: now).text == "100% left")
}

@Test func tooltipNamesWhichWindowItIsTalkingAbout() {
    let session = MenuBarLabel.sessionActive(remaining: 0.5,
                                             resetsAt: now.addingTimeInterval(7200))
    #expect(session.tooltip(now: now).contains("5-hour"))
    #expect(session.tooltip(now: now).contains("2h"))

    // Weekly is gone from the menu bar text, but the tooltip still explains the
    // warning — otherwise a bare triangle says nothing.
    let closing = MenuBarLabel.weekClosingUnderused(sessionRemaining: nil,
                                                    weeklyRemaining: 0.5,
                                                    resetsAt: now.addingTimeInterval(3 * 86400))
    #expect(closing.tooltip(now: now).contains("this week"))
    #expect(closing.tooltip(now: now).contains("3d"))

    #expect(MenuBarLabel.noSession.tooltip(now: now).contains("weekly"))
}
