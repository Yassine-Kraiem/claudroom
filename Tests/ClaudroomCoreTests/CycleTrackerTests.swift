import Testing
import Foundation
@testable import ClaudroomCore

private let reset1 = Date(timeIntervalSince1970: 1_785_000_000)
private let reset2 = reset1.addingTimeInterval(7 * 86400)

private func snap(weekly: Double?, resetsAt: Date?, observedAt: Date) -> UsageSnapshot {
    UsageSnapshot(
        observedAt: observedAt,
        fiveHour: nil,
        weekly: (weekly != nil && resetsAt != nil)
            ? .init(fraction: weekly!, resetsAt: resetsAt!) : nil,
        scopedLimits: [], extraUsageEnabled: false, schemaOK: true, rawJSON: "{}")
}

@Test func firstSampleOpensACycle() {
    let r = CycleTracker.reconcile(
        open: nil,
        snapshot: snap(weekly: 0.1, resetsAt: reset1, observedAt: reset1.addingTimeInterval(-3600)),
        planTier: "default_claude_max_5x", pollInterval: 60)
    #expect(r.toClose == nil)
    #expect(r.open.resetsAt == reset1)
    #expect(r.open.closed == false)
    #expect(r.open.finalUtilizationFrac == 0.1)
}

@Test func sameCycleUpdatesInPlace() {
    let open = Cycle(resetsAt: reset1, planTier: "t", finalUtilizationFrac: 0.1,
                     closed: false, inferred: false,
                     lastObservedAt: reset1.addingTimeInterval(-7200))
    let r = CycleTracker.reconcile(
        open: open,
        snapshot: snap(weekly: 0.3, resetsAt: reset1, observedAt: reset1.addingTimeInterval(-3600)),
        planTier: "t", pollInterval: 60)
    #expect(r.toClose == nil)
    #expect(r.open.resetsAt == reset1)
    #expect(r.open.finalUtilizationFrac == 0.3)
}

@Test func changedResetsAtClosesPriorCycle() {
    let open = Cycle(resetsAt: reset1, planTier: "t", finalUtilizationFrac: 0.42,
                     closed: false, inferred: false,
                     lastObservedAt: reset1.addingTimeInterval(-30))
    let r = CycleTracker.reconcile(
        open: open,
        snapshot: snap(weekly: 0.02, resetsAt: reset2, observedAt: reset1.addingTimeInterval(60)),
        planTier: "t", pollInterval: 60)
    #expect(r.toClose?.resetsAt == reset1)
    #expect(r.toClose?.closed == true)
    #expect(r.toClose?.finalUtilizationFrac == 0.42)
    #expect(r.open.resetsAt == reset2)
    #expect(r.open.finalUtilizationFrac == 0.02)
}

@Test func closeIsExactWhenLastSampleIsRecent() {
    let open = Cycle(resetsAt: reset1, planTier: "t", finalUtilizationFrac: 0.42,
                     closed: false, inferred: false,
                     lastObservedAt: reset1.addingTimeInterval(-30))
    let r = CycleTracker.reconcile(
        open: open,
        snapshot: snap(weekly: 0.0, resetsAt: reset2, observedAt: reset1.addingTimeInterval(60)),
        planTier: "t", pollInterval: 60)
    #expect(r.toClose?.inferred == false)
}

@Test func closeIsInferredAfterALongGap() {
    // Machine asleep for two days across the reset.
    let open = Cycle(resetsAt: reset1, planTier: "t", finalUtilizationFrac: 0.22,
                     closed: false, inferred: false,
                     lastObservedAt: reset1.addingTimeInterval(-2 * 86400))
    let r = CycleTracker.reconcile(
        open: open,
        snapshot: snap(weekly: 0.0, resetsAt: reset2, observedAt: reset1.addingTimeInterval(86400)),
        planTier: "t", pollInterval: 60)
    #expect(r.toClose?.inferred == true)
    #expect(r.toClose?.finalUtilizationFrac == 0.22)
}

@Test func missingWeeklyWindowLeavesCycleUntouched() {
    let open = Cycle(resetsAt: reset1, planTier: "t", finalUtilizationFrac: 0.42,
                     closed: false, inferred: false, lastObservedAt: reset1)
    let r = CycleTracker.reconcile(
        open: open,
        snapshot: snap(weekly: nil, resetsAt: nil, observedAt: reset1.addingTimeInterval(60)),
        planTier: "t", pollInterval: 60)
    #expect(r.toClose == nil)
    #expect(r.open == open)
}

@Test func planTierChangeIsRecordedOnTheNewCycle() {
    let open = Cycle(resetsAt: reset1, planTier: "default_claude_max_5x",
                     finalUtilizationFrac: 0.9, closed: false, inferred: false,
                     lastObservedAt: reset1)
    let r = CycleTracker.reconcile(
        open: open,
        snapshot: snap(weekly: 0.05, resetsAt: reset2, observedAt: reset1.addingTimeInterval(60)),
        planTier: "default_claude_max_20x", pollInterval: 60)
    #expect(r.toClose?.planTier == "default_claude_max_5x")
    #expect(r.open.planTier == "default_claude_max_20x")
}

@Test func cycleStartIsSevenDaysBeforeReset() {
    let c = Cycle(resetsAt: reset2, planTier: "t", finalUtilizationFrac: nil,
                  closed: false, inferred: false, lastObservedAt: nil)
    #expect(c.startedAt == reset1)
}
