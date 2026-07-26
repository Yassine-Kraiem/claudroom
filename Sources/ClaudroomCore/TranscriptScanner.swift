import Foundation

/// Turns a Claude model id into something readable, with a defensive fallback.
/// New model ids appear without warning, so this must never fail — an unrecognised
/// shape falls back to the raw id rather than guessing.
public enum ModelName {
    public static func display(for id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        var parts = id.dropFirst("claude-".count).split(separator: "-").map(String.init)
        guard let family = parts.first else { return id }
        parts.removeFirst()

        // Drop a trailing release date such as 20251001.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }

        let version = parts.joined(separator: ".")
        let familyName = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? familyName : "\(familyName) \(version)"
    }

    /// Only first-party Claude models count toward Claude usage. Local transcripts
    /// also contain third-party models routed through Claude Code and a `<synthetic>`
    /// pseudo-model for locally generated messages; both must be excluded.
    public static func isClaudeModel(_ id: String) -> Bool {
        id.hasPrefix("claude-")
    }
}

/// Turns a working directory into a short, unambiguous project label.
///
/// Derived from each record's `cwd`, never from the transcript folder name — that
/// name encodes the path with separators replaced by hyphens, so a directory
/// genuinely containing a hyphen or underscore cannot be recovered from it.
public enum ProjectName {
    /// Directories that hold projects rather than being one. A path under these
    /// needs a second component before it names anything meaningful.
    static let containers: Set<String> = [
        "Documents", "Downloads", "Desktop", "Developer", "Projects",
        "Code", "code", "src", "repos", "work", "dev",
    ]

    /// Rolls a working directory up to the project it belongs to.
    ///
    /// Records carry the exact `cwd`, which changes as you move around inside a
    /// session — so raw paths fragment one project across many rows
    /// (`research`, `research/code`, `research/latex/…`). The root is
    /// what answers "which project consumed my capacity", so that is what is kept.
    public static func display(for cwd: String, home: String = NSHomeDirectory()) -> String {
        guard cwd != home else { return "~" }
        guard cwd.hasPrefix(home + "/") else { return cwd }

        let parts = cwd.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard let first = parts.first else { return "~" }

        // "Documents/DCPS" rather than a bucket called "Documents".
        if containers.contains(first), parts.count > 1 {
            return "\(first)/\(parts[1])"
        }
        return first
    }
}

public struct TranscriptEvent: Sendable, Equatable {
    /// ISO8601 hour, e.g. "2026-07-25T07". Weekly resets land on exact hours, so
    /// hour buckets can be summed into a cycle without misattribution.
    public let hourBucket: String
    public let model: String
    public let project: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int

    public init(hourBucket: String, model: String, project: String,
                inputTokens: Int, outputTokens: Int,
                cacheReadTokens: Int, cacheCreationTokens: Int) {
        self.hourBucket = hourBucket
        self.model = model
        self.project = project
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }
}

public enum TranscriptParser {
    /// Cheap reject before the expensive parse. Most lines in a transcript are user
    /// turns, tool results and hook output; over a gigabyte of backfill, skipping
    /// their JSON parse is the difference between seconds and minutes.
    static func couldBeAssistantMessage(_ line: String) -> Bool {
        line.contains("\"type\":\"assistant\"") && line.contains("\"usage\"")
    }

    /// Returns nil for any line that is not a usable assistant message: user turns,
    /// hook output, non-Claude models, malformed JSON, missing usage.
    public static func parse(line: String) -> TranscriptEvent? {
        guard couldBeAssistantMessage(line) else { return nil }
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "assistant",
              let timestamp = root["timestamp"] as? String,
              let message = root["message"] as? [String: Any],
              let model = message["model"] as? String,
              ModelName.isClaudeModel(model),
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        // "2026-07-25T07:41:10.705Z" -> "2026-07-25T07"
        guard timestamp.count >= 13 else { return nil }
        let hourBucket = String(timestamp.prefix(13))

        func int(_ key: String) -> Int { usage[key] as? Int ?? 0 }

        let project = (root["cwd"] as? String).map { ProjectName.display(for: $0) } ?? "unknown"

        return TranscriptEvent(
            hourBucket: hourBucket,
            model: model,
            project: project,
            inputTokens: int("input_tokens"),
            outputTokens: int("output_tokens"),
            cacheReadTokens: int("cache_read_input_tokens"),
            cacheCreationTokens: int("cache_creation_input_tokens")
        )
    }
}

public struct ScanResult: Sendable {
    public let events: [TranscriptEvent]
    /// Byte offset reached per file, to be persisted and passed back next scan.
    public let offsets: [String: Int64]
}

/// Incremental append-only scanner. Transcripts grow to tens of megabytes, so each
/// scan reads only the bytes added since last time.
public enum TranscriptScanner {
    public static func defaultRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public static func transcriptFiles(root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    static let chunkSize = 4 * 1024 * 1024
    static let probeWindow = 512 * 1024
    /// Once the binary search narrows to this, just read it — further probing costs
    /// more than the bytes saved.
    static let searchFloor: UInt64 = 8 * 1024 * 1024
    /// A single line larger than this is pathological; drop the carry rather than
    /// grow memory without bound.
    static let maxCarry = 32 * 1024 * 1024

    /// Extracts the ISO timestamp of the first complete line at or after `offset`,
    /// by direct key search rather than full JSON parsing — probe lines can be
    /// hundreds of kilobytes and only the direction of the search depends on this.
    static func probeTimestamp(_ handle: FileHandle, at offset: UInt64, size: UInt64) -> Date? {
        guard offset < size else { return nil }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: probeWindow), !data.isEmpty
        else { return nil }

        // Skip the partial line we probably landed in the middle of.
        let searchable: Data
        if offset == 0 {
            searchable = data
        } else if let nl = data.firstIndex(of: UInt8(ascii: "\n")), nl + 1 < data.endIndex {
            searchable = data[(nl + 1)...]
        } else {
            return nil
        }

        guard let text = String(data: searchable, encoding: .utf8),
              let range = text.range(of: #""timestamp":""#)
        else { return nil }

        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return ISO.date(String(rest[rest.startIndex..<end]))
    }

    /// Byte offset to start reading from so that no event at or after `cutoff` is
    /// missed. Transcripts are append-ordered by time, so this is a binary search.
    /// Reading somewhat too early is harmless — events carry their own timestamps
    /// and land in the correct bucket — so the search is biased low.
    static func startOffset(_ handle: FileHandle, size: UInt64, cutoff: Date) -> UInt64 {
        var lo: UInt64 = 0
        var hi = size
        while hi - lo > searchFloor {
            let mid = lo + (hi - lo) / 2
            guard let ts = probeTimestamp(handle, at: mid, size: size) else {
                hi = mid
                continue
            }
            if ts < cutoff { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// `since` bounds the work: files untouched since then are skipped outright, and
    /// large files are entered at the right place instead of from byte zero. Pass nil
    /// to scan everything from the beginning.
    public static func scan(root: URL,
                            priorOffsets: [String: Int64],
                            since: Date? = nil,
                            progress: (@Sendable (Int, Int) -> Void)? = nil) -> ScanResult {
        var events: [TranscriptEvent] = []
        var offsets = priorOffsets

        let files = transcriptFiles(root: root)
        for (index, url) in files.enumerated() {
            progress?(index, files.count)
            // Canonical path, so an offset stays valid whether the file was reached
            // via /var/... or /private/var/...
            let path = url.resolvingSymlinksInPath().path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = UInt64((attrs?[.size] as? NSNumber)?.uint64Value ?? 0)

            // Steady state: nothing appended since last scan. Decided from metadata
            // alone, so a rescan across ~1000 files costs no file opens.
            if let prior = priorOffsets[path], UInt64(prior) == size {
                offsets[path] = prior
                continue
            }

            if priorOffsets[path] == nil, let since,
               let mtime = attrs?[.modificationDate] as? Date, mtime < since {
                // Nothing in here can belong to the window; never open it at all.
                offsets[path] = Int64(size)
                continue
            }

            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }

            let start: UInt64
            if let prior = priorOffsets[path] {
                // A file that shrank was rotated or replaced: re-read from the start.
                start = size < UInt64(prior) ? 0 : UInt64(prior)
            } else if let since, size > searchFloor {
                start = startOffset(handle, size: size, cutoff: since)
            } else {
                start = 0
            }

            guard size > start else {
                offsets[path] = Int64(size)
                continue
            }

            offsets[path] = readLines(handle, from: start, size: size) { line in
                if let event = TranscriptParser.parse(line: line) { events.append(event) }
            }
        }

        progress?(files.count, files.count)
        return ScanResult(events: events, offsets: offsets)
    }

    /// Streams the file in bounded chunks, carrying partial lines across chunk
    /// boundaries. Returns the offset of the last complete line consumed — a
    /// trailing partial line is left for a later scan, once the writer finishes it.
    private static func readLines(_ handle: FileHandle,
                                  from start: UInt64,
                                  size: UInt64,
                                  _ body: (String) -> Void) -> Int64 {
        var offset = start
        var carry = Data()
        var consumed = start

        while offset < size {
            try? handle.seek(toOffset: offset)
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)

            var buffer = carry
            buffer.append(chunk)

            guard let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) else {
                // No line boundary in this window yet.
                carry = buffer.count > maxCarry ? Data() : buffer
                continue
            }

            let usable = buffer[buffer.startIndex...lastNewline]
            for lineData in usable.split(separator: UInt8(ascii: "\n")) {
                guard let line = String(data: Data(lineData), encoding: .utf8) else { continue }
                body(line)
            }

            consumed += UInt64(usable.count)
            let remainder = buffer[(lastNewline + 1)...]
            carry = remainder.count > maxCarry ? Data() : Data(remainder)
        }

        return Int64(consumed)
    }
}

public struct ModelUsageRow: Sendable, Equatable {
    public let model: String
    public let messages: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int

    public var displayName: String { ModelName.display(for: model) }

    /// Tokens the model actually generated. Used for share-of-work because it is
    /// the least distorted by cache behaviour, which varies wildly by session shape.
    public var billableWork: Int { outputTokens }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// What this would have cost on the metered API. Nil for a model with no
    /// published price on file.
    public var apiCost: Double? {
        Pricing.cost(model: model,
                     input: inputTokens,
                     output: outputTokens,
                     cacheRead: cacheReadTokens,
                     cacheWrite: cacheCreationTokens)
    }

    public init(model: String, messages: Int, inputTokens: Int, outputTokens: Int,
                cacheReadTokens: Int, cacheCreationTokens: Int) {
        self.model = model
        self.messages = messages
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }
}

public enum ModelShare {
    /// Share of output tokens per model, newest-heaviest first.
    ///
    /// Deliberately *not* presented as share of your rate limit: models consume the
    /// cap at different rates and Anthropic does not publish the weighting, so any
    /// such conversion would be invented.
    public static func shares(_ rows: [ModelUsageRow]) -> [(row: ModelUsageRow, share: Double)] {
        let total = rows.reduce(0) { $0 + $1.billableWork }
        guard total > 0 else { return rows.map { ($0, 0) } }
        return rows
            .map { ($0, Double($0.billableWork) / Double(total)) }
            .sorted { $0.1 > $1.1 }
    }
}
