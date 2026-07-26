import Testing
import Foundation
@testable import ClaudroomCore

private let cycleStart = Date(timeIntervalSince1970: 1_784_800_000)
private let cycleEnd = cycleStart.addingTimeInterval(168 * 3600)

private func hour(_ offset: Int) -> Date {
    cycleStart.addingTimeInterval(Double(offset) * 3600)
}

@Test func buildsOneBucketPerHourOfTheCycle() {
    let buckets = ActivityTimeline.buckets(from: cycleStart, to: cycleEnd,
                                           now: hour(24), usage: [:])
    #expect(buckets.count == 168)
    #expect(buckets.first?.hour == cycleStart)
}

@Test func idleHoursOccupySpaceRatherThanCollapsing() {
    // Two active hours in a week; the other 166 must still exist as buckets.
    let usage = [hour(3): 500, hour(50): 900]
    let buckets = ActivityTimeline.buckets(from: cycleStart, to: cycleEnd,
                                           now: cycleEnd, usage: usage)
    #expect(buckets.count == 168)
    #expect(ActivityTimeline.activeHours(buckets) == 2)
    #expect(ActivityTimeline.idleElapsedHours(buckets) == 166)
}

@Test func futureHoursAreNotCountedAsIdleWaste() {
    // now == hour(10), and a bucket exactly at now counts as elapsed, so buckets
    // 0...10 have happened — eleven of them. One is active, leaving ten idle.
    // The remaining 157 have not happened yet and so are not waste.
    let buckets = ActivityTimeline.buckets(from: cycleStart, to: cycleEnd,
                                           now: hour(10), usage: [hour(1): 100])
    #expect(ActivityTimeline.idleElapsedHours(buckets) == 10)
    #expect(buckets.filter(\.isFuture).count == 157)
    #expect(ActivityTimeline.activeHours(buckets) == 1)
}

@Test func activityIsAttributedToTheRightHour() {
    let buckets = ActivityTimeline.buckets(from: cycleStart, to: cycleEnd,
                                           now: cycleEnd, usage: [hour(5): 4242])
    #expect(buckets[5].outputTokens == 4242)
    #expect(buckets[5].isActive)
    #expect(buckets[4].isActive == false)
    #expect(buckets[6].isActive == false)
}

@Test func peakIsTheLargestHour() {
    let usage = [hour(1): 10, hour(2): 9999, hour(3): 500]
    let buckets = ActivityTimeline.buckets(from: cycleStart, to: cycleEnd,
                                           now: cycleEnd, usage: usage)
    #expect(ActivityTimeline.peakTokens(buckets) == 9999)
}

@Test func peakOfAnEmptyCycleIsZeroNotACrash() {
    let buckets = ActivityTimeline.buckets(from: cycleStart, to: cycleEnd,
                                           now: cycleStart, usage: [:])
    #expect(ActivityTimeline.peakTokens(buckets) == 0)
    #expect(ActivityTimeline.activeHours(buckets) == 0)
}

@Test func invertedRangeYieldsNothing() {
    #expect(ActivityTimeline.buckets(from: cycleEnd, to: cycleStart,
                                     now: cycleStart, usage: [:]).isEmpty)
}

@Test func absurdRangeIsRejectedRatherThanAllocated() {
    // A corrupt reset timestamp must not produce a million buckets.
    let farFuture = cycleStart.addingTimeInterval(100_000 * 3600)
    #expect(ActivityTimeline.buckets(from: cycleStart, to: farFuture,
                                     now: cycleStart, usage: [:]).isEmpty)
}

@Test func anHourExactlyAtNowIsNotFuture() {
    let buckets = ActivityTimeline.buckets(from: cycleStart, to: cycleEnd,
                                           now: hour(4), usage: [:])
    #expect(buckets[4].isFuture == false)
    #expect(buckets[5].isFuture)
}
