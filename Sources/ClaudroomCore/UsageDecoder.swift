import Foundation

public enum UsageDecoderError: Error, Sendable {
    case notAnObject
}

/// Hand-rolled traversal of JSONSerialization output rather than Codable.
/// Codable throws on the first surprise; the requirement here is partial success —
/// one missing field must degrade a single metric, not the whole snapshot.
public enum UsageDecoder {
    /// Built per call rather than cached: ISO8601DateFormatter is not Sendable, and
    /// a shared static would be a data race under Swift 6 strict concurrency. We parse
    /// a handful of dates per poll, so the allocation cost is irrelevant.
    static func parseDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// Percent (0…100) -> fraction (0…1). The single conversion point in the codebase.
    static func parseFraction(_ any: Any?) -> Double? {
        // NSNumber bridges to both Double and Int, but a JSON string must not.
        guard !(any is String) else { return nil }
        guard let n = any as? Double ?? (any as? Int).map(Double.init) else { return nil }
        guard n.isFinite, n >= 0 else { return nil }
        return n / 100.0
    }

    /// Rounds a reset timestamp to the nearest minute.
    ///
    /// The server recomputes `resets_at` per request, so the same weekly cycle comes
    /// back as 11:59:59.316Z, 12:00:00.135Z, 12:00:00.147Z… Cycle identity is that
    /// timestamp, so without this every poll looks like a brand-new cycle: the prior
    /// one gets closed, and right-sizing ends up with a pile of fabricated cycles it
    /// will happily draw a verdict from. Real cycles are seven days apart, so a
    /// minute of tolerance cannot merge two distinct ones.
    static func normalizeReset(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    private static func window(_ any: Any?, schemaOK: inout Bool) -> UsageSnapshot.Window? {
        guard let obj = any as? [String: Any] else {
            schemaOK = false
            return nil
        }
        guard let frac = parseFraction(obj["utilization"]) else {
            schemaOK = false
            return nil
        }
        // A null resets_at alongside a real utilization means "no window running"
        // — normal at a reset boundary, not drift. Only a missing/!unparseable
        // utilization is a schema problem.
        let resets = parseDate(obj["resets_at"]).map(normalizeReset)
        if obj["resets_at"] != nil, !(obj["resets_at"] is NSNull), resets == nil {
            schemaOK = false
        }
        return .init(fraction: frac, resetsAt: resets)
    }

    public static func decode(data: Data, observedAt: Date) throws -> UsageSnapshot {
        let any = try JSONSerialization.jsonObject(with: data)
        guard let root = any as? [String: Any] else { throw UsageDecoderError.notAnObject }

        var schemaOK = true
        let fiveHour = window(root["five_hour"], schemaOK: &schemaOK)
        let weekly = window(root["seven_day"], schemaOK: &schemaOK)

        var scoped: [UsageSnapshot.ScopedLimit] = []
        if let limits = root["limits"] as? [[String: Any]] {
            for l in limits {
                guard let kind = l["kind"] as? String,
                      let frac = parseFraction(l["percent"]) else { continue }
                let model = (l["scope"] as? [String: Any])
                    .flatMap { $0["model"] as? [String: Any] }
                    .flatMap { $0["display_name"] as? String }
                scoped.append(.init(kind: kind,
                                    modelDisplayName: model,
                                    fraction: frac,
                                    resetsAt: parseDate(l["resets_at"]).map(normalizeReset)))
            }
        } else if root["limits"] != nil {
            schemaOK = false
        }

        let extraEnabled = (root["extra_usage"] as? [String: Any])
            .flatMap { $0["is_enabled"] as? Bool } ?? false

        return UsageSnapshot(
            observedAt: observedAt,
            fiveHour: fiveHour,
            weekly: weekly,
            scopedLimits: scoped,
            extraUsageEnabled: extraEnabled,
            schemaOK: schemaOK,
            rawJSON: String(decoding: data, as: UTF8.self)
        )
    }
}

public struct Profile: Sendable, Equatable {
    public let tier: PlanTier?
    public let rawTier: String
    public let subscriptionCreatedAt: Date?
    public let email: String?

    public init(tier: PlanTier?, rawTier: String, subscriptionCreatedAt: Date?, email: String?) {
        self.tier = tier
        self.rawTier = rawTier
        self.subscriptionCreatedAt = subscriptionCreatedAt
        self.email = email
    }
}

public enum ProfileDecoder {
    public static func decode(data: Data) throws -> Profile {
        let any = try JSONSerialization.jsonObject(with: data)
        guard let root = any as? [String: Any] else { throw UsageDecoderError.notAnObject }
        let org = root["organization"] as? [String: Any] ?? [:]
        let account = root["account"] as? [String: Any] ?? [:]
        let raw = org["rate_limit_tier"] as? String ?? ""
        return Profile(
            tier: PlanTier.from(rawTier: raw),
            rawTier: raw,
            subscriptionCreatedAt: UsageDecoder.parseDate(org["subscription_created_at"]),
            email: account["email"] as? String
        )
    }
}
