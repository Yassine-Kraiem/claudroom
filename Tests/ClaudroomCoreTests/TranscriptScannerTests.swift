import Testing
import Foundation
@testable import ClaudroomCore

// MARK: - Model names

@Test func displayNameFormatsKnownModels() {
    #expect(ModelName.display(for: "claude-opus-4-8") == "Opus 4.8")
    #expect(ModelName.display(for: "claude-sonnet-5") == "Sonnet 5")
    #expect(ModelName.display(for: "claude-fable-5") == "Fable 5")
    #expect(ModelName.display(for: "claude-opus-5") == "Opus 5")
}

@Test func displayNameStripsReleaseDate() {
    #expect(ModelName.display(for: "claude-haiku-4-5-20251001") == "Haiku 4.5")
}

@Test func displayNameFallsBackToRawIdForUnknownShapes() {
    #expect(ModelName.display(for: "qwen3.5") == "qwen3.5")
    #expect(ModelName.display(for: "<synthetic>") == "<synthetic>")
    #expect(ModelName.display(for: "claude-") == "claude-")
}

@Test func onlyClaudeModelsCount() {
    #expect(ModelName.isClaudeModel("claude-opus-5"))
    #expect(ModelName.isClaudeModel("qwen3.5") == false)
    #expect(ModelName.isClaudeModel("<synthetic>") == false)
}

// MARK: - Parsing

private let assistantLine = #"{"type":"assistant","timestamp":"2026-07-25T07:41:10.705Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":2,"output_tokens":838,"cache_read_input_tokens":20606,"cache_creation_input_tokens":17069}}}"#

@Test func parsesAnAssistantMessage() {
    let e = TranscriptParser.parse(line: assistantLine)
    #expect(e?.model == "claude-opus-4-8")
    #expect(e?.hourBucket == "2026-07-25T07")
    #expect(e?.outputTokens == 838)
    #expect(e?.inputTokens == 2)
    #expect(e?.cacheReadTokens == 20606)
    #expect(e?.cacheCreationTokens == 17069)
}

@Test func ignoresNonAssistantLines() {
    #expect(TranscriptParser.parse(line: #"{"type":"user","timestamp":"2026-07-25T07:00:00.000Z"}"#) == nil)
    #expect(TranscriptParser.parse(line: #"{"type":"mode","mode":"normal"}"#) == nil)
}

@Test func ignoresNonClaudeModels() {
    let line = #"{"type":"assistant","timestamp":"2026-07-25T07:00:00.000Z","message":{"model":"qwen3.5","usage":{"output_tokens":10}}}"#
    #expect(TranscriptParser.parse(line: line) == nil)
}

@Test func ignoresSyntheticMessages() {
    let line = #"{"type":"assistant","timestamp":"2026-07-25T07:00:00.000Z","message":{"model":"<synthetic>","usage":{"output_tokens":0}}}"#
    #expect(TranscriptParser.parse(line: line) == nil)
}

@Test func ignoresMalformedLines() {
    #expect(TranscriptParser.parse(line: "") == nil)
    #expect(TranscriptParser.parse(line: "not json") == nil)
    #expect(TranscriptParser.parse(line: "{") == nil)
}

@Test func missingUsageFieldsDefaultToZero() {
    let line = #"{"type":"assistant","timestamp":"2026-07-25T07:00:00.000Z","message":{"model":"claude-opus-5","usage":{"output_tokens":5}}}"#
    let e = TranscriptParser.parse(line: line)
    #expect(e?.outputTokens == 5)
    #expect(e?.inputTokens == 0)
    #expect(e?.cacheReadTokens == 0)
}

@Test func missingUsageObjectIsRejected() {
    let line = #"{"type":"assistant","timestamp":"2026-07-25T07:00:00.000Z","message":{"model":"claude-opus-5"}}"#
    #expect(TranscriptParser.parse(line: line) == nil)
}

// MARK: - Incremental scanning

private func makeTempRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("headroom-scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func scansAllLinesOnFirstPass() throws {
    let root = try makeTempRoot()
    let file = root.appendingPathComponent("a.jsonl")
    try (assistantLine + "\n" + assistantLine + "\n").write(to: file, atomically: true, encoding: .utf8)

    let result = TranscriptScanner.scan(root: root, priorOffsets: [:])
    #expect(result.events.count == 2)
    #expect(result.offsets[file.resolvingSymlinksInPath().path] != nil)
}

@Test func secondScanReadsOnlyAppendedBytes() throws {
    let root = try makeTempRoot()
    let file = root.appendingPathComponent("a.jsonl")
    try (assistantLine + "\n").write(to: file, atomically: true, encoding: .utf8)

    let first = TranscriptScanner.scan(root: root, priorOffsets: [:])
    #expect(first.events.count == 1)

    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((assistantLine + "\n").utf8))
    try handle.close()

    let second = TranscriptScanner.scan(root: root, priorOffsets: first.offsets)
    #expect(second.events.count == 1)   // only the new line, not both
}

@Test func unchangedFileYieldsNoEvents() throws {
    let root = try makeTempRoot()
    try (assistantLine + "\n").write(to: root.appendingPathComponent("a.jsonl"),
                                     atomically: true, encoding: .utf8)
    let first = TranscriptScanner.scan(root: root, priorOffsets: [:])
    let second = TranscriptScanner.scan(root: root, priorOffsets: first.offsets)
    #expect(second.events.isEmpty)
}

@Test func partialTrailingLineIsDeferredNotDropped() throws {
    let root = try makeTempRoot()
    let file = root.appendingPathComponent("a.jsonl")
    // Complete line, then a half-written one with no newline yet.
    try (assistantLine + "\n" + #"{"type":"assis"#).write(to: file, atomically: true, encoding: .utf8)

    let first = TranscriptScanner.scan(root: root, priorOffsets: [:])
    #expect(first.events.count == 1)

    // The writer finishes the line.
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    let rest = #"tant","timestamp":"2026-07-25T08:00:00.000Z","message":{"model":"claude-opus-5","usage":{"output_tokens":7}}}"# + "\n"
    try handle.write(contentsOf: Data(rest.utf8))
    try handle.close()

    let second = TranscriptScanner.scan(root: root, priorOffsets: first.offsets)
    #expect(second.events.count == 1)
    #expect(second.events[0].outputTokens == 7)
}

@Test func truncatedFileIsRereadFromStart() throws {
    let root = try makeTempRoot()
    let file = root.appendingPathComponent("a.jsonl")
    try (assistantLine + "\n" + assistantLine + "\n").write(to: file, atomically: true, encoding: .utf8)
    let first = TranscriptScanner.scan(root: root, priorOffsets: [:])
    #expect(first.events.count == 2)

    // File replaced by a shorter one — offsets from the old file are meaningless.
    try (assistantLine + "\n").write(to: file, atomically: true, encoding: .utf8)
    let second = TranscriptScanner.scan(root: root, priorOffsets: first.offsets)
    #expect(second.events.count == 1)
}

@Test func nonJsonlFilesAreIgnored() throws {
    let root = try makeTempRoot()
    try (assistantLine + "\n").write(to: root.appendingPathComponent("notes.txt"),
                                     atomically: true, encoding: .utf8)
    #expect(TranscriptScanner.scan(root: root, priorOffsets: [:]).events.isEmpty)
}

@Test func missingRootYieldsNothing() {
    let root = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    #expect(TranscriptScanner.scan(root: root, priorOffsets: [:]).events.isEmpty)
}

// MARK: - Shares

private func row(_ model: String, output: Int) -> ModelUsageRow {
    ModelUsageRow(model: model, messages: 1, inputTokens: 0, outputTokens: output,
                  cacheReadTokens: 0, cacheCreationTokens: 0)
}

@Test func sharesSumToOneAndSortDescending() {
    let shares = ModelShare.shares([row("claude-sonnet-5", output: 25),
                                    row("claude-opus-5", output: 75)])
    #expect(shares[0].row.model == "claude-opus-5")
    #expect(abs(shares[0].share - 0.75) < 0.0001)
    #expect(abs(shares.reduce(0) { $0 + $1.share } - 1.0) < 0.0001)
}

@Test func sharesHandleZeroTotalWithoutDividingByZero() {
    let shares = ModelShare.shares([row("claude-opus-5", output: 0)])
    #expect(shares.count == 1)
    #expect(shares[0].share == 0)
}

@Test func sharesOfEmptyInputIsEmpty() {
    #expect(ModelShare.shares([]).isEmpty)
}

// MARK: - Bounded scanning

private func line(at ts: String, model: String = "claude-opus-5", out: Int = 1) -> String {
    #"{"type":"assistant","timestamp":"\#(ts)","message":{"model":"\#(model)","usage":{"output_tokens":\#(out)}}}"#
}

@Test func filesUntouchedSinceCutoffAreSkippedEntirely() throws {
    let root = try makeTempRoot()
    let file = root.appendingPathComponent("old.jsonl")
    try (line(at: "2020-01-01T00:00:00.000Z") + "\n").write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)

    let cutoff = Date(timeIntervalSince1970: 1_785_000_000)
    let result = TranscriptScanner.scan(root: root, priorOffsets: [:], since: cutoff)
    #expect(result.events.isEmpty)
    // Offset still recorded, so the file is never reopened.
    #expect(result.offsets[file.resolvingSymlinksInPath().path] != nil)
}

@Test func recentFilesAreScannedEvenWithACutoff() throws {
    let root = try makeTempRoot()
    try (line(at: "2026-07-25T07:00:00.000Z") + "\n")
        .write(to: root.appendingPathComponent("new.jsonl"), atomically: true, encoding: .utf8)
    // Relative to now: the file was just written, so it must fall inside any
    // window that starts in the past.
    let cutoff = Date().addingTimeInterval(-86400)
    #expect(TranscriptScanner.scan(root: root, priorOffsets: [:], since: cutoff).events.count == 1)
}

@Test func chunkedReadHandlesLinesSpanningChunkBoundaries() throws {
    let root = try makeTempRoot()
    let file = root.appendingPathComponent("big.jsonl")
    // Comfortably more than one 4 MB chunk, so boundaries land mid-line.
    var blob = ""
    for i in 0..<20_000 {
        blob += line(at: "2026-07-25T07:00:00.000Z", out: 1)
            .replacingOccurrences(of: #""usage""#, with: #""pad":"\#(String(repeating: "x", count: 300))","usage""#)
        blob += "\n"
        _ = i
    }
    try blob.write(to: file, atomically: true, encoding: .utf8)

    let result = TranscriptScanner.scan(root: root, priorOffsets: [:])
    #expect(result.events.count == 20_000)
    #expect(result.events.allSatisfy { $0.outputTokens == 1 })
}

@Test func binarySearchLandsBeforeTheCutoffNeverAfter() throws {
    let root = try makeTempRoot()
    let file = root.appendingPathComponent("timeline.jsonl")
    // 12 MB of ordered entries: first half old, second half inside the window.
    var blob = ""
    let pad = String(repeating: "x", count: 600)
    for _ in 0..<10_000 { blob += #"{"type":"assistant","timestamp":"2026-07-01T00:00:00.000Z","pad":"\#(pad)","message":{"model":"claude-opus-5","usage":{"output_tokens":1}}}"# + "\n" }
    for _ in 0..<10_000 { blob += #"{"type":"assistant","timestamp":"2026-07-25T07:00:00.000Z","pad":"\#(pad)","message":{"model":"claude-opus-5","usage":{"output_tokens":2}}}"# + "\n" }
    try blob.write(to: file, atomically: true, encoding: .utf8)

    let cutoff = ISO.date("2026-07-20T00:00:00.000Z")!
    let result = TranscriptScanner.scan(root: root, priorOffsets: [:], since: cutoff)

    // Every in-window event must be present. Reading some pre-cutoff ones is fine.
    let inWindow = result.events.filter { $0.outputTokens == 2 }
    #expect(inWindow.count == 10_000)
}

// MARK: - Project attribution

private let home = "/Users/tester"

@Test func rollsSubdirectoriesUpToTheProjectRoot() {
    // One project must not fragment across every directory visited in a session.
    #expect(ProjectName.display(for: "\(home)/research", home: home) == "research")
    #expect(ProjectName.display(for: "\(home)/research/code", home: home) == "research")
    #expect(ProjectName.display(for: "\(home)/research/latex/03_Content", home: home) == "research")
}

@Test func containerFoldersKeepTheirSecondComponent() {
    // "Documents" alone names nothing; every project under it would collapse together.
    #expect(ProjectName.display(for: "\(home)/Documents/DCPS", home: home) == "Documents/DCPS")
    #expect(ProjectName.display(for: "\(home)/Documents/DCPS/src", home: home) == "Documents/DCPS")
    #expect(ProjectName.display(for: "\(home)/Downloads/CV_EN", home: home) == "Downloads/CV_EN")
}

@Test func homeItselfIsItsOwnBucket() {
    #expect(ProjectName.display(for: home, home: home) == "~")
    #expect(ProjectName.display(for: "\(home)/Documents", home: home) == "Documents")
}

@Test func pathsOutsideHomeAreKeptWhole() {
    #expect(ProjectName.display(for: "/opt/thing", home: home) == "/opt/thing")
}

@Test func attributionComesFromCwdNotTheFolderName() {
    // The transcript folder encodes the path with separators replaced, so
    // "Annual_Report_EN" is unrecoverable from it. cwd is exact.
    let line = #"{"type":"assistant","timestamp":"2026-07-25T07:00:00.000Z","cwd":"\#(home)/Downloads/Annual_Report_EN","message":{"model":"claude-opus-5","usage":{"output_tokens":5}}}"#
    let event = TranscriptParser.parse(line: line)
    #expect(event?.project.contains("Annual_Report_EN") == true)
}

@Test func aRecordWithoutCwdIsMarkedUnknownNotDropped() {
    let line = #"{"type":"assistant","timestamp":"2026-07-25T07:00:00.000Z","message":{"model":"claude-opus-5","usage":{"output_tokens":5}}}"#
    #expect(TranscriptParser.parse(line: line)?.project == "unknown")
}
