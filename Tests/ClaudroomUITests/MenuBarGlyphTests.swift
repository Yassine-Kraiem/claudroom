import Testing
import Foundation
import ClaudroomCore
@testable import ClaudroomUI

@Suite struct MenuBarGlyphTests {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private var everyState: [MenuBarLabel] {
        [.notSignedIn,
         .stale,
         .noSession,
         .weekOnly(remaining: 0.74, resetsAt: now),
         .sessionActive(remaining: 0.54, resetsAt: now),
         .weekClosingUnderused(sessionRemaining: 0.54, weeklyRemaining: 0.7, resetsAt: now)]
    }

    /// The text is an em dash for three of the six states, so the mark is the only
    /// thing telling them apart. Stale and signed-out drew the same empty ring
    /// once already — one clears itself, the other needs `claude` login.
    @Test func everyStateIsVisuallyDistinct() {
        let drawn = everyState.map { label -> String in
            let s = MenuBarGlyph.state(for: label)
            return "\(s.remaining.map { String(format: "%.3f", $0) } ?? "nil")|\(s.warning)|\(s.mode)"
        }
        #expect(Set(drawn).count == everyState.count,
                "two states render identically: \(drawn)")
    }

    @Test func theRingReadsTheSessionNotTheWeek() {
        let s = MenuBarGlyph.state(for: .weekClosingUnderused(sessionRemaining: 0.25,
                                                              weeklyRemaining: 0.9,
                                                              resetsAt: now))
        // 0.9 of the week is unused, but the arc must show the session's 0.25.
        #expect(s.remaining == 0.25)
        #expect(s.warning)
    }

    /// Nothing to report draws an empty ring, not a full one — a full ring would
    /// claim a fresh window that is not actually running.
    @Test func nothingToReportIsEmptyNotFull() {
        #expect(MenuBarGlyph.state(for: .noSession).remaining == nil)
    }

    /// Without a session the ring follows the week, as the `wk` text does.
    @Test func absentSessionRingFollowsTheWeek() {
        #expect(MenuBarGlyph.state(for: .weekOnly(remaining: 0.74, resetsAt: now)).remaining == 0.74)
        #expect(MenuBarGlyph.state(for: .weekClosingUnderused(sessionRemaining: nil,
                                                              weeklyRemaining: 0.7,
                                                              resetsAt: now)).remaining == 0.7)
    }

    @Test func rendersAtMenuBarSizeForEveryState() {
        for label in everyState {
            let image = MenuBarGlyph.image(for: label)
            #expect(image.size.width == MenuBarGlyph.size)
            // A template image would be flattened to one tint, collapsing the used
            // and remaining arcs into a single shade.
            #expect(!image.isTemplate)
            #expect(image.tiffRepresentation != nil, "\(label) failed to rasterise")
        }
    }
}
