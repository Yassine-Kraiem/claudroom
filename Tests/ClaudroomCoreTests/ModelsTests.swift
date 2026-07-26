import Testing
import Foundation
@testable import ClaudroomCore

@Test func planTierMapsKnownTiers() {
    #expect(PlanTier.from(rawTier: "default_claude_max_5x") == .max5x)
    #expect(PlanTier.from(rawTier: "default_claude_max_20x") == .max20x)
    #expect(PlanTier.from(rawTier: "default_pro") == .pro)
}

@Test func planTierRejectsUnknownTier() {
    #expect(PlanTier.from(rawTier: "default_claude_max_50x") == nil)
    #expect(PlanTier.from(rawTier: "") == nil)
}

@Test func planTierCarriesCapacityMultiplier() {
    #expect(PlanTier.pro.multiplier == 1)
    #expect(PlanTier.max5x.multiplier == 5)
    #expect(PlanTier.max20x.multiplier == 20)
}
