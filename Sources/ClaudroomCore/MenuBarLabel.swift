import Foundation

/// What the menu bar shows.
///
/// The number is always the **5-hour session** window, never the week. The two
/// limiters answer different questions and swapping between them in one slot made
/// the figure ambiguous: 54% could mean "half my week" or "half my session", and
/// the icon was carrying more meaning than an icon can.
///
/// Weekly capacity lives in the popover. The one weekly condition still worth the
/// menu bar is a cycle about to close under-used — that is the thing the app
/// exists to catch, and it would be lost entirely if weekly moved out wholesale.
/// It takes the icon; the number still reports the session.
///
/// When no session figure exists — no window running, or the API not reporting a
/// 5-hour limiter at all, as it does for some accounts — the slot falls back to
/// the week, marked `wk` so the two can never be confused. A bare dash there
/// left the menu bar empty for days on accounts with no 5-hour window.
///
/// Every case reports capacity *remaining*, never spend.
public enum MenuBarLabel: Sendable, Equatable {
    case notSignedIn
    case stale
    /// A 5-hour window is running.
    case sessionActive(remaining: Double, resetsAt: Date)
    /// No window running, so there is no session figure to report, and no week
    /// either.
    case noSession
    /// No session figure; the week's remaining capacity stands in, labelled `wk`.
    case weekOnly(remaining: Double, resetsAt: Date)
    /// The week closes soon with capacity unused. Shows the session number if a
    /// window happens to be running, a dash otherwise, and warns either way.
    case weekClosingUnderused(sessionRemaining: Double?,
                              weeklyRemaining: Double,
                              resetsAt: Date)

    private static func pct(_ f: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, f)) * 100)
    }

    static func shortRemaining(to date: Date, from now: Date) -> String {
        let secs = max(0, date.timeIntervalSince(now))
        let minutes = Int(secs) / 60
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        if days > 0 { return "\(days)d" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    public var text: String {
        switch self {
        case .notSignedIn, .stale, .noSession:
            return "—"
        case .sessionActive(let remaining, _):
            return "\(Self.pct(remaining)) left"
        case .weekOnly(let remaining, _):
            return "\(Self.pct(remaining)) wk"
        case .weekClosingUnderused(let sessionRemaining, let weeklyRemaining, _):
            return sessionRemaining.map { "\(Self.pct($0)) left" } ?? "\(Self.pct(weeklyRemaining)) wk"
        }
    }

    /// Longer form for the tooltip, where there is room to say which limiter this
    /// is and to mention the week the menu bar no longer shows.
    public func tooltip(now: Date) -> String {
        switch self {
        case .notSignedIn:
            return "Not signed in to Claude Code"
        case .stale:
            return "Data is stale"
        case .noSession:
            return "No 5-hour window running — open for weekly capacity"
        case .weekOnly(let remaining, let resetsAt):
            return "No 5-hour window running · \(Self.pct(remaining)) of this week left · resets in \(Self.shortRemaining(to: resetsAt, from: now))"
        case .sessionActive(let remaining, let resetsAt):
            return "\(Self.pct(remaining)) of the 5-hour window left · resets in \(Self.shortRemaining(to: resetsAt, from: now))"
        case .weekClosingUnderused(let sessionRemaining, let weeklyRemaining, let resetsAt):
            let session = sessionRemaining.map { "\(Self.pct($0)) of the 5-hour window left · " } ?? ""
            return session + "\(Self.pct(weeklyRemaining)) of this week still unused, and it resets in \(Self.shortRemaining(to: resetsAt, from: now))"
        }
    }
}

public struct LabelInput: Sendable {
    public let snapshot: UsageSnapshot?
    public let now: Date
    public let isStale: Bool
    public let hasCredentials: Bool
    /// Below this much *used*, with under a day to go, the cycle is closing wasted.
    public let underusedThresholdPct: Double

    public init(snapshot: UsageSnapshot?, now: Date, isStale: Bool,
                hasCredentials: Bool, underusedThresholdPct: Double) {
        self.snapshot = snapshot
        self.now = now
        self.isStale = isStale
        self.hasCredentials = hasCredentials
        self.underusedThresholdPct = underusedThresholdPct
    }
}

public enum MenuBarLabelSelector {
    public static func select(_ input: LabelInput) -> MenuBarLabel {
        guard input.hasCredentials else { return .notSignedIn }
        if input.isStale { return .stale }
        guard let snapshot = input.snapshot else { return .stale }

        // A session window is running only once started and before it resets.
        var sessionRemaining: Double?
        var sessionResetsAt: Date?
        if let five = snapshot.fiveHour, five.isActive(at: input.now),
           let resetsAt = five.resetsAt {
            sessionRemaining = 1 - five.fraction
            sessionResetsAt = resetsAt
        }

        // Checked before the session case so the warning is never suppressed by a
        // window happening to be open — the closing week is the more urgent fact,
        // and the session number rides along inside it.
        if let weekly = snapshot.weekly, let weeklyResetsAt = weekly.resetsAt {
            let hoursLeft = weeklyResetsAt.timeIntervalSince(input.now) / 3600
            if hoursLeft > 0, hoursLeft <= 24,
               weekly.fraction * 100 < input.underusedThresholdPct {
                return .weekClosingUnderused(sessionRemaining: sessionRemaining,
                                             weeklyRemaining: 1 - weekly.fraction,
                                             resetsAt: weeklyResetsAt)
            }
        }

        if let remaining = sessionRemaining, let resetsAt = sessionResetsAt {
            return .sessionActive(remaining: remaining, resetsAt: resetsAt)
        }
        if let weekly = snapshot.weekly, let resetsAt = weekly.resetsAt {
            return .weekOnly(remaining: 1 - weekly.fraction, resetsAt: resetsAt)
        }
        return .noSession
    }
}
