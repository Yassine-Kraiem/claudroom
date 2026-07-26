import Foundation

public enum PlanTier: String, Sendable, Equatable, CaseIterable {
    case pro    = "default_pro"
    case max5x  = "default_claude_max_5x"
    case max20x = "default_claude_max_20x"

    /// Capacity relative to Pro. Approximate — these are Anthropic's plan names,
    /// not a published capacity ratio. Surfaced as approximate in the UI.
    public var multiplier: Double {
        switch self {
        case .pro:    return 1
        case .max5x:  return 5
        case .max20x: return 20
        }
    }


    public var displayName: String {
        switch self {
        case .pro:    return "Pro"
        case .max5x:  return "Max 5x"
        case .max20x: return "Max 20x"
        }
    }

    /// Returns nil for unrecognised tiers. Callers must suppress plan-dependent
    /// features rather than guessing.
    public static func from(rawTier: String) -> PlanTier? {
        PlanTier(rawValue: rawTier)
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        /// 0…1, never a percent. The API reports 0…100; conversion happens once,
        /// in UsageDecoder.
        public let fraction: Double
        /// Nil when no window is currently running. The API returns
        /// `{"utilization": 0.0, "resets_at": null}` for a 5-hour window that has
        /// reset and not yet been restarted — a real state, not missing data.
        public let resetsAt: Date?

        public init(fraction: Double, resetsAt: Date?) {
            self.fraction = fraction
            self.resetsAt = resetsAt
        }

        /// Running only if it has been started and has a known reset ahead of `now`.
        public func isActive(at now: Date) -> Bool {
            guard let resetsAt else { return false }
            return fraction > 0 && resetsAt > now
        }
    }

    public struct ScopedLimit: Sendable, Equatable {
        public let kind: String
        public let modelDisplayName: String?
        public let fraction: Double
        public let resetsAt: Date?

        public init(kind: String, modelDisplayName: String?, fraction: Double, resetsAt: Date?) {
            self.kind = kind
            self.modelDisplayName = modelDisplayName
            self.fraction = fraction
            self.resetsAt = resetsAt
        }
    }

    public let observedAt: Date
    public let fiveHour: Window?
    public let weekly: Window?
    public let scopedLimits: [ScopedLimit]
    public let extraUsageEnabled: Bool
    /// False when any expected field was missing or wrong-typed.
    public let schemaOK: Bool
    public let rawJSON: String

    public init(observedAt: Date, fiveHour: Window?, weekly: Window?,
                scopedLimits: [ScopedLimit], extraUsageEnabled: Bool,
                schemaOK: Bool, rawJSON: String) {
        self.observedAt = observedAt
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.scopedLimits = scopedLimits
        self.extraUsageEnabled = extraUsageEnabled
        self.schemaOK = schemaOK
        self.rawJSON = rawJSON
    }
}
