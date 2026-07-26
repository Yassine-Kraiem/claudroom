import Foundation

public struct StoredSample: Sendable, Equatable {
    public let observedAt: Date
    public let fiveHourFrac: Double?
    public let fiveHourResetsAt: Date?
    public let weeklyFrac: Double?
    public let weeklyResetsAt: Date?

    public init(observedAt: Date, fiveHourFrac: Double?, fiveHourResetsAt: Date?,
                weeklyFrac: Double?, weeklyResetsAt: Date?) {
        self.observedAt = observedAt
        self.fiveHourFrac = fiveHourFrac
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weeklyFrac = weeklyFrac
        self.weeklyResetsAt = weeklyResetsAt
    }
}

public struct Cycle: Sendable, Equatable {
    /// A cycle's identity is its reset timestamp. Keying on this rather than
    /// wall-clock makes gaps, sleep and clock changes non-events.
    public let resetsAt: Date
    public let planTier: String
    public var finalUtilizationFrac: Double?
    public var closed: Bool
    /// True when the closing value came from a stale last-known sample rather
    /// than one taken near the reset. Surfaced in the UI, never presented as measured.
    public var inferred: Bool
    public var lastObservedAt: Date?

    public var startedAt: Date { resetsAt.addingTimeInterval(-7 * 24 * 3600) }

    public init(resetsAt: Date, planTier: String, finalUtilizationFrac: Double?,
                closed: Bool, inferred: Bool, lastObservedAt: Date?) {
        self.resetsAt = resetsAt
        self.planTier = planTier
        self.finalUtilizationFrac = finalUtilizationFrac
        self.closed = closed
        self.inferred = inferred
        self.lastObservedAt = lastObservedAt
    }
}

enum ISO {
    /// Built per call — ISO8601DateFormatter is not Sendable.
    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    static func string(_ d: Date) -> String { formatter().string(from: d) }

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return formatter().date(from: s)
    }

    /// "2026-07-25T07" — matches the prefix taken from transcript timestamps, and
    /// sorts lexicographically so range queries work as plain string comparisons.
    static func hourBucket(_ d: Date) -> String {
        String(string(d).prefix(13))
    }
}

public final class Store {
    private let db: Database

    public init(database: Database) throws {
        self.db = database
        try migrate()
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS samples (
          id                  INTEGER PRIMARY KEY,
          observed_at         TEXT NOT NULL,
          five_hour_frac      REAL,
          five_hour_resets_at TEXT,
          weekly_frac         REAL,
          weekly_resets_at    TEXT,
          plan_tier           TEXT,
          raw_json            TEXT NOT NULL,
          schema_ok           INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_samples_observed_at ON samples(observed_at);

        CREATE TABLE IF NOT EXISTS cycles (
          id                     INTEGER PRIMARY KEY,
          resets_at              TEXT NOT NULL UNIQUE,
          started_at             TEXT,
          plan_tier              TEXT NOT NULL,
          final_utilization_frac REAL,
          closed                 INTEGER NOT NULL DEFAULT 0,
          inferred               INTEGER NOT NULL DEFAULT 0,
          last_observed_at       TEXT
        );

        CREATE TABLE IF NOT EXISTS settings (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS alerts_fired (
          cycle_resets_at TEXT NOT NULL,
          rule            TEXT NOT NULL,
          fired_at        TEXT NOT NULL,
          PRIMARY KEY (cycle_resets_at, rule)
        );

        CREATE TABLE IF NOT EXISTS model_usage (
          hour_bucket           TEXT NOT NULL,
          model                 TEXT NOT NULL,
          project               TEXT NOT NULL DEFAULT 'unknown',
          messages              INTEGER NOT NULL DEFAULT 0,
          input_tokens          INTEGER NOT NULL DEFAULT 0,
          output_tokens         INTEGER NOT NULL DEFAULT 0,
          cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
          cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (hour_bucket, model, project)
        );

        CREATE TABLE IF NOT EXISTS scan_offsets (
          path   TEXT PRIMARY KEY,
          offset INTEGER NOT NULL
        );
        """)

        try migrateProjectColumn()
    }

    /// Adds the project dimension to an older database.
    ///
    /// Every row in `model_usage` is derived from transcripts on disk, so the safe
    /// migration is to drop the table and clear the scan bookmarks: the next
    /// backfill rebuilds it with attribution. Preserving unattributed rows would
    /// leave a permanent "unknown" bucket that never resolves.
    private func migrateProjectColumn() throws {
        let columns = try db.query("PRAGMA table_info(model_usage)")
            .compactMap { $0["name"]?.stringValue }
        guard !columns.isEmpty, !columns.contains("project") else { return }

        try db.exec("""
        DROP TABLE model_usage;
        DELETE FROM scan_offsets;
        CREATE TABLE model_usage (
          hour_bucket           TEXT NOT NULL,
          model                 TEXT NOT NULL,
          project               TEXT NOT NULL DEFAULT 'unknown',
          messages              INTEGER NOT NULL DEFAULT 0,
          input_tokens          INTEGER NOT NULL DEFAULT 0,
          output_tokens         INTEGER NOT NULL DEFAULT 0,
          cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
          cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (hour_bucket, model, project)
        );
        """)
        try db.run("DELETE FROM settings WHERE key = 'backfill_done'")
    }

    // MARK: - Per-model usage

    /// Aggregates in memory first, then writes one row per (hour, model) inside a
    /// single transaction. The initial scan produces tens of thousands of events;
    /// one statement each would take minutes.
    public func record(events: [TranscriptEvent]) throws {
        guard !events.isEmpty else { return }

        struct Key: Hashable { let hour: String; let model: String; let project: String }
        var totals: [Key: (msgs: Int, input: Int, output: Int, cacheR: Int, cacheW: Int)] = [:]
        for e in events {
            let key = Key(hour: e.hourBucket, model: e.model, project: e.project)
            var t = totals[key] ?? (0, 0, 0, 0, 0)
            t.msgs += 1
            t.input += e.inputTokens
            t.output += e.outputTokens
            t.cacheR += e.cacheReadTokens
            t.cacheW += e.cacheCreationTokens
            totals[key] = t
        }

        try db.exec("BEGIN TRANSACTION;")
        do {
            for (key, t) in totals {
                try db.run("""
                INSERT INTO model_usage
                  (hour_bucket, model, project, messages, input_tokens, output_tokens,
                   cache_read_tokens, cache_creation_tokens)
                VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(hour_bucket, model, project) DO UPDATE SET
                  messages = messages + excluded.messages,
                  input_tokens = input_tokens + excluded.input_tokens,
                  output_tokens = output_tokens + excluded.output_tokens,
                  cache_read_tokens = cache_read_tokens + excluded.cache_read_tokens,
                  cache_creation_tokens = cache_creation_tokens + excluded.cache_creation_tokens
                """, [
                    .text(key.hour), .text(key.model), .text(key.project),
                    .int(Int64(t.msgs)), .int(Int64(t.input)), .int(Int64(t.output)),
                    .int(Int64(t.cacheR)), .int(Int64(t.cacheW)),
                ])
            }
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    public func modelUsage(since: Date, until: Date = .distantFuture) throws -> [ModelUsageRow] {
        try db.query("""
        SELECT model,
               SUM(messages) AS messages,
               SUM(input_tokens) AS input_tokens,
               SUM(output_tokens) AS output_tokens,
               SUM(cache_read_tokens) AS cache_read_tokens,
               SUM(cache_creation_tokens) AS cache_creation_tokens
        FROM model_usage
        WHERE hour_bucket >= ? AND hour_bucket <= ?
        GROUP BY model
        ORDER BY output_tokens DESC
        """, [.text(ISO.hourBucket(since)), .text(ISO.hourBucket(until))]).compactMap { row in
            guard let model = row["model"]?.stringValue else { return nil }
            func n(_ k: String) -> Int { Int(row[k]?.intValue ?? 0) }
            return ModelUsageRow(
                model: model,
                messages: n("messages"),
                inputTokens: n("input_tokens"),
                outputTokens: n("output_tokens"),
                cacheReadTokens: n("cache_read_tokens"),
                cacheCreationTokens: n("cache_creation_tokens")
            )
        }
    }

    /// Per-day totals per model across a range, for the dashboard charts.
    public func dailyActivity(from: Date, to: Date) throws -> [DailyActivity] {
        try db.query("""
        SELECT substr(hour_bucket, 1, 10) AS day,
               model,
               SUM(output_tokens) AS output_tokens,
               SUM(messages) AS messages
        FROM model_usage
        WHERE hour_bucket >= ? AND hour_bucket <= ?
        GROUP BY day, model
        ORDER BY day
        """, [.text(ISO.hourBucket(from)), .text(ISO.hourBucket(to))]).compactMap { row in
            guard let dayString = row["day"]?.stringValue,
                  let day = ISO.date(dayString + "T00:00:00.000Z"),
                  let model = row["model"]?.stringValue else { return nil }
            return DailyActivity(day: day, model: model,
                                 outputTokens: Int(row["output_tokens"]?.intValue ?? 0),
                                 messages: Int(row["messages"]?.intValue ?? 0))
        }
    }

    /// Total output tokens per hour bucket across a range.
    public func hourlyOutput(from: Date, to: Date) throws -> [Date: Int] {
        var out: [Date: Int] = [:]
        for row in try db.query("""
        SELECT hour_bucket, SUM(output_tokens) AS output_tokens
        FROM model_usage
        WHERE hour_bucket >= ? AND hour_bucket <= ?
        GROUP BY hour_bucket
        """, [.text(ISO.hourBucket(from)), .text(ISO.hourBucket(to))]) {
            guard let bucket = row["hour_bucket"]?.stringValue,
                  let hour = ISO.date(bucket + ":00:00.000Z") else { continue }
            out[hour] = Int(row["output_tokens"]?.intValue ?? 0)
        }
        return out
    }

    public func activityRange() throws -> (first: Date, last: Date)? {
        let rows = try db.query("SELECT min(hour_bucket) AS lo, max(hour_bucket) AS hi FROM model_usage")
        guard let lo = rows.first?["lo"]?.stringValue,
              let hi = rows.first?["hi"]?.stringValue,
              let first = ISO.date(lo + ":00:00.000Z"),
              let last = ISO.date(hi + ":00:00.000Z") else { return nil }
        return (first, last)
    }

    /// Wipes scan bookmarks so the next scan re-reads every transcript from the
    /// start. Used only by the explicit historical backfill.
    public func clearScanOffsets() throws {
        try db.run("DELETE FROM scan_offsets")
    }

    /// Clears derived per-model rows before a backfill, so re-reading files cannot
    /// double-count what a previous incremental scan already recorded.
    public func clearModelUsage() throws {
        try db.run("DELETE FROM model_usage")
    }

    /// Grouped by project *and* model, then folded per project in Swift. Grouping
    /// by project alone would lose the model, and cost cannot be recovered from a
    /// blended total — Opus output bills at 25x Haiku input.
    public func projectUsage(since: Date, until: Date = .distantFuture) throws -> [ProjectUsageRow] {
        struct Totals {
            var messages = 0, output = 0, total = 0, unpriced = 0
            var cost: Double = 0
        }
        var byProject: [String: Totals] = [:]

        for row in try db.query("""
        SELECT project, model,
               SUM(messages) AS messages,
               SUM(input_tokens) AS input_tokens,
               SUM(output_tokens) AS output_tokens,
               SUM(cache_read_tokens) AS cache_read_tokens,
               SUM(cache_creation_tokens) AS cache_creation_tokens
        FROM model_usage
        WHERE hour_bucket >= ? AND hour_bucket <= ?
        GROUP BY project, model
        """, [.text(ISO.hourBucket(since)), .text(ISO.hourBucket(until))]) {
            guard let project = row["project"]?.stringValue,
                  let model = row["model"]?.stringValue else { continue }
            func n(_ k: String) -> Int { Int(row[k]?.intValue ?? 0) }
            let input = n("input_tokens"), output = n("output_tokens")
            let cacheRead = n("cache_read_tokens"), cacheWrite = n("cache_creation_tokens")
            let tokens = input + output + cacheRead + cacheWrite

            var t = byProject[project] ?? Totals()
            t.messages += n("messages")
            t.output += output
            t.total += tokens
            if let cost = Pricing.cost(model: model, input: input, output: output,
                                       cacheRead: cacheRead, cacheWrite: cacheWrite) {
                t.cost += cost
            } else {
                t.unpriced += tokens
            }
            byProject[project] = t
        }

        return byProject
            .map { ProjectUsageRow(project: $0.key,
                                   messages: $0.value.messages,
                                   outputTokens: $0.value.output,
                                   totalTokens: $0.value.total,
                                   apiCost: $0.value.cost,
                                   unpricedTokens: $0.value.unpriced) }
            .sorted { $0.apiCost != $1.apiCost ? $0.apiCost > $1.apiCost
                                               : $0.outputTokens > $1.outputTokens }
    }

    /// One project's cost opened up by token class and by model.
    ///
    /// Models are merged on display name: a dated snapshot and its alias
    /// (`claude-haiku-4-5-20251001`, `claude-haiku-4-5`) are separate rows here but
    /// one model on screen, and leaving them apart shows the same name twice.
    public func projectDetail(project: String, since: Date,
                              until: Date = .distantFuture) throws -> ProjectDetail? {
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, messages = 0
        var inputCost = 0.0, outputCost = 0.0, cacheReadCost = 0.0, cacheWriteCost = 0.0
        var unpriced = 0
        var byModel: [String: (tokens: Int, cost: Double)] = [:]

        let rows = try db.query("""
        SELECT model,
               SUM(messages) AS messages,
               SUM(input_tokens) AS input_tokens,
               SUM(output_tokens) AS output_tokens,
               SUM(cache_read_tokens) AS cache_read_tokens,
               SUM(cache_creation_tokens) AS cache_creation_tokens
        FROM model_usage
        WHERE project = ? AND hour_bucket >= ? AND hour_bucket <= ?
        GROUP BY model
        """, [.text(project), .text(ISO.hourBucket(since)), .text(ISO.hourBucket(until))])
        guard !rows.isEmpty else { return nil }

        for row in rows {
            guard let model = row["model"]?.stringValue else { continue }
            func n(_ k: String) -> Int { Int(row[k]?.intValue ?? 0) }
            let i = n("input_tokens"), o = n("output_tokens")
            let cr = n("cache_read_tokens"), cw = n("cache_creation_tokens")

            input += i; output += o; cacheRead += cr; cacheWrite += cw
            messages += n("messages")

            let name = ModelName.display(for: model)
            var entry = byModel[name] ?? (0, 0)
            entry.tokens += o

            if let p = Pricing.price(for: model) {
                inputCost += Double(i) * p.input / 1_000_000
                outputCost += Double(o) * p.output / 1_000_000
                cacheReadCost += Double(cr) * p.cacheRead / 1_000_000
                cacheWriteCost += Double(cw) * p.cacheWrite / 1_000_000
                entry.cost += (Double(i) * p.input + Double(o) * p.output
                               + Double(cr) * p.cacheRead
                               + Double(cw) * p.cacheWrite) / 1_000_000
            } else {
                unpriced += i + o + cr + cw
            }
            byModel[name] = entry
        }

        let classes = [
            Pricing.Line(label: "cache read", tokens: cacheRead, cost: cacheReadCost),
            Pricing.Line(label: "cache write", tokens: cacheWrite, cost: cacheWriteCost),
            Pricing.Line(label: "output", tokens: output, cost: outputCost),
            Pricing.Line(label: "input", tokens: input, cost: inputCost),
        ].filter { $0.tokens > 0 }.sorted { $0.cost > $1.cost }

        return ProjectDetail(
            project: project,
            totalCost: inputCost + outputCost + cacheReadCost + cacheWriteCost,
            totalTokens: input + output + cacheRead + cacheWrite,
            messages: messages,
            byTokenClass: classes,
            byModel: byModel
                .map { Pricing.Line(label: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
                .sorted { $0.cost > $1.cost },
            unpricedTokens: unpriced)
    }

    public func scanOffsets() throws -> [String: Int64] {
        var out: [String: Int64] = [:]
        for row in try db.query("SELECT path, offset FROM scan_offsets") {
            if let p = row["path"]?.stringValue, let o = row["offset"]?.intValue {
                out[p] = o
            }
        }
        return out
    }

    public func setScanOffsets(_ offsets: [String: Int64]) throws {
        guard !offsets.isEmpty else { return }
        try db.exec("BEGIN TRANSACTION;")
        do {
            for (path, offset) in offsets {
                try db.run("""
                INSERT INTO scan_offsets (path, offset) VALUES (?,?)
                ON CONFLICT(path) DO UPDATE SET offset = excluded.offset
                """, [.text(path), .int(offset)])
            }
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    /// Split out rather than inlined: with both the window and its reset optional,
    /// the nested `map`/`??` chains defeated the type-checker.
    private static func fractionValue(_ window: UsageSnapshot.Window?) -> SQLValue {
        guard let window else { return .null }
        return .double(window.fraction)
    }

    private static func resetValue(_ window: UsageSnapshot.Window?) -> SQLValue {
        guard let resetsAt = window?.resetsAt else { return .null }
        return .text(ISO.string(resetsAt))
    }

    public func insert(sample: UsageSnapshot, planTier: String) throws {
        try db.run("""
        INSERT INTO samples
          (observed_at, five_hour_frac, five_hour_resets_at,
           weekly_frac, weekly_resets_at, plan_tier, raw_json, schema_ok)
        VALUES (?,?,?,?,?,?,?,?)
        """, [
            .text(ISO.string(sample.observedAt)),
            Self.fractionValue(sample.fiveHour),
            Self.resetValue(sample.fiveHour),
            Self.fractionValue(sample.weekly),
            Self.resetValue(sample.weekly),
            .text(planTier),
            .text(sample.rawJSON),
            .int(sample.schemaOK ? 1 : 0),
        ])
    }

    public func recentSamples(limit: Int) throws -> [StoredSample] {
        try db.query("""
        SELECT observed_at, five_hour_frac, five_hour_resets_at, weekly_frac, weekly_resets_at
        FROM samples ORDER BY observed_at DESC LIMIT ?
        """, [.int(Int64(limit))]).compactMap { row in
            guard let at = ISO.date(row["observed_at"]?.stringValue) else { return nil }
            return StoredSample(
                observedAt: at,
                fiveHourFrac: row["five_hour_frac"]?.doubleValue,
                fiveHourResetsAt: ISO.date(row["five_hour_resets_at"]?.stringValue),
                weeklyFrac: row["weekly_frac"]?.doubleValue,
                weeklyResetsAt: ISO.date(row["weekly_resets_at"]?.stringValue)
            )
        }
    }

    public func rawJSON(at observedAt: Date) throws -> String? {
        try db.query("SELECT raw_json FROM samples WHERE observed_at = ? LIMIT 1",
                     [.text(ISO.string(observedAt))]).first?["raw_json"]?.stringValue
    }

    public func planTier(at observedAt: Date) throws -> String? {
        try db.query("SELECT plan_tier FROM samples WHERE observed_at = ? LIMIT 1",
                     [.text(ISO.string(observedAt))]).first?["plan_tier"]?.stringValue
    }

    public func upsert(cycle: Cycle) throws {
        try db.run("""
        INSERT INTO cycles
          (resets_at, started_at, plan_tier, final_utilization_frac,
           closed, inferred, last_observed_at)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(resets_at) DO UPDATE SET
          plan_tier = excluded.plan_tier,
          final_utilization_frac = excluded.final_utilization_frac,
          closed = excluded.closed,
          inferred = excluded.inferred,
          last_observed_at = excluded.last_observed_at
        """, [
            .text(ISO.string(cycle.resetsAt)),
            .text(ISO.string(cycle.startedAt)),
            .text(cycle.planTier),
            cycle.finalUtilizationFrac.map { SQLValue.double($0) } ?? .null,
            .int(cycle.closed ? 1 : 0),
            .int(cycle.inferred ? 1 : 0),
            cycle.lastObservedAt.map { SQLValue.text(ISO.string($0)) } ?? .null,
        ])
    }

    private func cycles(where clause: String, _ binds: [SQLValue]) throws -> [Cycle] {
        try db.query("""
        SELECT resets_at, plan_tier, final_utilization_frac, closed, inferred, last_observed_at
        FROM cycles WHERE \(clause)
        """, binds).compactMap { row in
            guard let resets = ISO.date(row["resets_at"]?.stringValue) else { return nil }
            return Cycle(
                resetsAt: resets,
                planTier: row["plan_tier"]?.stringValue ?? "",
                finalUtilizationFrac: row["final_utilization_frac"]?.doubleValue,
                closed: (row["closed"]?.intValue ?? 0) == 1,
                inferred: (row["inferred"]?.intValue ?? 0) == 1,
                lastObservedAt: ISO.date(row["last_observed_at"]?.stringValue)
            )
        }
    }

    /// Newest-first.
    public func closedCycles(limit: Int) throws -> [Cycle] {
        try cycles(where: "closed = 1 ORDER BY resets_at DESC LIMIT ?", [.int(Int64(limit))])
    }

    public func openCycle() throws -> Cycle? {
        try cycles(where: "closed = 0 ORDER BY resets_at DESC LIMIT 1", []).first
    }

    public func setting(_ key: String) throws -> String? {
        try db.query("SELECT value FROM settings WHERE key = ?", [.text(key)])
            .first?["value"]?.stringValue
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try db.run("""
        INSERT INTO settings (key, value) VALUES (?,?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, [.text(key), .text(value)])
    }

    public func hasFired(rule: String, cycleResetsAt: Date) throws -> Bool {
        try !db.query(
            "SELECT 1 FROM alerts_fired WHERE cycle_resets_at = ? AND rule = ?",
            [.text(ISO.string(cycleResetsAt)), .text(rule)]
        ).isEmpty
    }

    public func markFired(rule: String, cycleResetsAt: Date, at: Date) throws {
        try db.run("""
        INSERT INTO alerts_fired (cycle_resets_at, rule, fired_at) VALUES (?,?,?)
        ON CONFLICT(cycle_resets_at, rule) DO NOTHING
        """, [.text(ISO.string(cycleResetsAt)), .text(rule), .text(ISO.string(at))])
    }

    public func pruneSamples(olderThan cutoff: Date) throws {
        try db.run("DELETE FROM samples WHERE observed_at < ?", [.text(ISO.string(cutoff))])
    }
}
