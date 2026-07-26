import Foundation

public struct BurnRate: Sendable, Equatable {
    /// Utilization fraction consumed per hour. 0.023 == 2.3 %/h.
    public let perHour: Double
    public let sampleCount: Int
    public let spanHours: Double

    public init(perHour: Double, sampleCount: Int, spanHours: Double) {
        self.perHour = perHour
        self.sampleCount = sampleCount
        self.spanHours = spanHours
    }
}

public enum BurnEstimator {
    /// Minimum observation span before a slope means anything.
    static let minimumSpan: TimeInterval = 5 * 60
    static let minimumSamples = 3

    /// Least-squares slope of utilization against time.
    ///
    /// A slope rather than an endpoint difference because the API reports whole
    /// percentages: consecutive samples often differ by 0 or 1, so two endpoints
    /// would quantise the answer badly. Regression averages that noise out.
    ///
    /// Samples must all belong to the same window — a reset partway through would
    /// otherwise read as a large negative burn. `SessionAdvisor` enforces that by
    /// filtering on the window's reset timestamp.
    public static func estimate(samples: [(at: Date, fraction: Double)],
                                now: Date,
                                lookback: TimeInterval = 45 * 60) -> BurnRate? {
        let cutoff = now.addingTimeInterval(-lookback)
        let points = samples.filter { $0.at >= cutoff }.sorted { $0.at < $1.at }
        guard points.count >= minimumSamples else { return nil }

        let span = points[points.count - 1].at.timeIntervalSince(points[0].at)
        guard span >= minimumSpan else { return nil }

        let origin = points[0].at
        let xs = points.map { $0.at.timeIntervalSince(origin) / 3600 }
        let ys = points.map(\.fraction)
        let n = Double(points.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n

        var numerator = 0.0
        var denominator = 0.0
        for i in 0..<points.count {
            numerator += (xs[i] - meanX) * (ys[i] - meanY)
            denominator += (xs[i] - meanX) * (xs[i] - meanX)
        }
        guard denominator > 0 else { return nil }

        return BurnRate(perHour: numerator / denominator,
                        sampleCount: points.count,
                        spanHours: span / 3600)
    }
}

/// Which of the two independent limiters is actually about to bite.
///
/// The 5-hour window and the weekly cap constrain different things, and the right
/// response to each is opposite: capping the session window while the week sits
/// idle is a pacing-and-model-choice problem, not a reason to buy a bigger plan.
public enum BindingLimiter: String, Sendable, Equatable {
    case rateLimited    // session capping, week has room
    case planCeiling    // both stretched
    case underUsing     // neither stretched — capacity going to waste
    case frontLoaded    // session fine, week already heavily spent
    case unknown        // not enough data to say
}

public struct SessionAdvice: Sendable, Equatable {
    public let limiter: BindingLimiter
    public let headline: String
    public let detail: String
    /// When the 5-hour window reaches 100% at the current burn, if it will.
    public let projectedCapAt: Date?
    public let burnPerHour: Double?
    /// Model responsible for most output this window, if known.
    public let dominantModel: String?

    public init(limiter: BindingLimiter, headline: String, detail: String,
                projectedCapAt: Date?, burnPerHour: Double?, dominantModel: String?) {
        self.limiter = limiter
        self.headline = headline
        self.detail = detail
        self.projectedCapAt = projectedCapAt
        self.burnPerHour = burnPerHour
        self.dominantModel = dominantModel
    }
}

public enum SessionAdvisor {
    /// Session counts as at-risk above this even without a measurable burn.
    public static let sessionRiskFraction = 0.85
    public static let weeklyHighFraction = 0.70
    public static let weeklyLowFraction = 0.50

    /// Models worth suggesting a downshift to, cheapest first. Named rather than
    /// derived: the point is to recommend a lighter model, and there is no
    /// published ordering to compute one from.
    public static let lighterModels = ["Haiku", "Sonnet"]

    public static func advise(fiveHour: UsageSnapshot.Window?,
                              weekly: UsageSnapshot.Window?,
                              burn: BurnRate?,
                              now: Date,
                              dominantModel: String?) -> SessionAdvice {
        guard let fiveHour, let weekly else {
            return SessionAdvice(limiter: .unknown,
                                 headline: "Not enough data yet",
                                 detail: "Waiting for a usage reading.",
                                 projectedCapAt: nil, burnPerHour: nil,
                                 dominantModel: dominantModel)
        }

        // With no reset timestamp the window is not running: nothing to project.
        let hoursToSessionReset = fiveHour.resetsAt
            .map { max(0, $0.timeIntervalSince(now) / 3600) } ?? 0
        let remaining = max(0, 1 - fiveHour.fraction)

        var projectedCapAt: Date?
        var projectedAtReset = fiveHour.fraction
        if let burn, burn.perHour > 0 {
            projectedAtReset = fiveHour.fraction + burn.perHour * hoursToSessionReset
            let hoursToCap = remaining / burn.perHour
            if hoursToCap <= hoursToSessionReset {
                projectedCapAt = now.addingTimeInterval(hoursToCap * 3600)
            }
        }

        let sessionAtRisk = fiveHour.fraction >= sessionRiskFraction || projectedAtReset >= 1.0
        let weeklyHigh = weekly.fraction >= weeklyHighFraction
        let weeklyLow = weekly.fraction < weeklyLowFraction

        let weeklyPct = Int((weekly.fraction * 100).rounded())
        let sessionPct = Int((fiveHour.fraction * 100).rounded())

        let limiter: BindingLimiter
        let headline: String
        let detail: String

        switch (sessionAtRisk, weeklyHigh) {
        case (true, false):
            limiter = .rateLimited
            headline = "Rate-limited, not plan-limited"
            var d = "The 5-hour window is at \(sessionPct)% while your week is only at \(weeklyPct)%. "
                  + "This is the session limiter, not your plan."
            if let dominantModel {
                d += " Most of this window went to \(dominantModel) — moving routine work to "
                   + "\(lighterModels.joined(separator: " or ")) would stretch it. Keep the heavier "
                   + "model for work that needs it."
            }
            detail = d

        case (true, true):
            limiter = .planCeiling
            headline = "Near your plan's ceiling"
            detail = "Both limiters are stretched — session \(sessionPct)%, week \(weeklyPct)%. "
                   + "This is genuine demand for more capacity rather than a pacing problem."

        case (false, _) where weeklyLow:
            limiter = .underUsing
            headline = "You have room"
            detail = "Session \(sessionPct)%, week \(weeklyPct)%. Nothing is binding — "
                   + "no reason to hold back on the heavier models."

        default:
            limiter = .frontLoaded
            headline = "Week is running ahead"
            detail = "The session window is fine at \(sessionPct)%, but the week is already at "
                   + "\(weeklyPct)%. Worth pacing what is left."
        }

        return SessionAdvice(limiter: limiter,
                             headline: headline,
                             detail: detail,
                             projectedCapAt: projectedCapAt,
                             burnPerHour: burn?.perHour,
                             dominantModel: dominantModel)
    }
}
