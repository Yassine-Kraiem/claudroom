import Foundation

/// Published pay-as-you-go list price for one model, in dollars per million tokens.
///
/// Cache tokens are not priced independently — both are multiples of the input
/// rate. Writes bill at 2x and reads at 0.1x.
///
/// The 2x multiplier is the one-hour cache TTL, which is what Claude Code uses;
/// the five-minute TTL bills at 1.25x and lands about 13% low. Verified against
/// Claude Code's own `/usage` readout: an Opus 5 session reporting 5.1k input,
/// 481.2k output, 142.7M cache read and 4.0M cache write was priced at $123.74,
/// which these rates reproduce to $123.41 — inside the rounding of the figures
/// `/usage` prints.
public struct ModelPrice: Sendable, Equatable {
    public let input: Double
    public let output: Double

    public var cacheWrite: Double { input * 2.0 }
    public var cacheRead: Double { input * 0.1 }

    public init(input: Double, output: Double) {
        self.input = input
        self.output = output
    }
}

public enum Pricing {
    /// Matched by prefix so dated snapshots (`claude-haiku-4-5-20251001`) resolve
    /// to the same price as the alias. No entry is a prefix of another, which
    /// `PricingTests` asserts, so the first match is unambiguous.
    ///
    /// Deliberately not exhaustive. A model absent here is reported as unpriced
    /// rather than guessed at, and the dashboard says how much went unpriced.
    static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5",    ModelPrice(input: 10, output: 50)),
        ("claude-mythos-5",   ModelPrice(input: 10, output: 50)),
        ("claude-opus-5",     ModelPrice(input: 5,  output: 25)),
        ("claude-opus-4-8",   ModelPrice(input: 5,  output: 25)),
        ("claude-opus-4-7",   ModelPrice(input: 5,  output: 25)),
        ("claude-opus-4-6",   ModelPrice(input: 5,  output: 25)),
        ("claude-opus-4-5",   ModelPrice(input: 5,  output: 25)),
        ("claude-sonnet-5",   ModelPrice(input: 3,  output: 15)),
        ("claude-sonnet-4-6", ModelPrice(input: 3,  output: 15)),
        ("claude-sonnet-4-5", ModelPrice(input: 3,  output: 15)),
        ("claude-haiku-4-5",  ModelPrice(input: 1,  output: 5)),
    ]

    public static func price(for model: String) -> ModelPrice? {
        table.first { model.hasPrefix($0.prefix) }?.price
    }

    /// What these tokens would have cost on the metered API. Returns nil for a
    /// model with no published price on file — the caller reports that as
    /// unpriced rather than as zero.
    public static func cost(model: String,
                            input: Int,
                            output: Int,
                            cacheRead: Int,
                            cacheWrite: Int) -> Double? {
        guard let p = price(for: model) else { return nil }
        return (Double(input) * p.input
                + Double(output) * p.output
                + Double(cacheRead) * p.cacheRead
                + Double(cacheWrite) * p.cacheWrite) / 1_000_000
    }

    /// One priced line of a breakdown — a token class, or a model.
    public struct Line: Sendable, Equatable, Identifiable {
        public let label: String
        public let tokens: Int
        public let cost: Double
        public var id: String { label }

        public init(label: String, tokens: Int, cost: Double) {
            self.label = label
            self.tokens = tokens
            self.cost = cost
        }
    }

    /// `$4.20`, `$1.2k`. Costs here span five orders of magnitude — a single
    /// session is cents, a quarter's history is thousands — so the scale has to
    /// adapt or the column is unreadable at one end.
    public static func money(_ dollars: Double) -> String {
        switch abs(dollars) {
        case 0:            return "$0"
        case ..<0.01:      return "<$0.01"
        case ..<10:        return String(format: "$%.2f", dollars)
        case ..<1_000:     return String(format: "$%.0f", dollars)
        case ..<1_000_000: return String(format: "$%.1fk", dollars / 1_000)
        default:           return String(format: "$%.1fM", dollars / 1_000_000)
        }
    }
}
