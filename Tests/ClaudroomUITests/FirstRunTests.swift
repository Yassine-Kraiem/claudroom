import Testing
import Foundation
import ClaudroomCore
@testable import ClaudroomUI

/// What someone sees the first time they clone this and run it: no database, no
/// samples, no transcripts scanned yet.
///
/// Every other test starts from seeded state, so this is the one path that
/// nothing else covers — and it is the only path a new user is guaranteed to hit.
@MainActor
@Suite struct FirstRunTests {

    /// Never reached: `autoStart: false` means no poll runs.
    private struct UnusedClient: UsageFetching {
        func fetchUsage(token: String, now: Date) async throws -> UsageSnapshot {
            throw UsageClientError.transport
        }
        func fetchProfile(token: String) async throws -> Profile {
            throw UsageClientError.transport
        }
    }

    private func emptyStoreDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudroom-firstrun-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    @Test func startsCleanlyAgainstADirectoryThatDoesNotExistYet() {
        let dir = emptyStoreDirectory()
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        // Creating the store directory is the app's job, not the installer's.
        let model = AppModel(client: UnusedClient(), storeDirectory: dir, autoStart: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(model.snapshot == nil)
        #expect(model.label == .stale)
    }

    /// The dashboard is reachable before anything has been recorded, so every
    /// derived figure has to hold up with no rows behind it rather than dividing
    /// by a total of zero or unwrapping an empty range.
    @Test func theDashboardHoldsUpWithNothingRecorded() {
        let dir = emptyStoreDirectory()
        let model = AppModel(client: UnusedClient(), storeDirectory: dir, autoStart: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        model.loadActivity()

        #expect(model.projectUsage.isEmpty)
        #expect(model.lifetimeModelUsage.isEmpty)
        #expect(model.dailyActivity.isEmpty)
        #expect(model.modelTotals.isEmpty)
        #expect(model.selectedProject == nil)
        #expect(model.activityFirstDay == nil)
        #expect(model.activeDays == 0)
        #expect(model.totalAPICost == 0)
        #expect(model.unpricedTokens == 0)
        #expect(model.cycleActivity().isEmpty)
        #expect(model.fieldIntensities.allSatisfy { $0.isFinite })
    }

    @Test func selectingAProjectThatHasNoDataIsANoOp() {
        let dir = emptyStoreDirectory()
        let model = AppModel(client: UnusedClient(), storeDirectory: dir, autoStart: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        model.loadActivity()
        model.selectProject("nothing-here")
        #expect(model.selectedProject == nil)
    }

    /// Switching range on an empty install must not resurrect state or crash on
    /// the window resolution, which has no recorded bounds to clamp against.
    @Test func everyRangeIsSafeBeforeAnythingIsRecorded() {
        let dir = emptyStoreDirectory()
        let model = AppModel(client: UnusedClient(), storeDirectory: dir, autoStart: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        for range in DashboardRange.allCases {
            model.setRange(range)
            #expect(model.range == range)
            #expect(model.projectUsage.isEmpty)
            #expect(model.totalAPICost == 0)
        }
    }

    /// The menu bar has to render before any credential has been read.
    @Test func theMenuBarMarkRendersWithNoData() {
        let model = MenuBarGlyph.image(for: .stale)
        #expect(model.tiffRepresentation != nil)
        #expect(MenuBarLabel.stale.text == "—")
    }
}
