import Foundation

public enum AlertRule: String, Sendable, CaseIterable {
    case closing48h      = "closing_48h"
    case closing24h      = "closing_24h"
    case headroom        = "headroom"
    case session80       = "session_80"
    case session90       = "session_90"
    case sessionCapped   = "session_capped"
}

public struct AlertThresholds: Sendable, Equatable {
    public var closing48hPct: Double
    public var closing24hPct: Double
    public var headroomEnabled: Bool

    public init(closing48hPct: Double, closing24hPct: Double, headroomEnabled: Bool) {
        self.closing48hPct = closing48hPct
        self.closing24hPct = closing24hPct
        self.headroomEnabled = headroomEnabled
    }

    /// Two 5-hour warnings rather than one. 80% is early enough to act on —
    /// switch model, or stop before the window closes on you — and 90% is the
    /// last point at which stopping is still a decision rather than an outcome.
    public var session80Pct: Double = 80
    public var session90Pct: Double = 90
    public var sessionAlertsEnabled: Bool = true

    public static let `default` = AlertThresholds(
        closing48hPct: 50, closing24hPct: 70, headroomEnabled: false)
}

public struct PendingAlert: Sendable, Equatable {
    public let rule: AlertRule
    public let title: String
    public let body: String
    /// Rules this alert stands in for, to be recorded as fired without notifying.
    ///
    /// Usage can jump from 70% to 92% between two polls. Firing 80% and 90%
    /// together would double-notify for one event; firing only 90% and leaving
    /// 80% unfired would let it arrive on the next poll, reading as though usage
    /// had gone backwards. So the higher alert consumes the lower.
    public let supersedes: [AlertRule]

    public init(rule: AlertRule, title: String, body: String,
                supersedes: [AlertRule] = []) {
        self.rule = rule
        self.title = title
        self.body = body
        self.supersedes = supersedes
    }
}

/// Pure. Dedupe state arrives as `alreadyFired`; persisting it is the caller's job.
///
/// Mid-cycle linear-pace alerting is deliberately absent: the weekly cycle resets
/// mid-week, and weekday-shaped usage would trigger constant false alarms. Alerts
/// only fire near the close, where "you will not use this" is actually knowable.
public enum AlertEngine {
    public static func evaluate(weeklyFraction: Double?,
                                resetsAt: Date?,
                                now: Date,
                                thresholds: AlertThresholds,
                                alreadyFired: Set<AlertRule>) -> [PendingAlert] {
        guard let frac = weeklyFraction, let resetsAt else { return [] }
        let hoursLeft = resetsAt.timeIntervalSince(now) / 3600
        guard hoursLeft > 0 else { return [] }

        let pct = frac * 100
        var out: [PendingAlert] = []


        if hoursLeft <= 48, pct < thresholds.closing48hPct,
           !alreadyFired.contains(.closing48h) {
            out.append(PendingAlert(
                rule: .closing48h,
                title: "2 days left in this cycle",
                body: String(format: "You've used %.0f%% of this week's capacity.", pct)))
        }

        if hoursLeft <= 24, pct < thresholds.closing24hPct,
           !alreadyFired.contains(.closing24h) {
            out.append(PendingAlert(
                rule: .closing24h,
                title: "Cycle resets tomorrow",
                body: String(format: "You've used %.0f%% of this week's capacity.", pct)))
        }

        return out
    }

    /// Alerts about the 5-hour window, which bites on a scale of minutes rather
    /// than days. Deduped per window, keyed on its reset timestamp.
    ///
    /// Advice differs by which limiter is binding: with a quiet week the fix is
    /// model choice or a pause, whereas a stretched week means the plan itself is
    /// the constraint and pacing will not rescue it.
    public static func evaluateSession(fiveHour: UsageSnapshot.Window?,
                                       weeklyFraction: Double?,
                                       now: Date,
                                       dominantModel: String?,
                                       thresholds: AlertThresholds,
                                       alreadyFired: Set<AlertRule>) -> [PendingAlert] {
        guard thresholds.sessionAlertsEnabled,
              let fiveHour,
              let resetsAt = fiveHour.resetsAt,
              resetsAt > now
        else { return [] }

        let pct = fiveHour.fraction * 100
        let minutesLeft = Int(resetsAt.timeIntervalSince(now) / 60)
        let resetText = minutesLeft >= 60
            ? "\(minutesLeft / 60)h \(minutesLeft % 60)m"
            : "\(minutesLeft)m"

        if pct >= 99, !alreadyFired.contains(.sessionCapped) {
            return [PendingAlert(
                rule: .sessionCapped,
                title: "5-hour window exhausted",
                body: "Resets in \(resetText).",
                supersedes: [.session80, .session90])]
        }

        // Highest crossed threshold wins; see PendingAlert.supersedes.
        let rule: AlertRule
        let title: String
        let superseded: [AlertRule]
        if pct >= thresholds.session90Pct, !alreadyFired.contains(.session90) {
            rule = .session90
            title = "5-hour window at 90%"
            superseded = [.session80]
        } else if pct >= thresholds.session80Pct, !alreadyFired.contains(.session80) {
            rule = .session80
            title = "5-hour window at 80%"
            superseded = []
        } else {
            return []
        }

        var body = String(format: "%.0f%% used, resets in %@.", pct, resetText)

        // Which limiter is binding changes the advice completely: a quiet week
        // means pacing or a lighter model still helps, a stretched one means the
        // plan is the ceiling and pacing will not rescue it.
        let weeklyIsQuiet = (weeklyFraction ?? 1) < SessionAdvisor.weeklyHighFraction
        if weeklyIsQuiet {
            body += " Your week still has room, so this is the rate limiter"
            if let dominantModel {
                body += " — routine work on \(SessionAdvisor.lighterModels.joined(separator: " or "))"
                     + " would stretch it, keeping \(dominantModel) for what needs it."
            } else {
                body += " rather than your plan."
            }
        } else {
            body += " Your week is stretched too — this is your plan's ceiling, not pacing."
        }

        return [PendingAlert(rule: rule, title: title, body: body,
                             supersedes: superseded)]
    }
}
