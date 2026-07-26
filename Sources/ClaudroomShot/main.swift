//
// Renders the real DetailView to a PNG for the README.
//
// Uses the live database so the screenshot shows genuine numbers, but a stub
// network client so running it never touches the API or the Keychain.
//
// Usage: swift run ClaudroomShot docs/screenshot.png

import AppKit
import SwiftUI
import ClaudroomCore
import ClaudroomUI

/// Returns whatever the last real poll wrote to the database, so the rendered
/// view matches what the menu bar is actually showing.
struct ReplayClient: UsageFetching {
    let path: String

    func fetchUsage(token: String, now: Date) async throws -> UsageSnapshot {
        let db = try Database(path: path)
        let rows = try db.query(
            "SELECT raw_json FROM samples ORDER BY observed_at DESC LIMIT 1")
        guard let raw = rows.first?["raw_json"]?.stringValue else {
            throw UsageClientError.transport
        }
        return try UsageDecoder.decode(data: Data(raw.utf8), observedAt: now)
    }

    func fetchProfile(token: String) async throws -> Profile {
        throw UsageClientError.transport
    }
}

/// Dev tool: renders the menu bar mark at every state, on both menu bar
/// appearances, magnified. At 16pt on a live bar these differences are too small
/// to judge by squinting at the real thing.
@MainActor
func glyphSheet(to path: String) -> Int32 {
    let now = Date()
    let states: [(String, MenuBarLabel)] = [
        ("session 90%", .sessionActive(remaining: 0.90, resetsAt: now)),
        ("session 54%", .sessionActive(remaining: 0.54, resetsAt: now)),
        ("session 12%", .sessionActive(remaining: 0.12, resetsAt: now)),
        ("no session",  .noSession),
        ("week closing", .weekClosingUnderused(sessionRemaining: 0.54,
                                               weeklyRemaining: 0.7, resetsAt: now)),
        ("stale",       .stale),
        ("signed out",  .notSignedIn),
    ]

    let cell = CGSize(width: 128, height: 128)
    let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(states.count),
                                     height: cell.height * 2))
    sheet.lockFocus()
    for (row, background) in [NSColor.white, NSColor.black].enumerated() {
        background.setFill()
        NSRect(x: 0, y: CGFloat(row) * cell.height,
               width: cell.width * CGFloat(states.count), height: cell.height).fill()
        for (col, entry) in states.enumerated() {
            let glyph = MenuBarGlyph.image(for: entry.1)
            let box = NSRect(x: CGFloat(col) * cell.width + 24,
                             y: CGFloat(row) * cell.height + 24,
                             width: 80, height: 80)
            glyph.draw(in: box)
        }
    }
    sheet.unlockFocus()

    guard let tiff = sheet.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return 1 }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) — \(states.map(\.0).joined(separator: ", "))")
    return 0
}

/// Dev tool: drives the historical backfill from the command line so it can be
/// verified and timed without clicking through the UI.
@MainActor
func backfill() async -> Int32 {
    let storeDir = AppModel.defaultStoreDirectory()
    let model = AppModel(client: ReplayClient(path: storeDir.appendingPathComponent("usage.sqlite").path),
                         storeDirectory: storeDir,
                         autoStart: false)
    let started = ProcessInfo.processInfo.systemUptime
    await model.backfillHistory()
    let elapsed = ProcessInfo.processInfo.systemUptime - started

    model.loadActivity()
    let days = Set(model.dailyActivity.map(\.day)).count
    let tokens = model.dailyActivity.reduce(0) { $0 + $1.outputTokens }
    print(String(format: "backfill finished in %.1fs", elapsed))
    print("  \(days) days with activity, \(tokens) output tokens recorded")
    if let first = model.activityFirstDay {
        print("  earliest day: \(first)")
    }
    return 0
}

@MainActor
func render() async -> Int32 {
    let out = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "screenshot.png"
    let wantsDemo = CommandLine.arguments.contains("--demo")

    // Documentation images render from synthetic data. Rendering them from a real
    // database publishes that person's project names, working hours and spend, and
    // silently re-publishes them on every layout change.
    let storeDir: URL
    if wantsDemo {
        storeDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudroom-demo-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    } else {
        storeDir = AppModel.defaultStoreDirectory()
    }
    let dbPath = storeDir.appendingPathComponent("usage.sqlite").path
    defer { if wantsDemo { try? FileManager.default.removeItem(at: storeDir) } }

    if wantsDemo {
        do {
            let store = try Store(database: try Database(path: dbPath))
            try DemoData.seed(into: store, now: Date())
        } catch {
            FileHandle.standardError.write(Data("could not seed demo data: \(error)\n".utf8))
            return 1
        }
    } else if !FileManager.default.fileExists(atPath: dbPath) {
        FileHandle.standardError.write(Data("no database at \(dbPath) — run the app first, or pass --demo\n".utf8))
        return 1
    }

    // hydrateFromStore, not pollOnce: this binary is unsigned, so reading the
    // Keychain would raise a credential prompt and hang.
    let model = AppModel(client: ReplayClient(path: dbPath),
                         storeDirectory: storeDir,
                         autoStart: false)
    model.hydrateFromStore()

    let wantsDashboard = CommandLine.arguments.contains("--dashboard")
    model.loadActivity()

    // Open the costliest project so the documentation screenshot shows the
    // drill-down rather than a panel that looks static.
    if wantsDashboard, let top = model.projectUsage.first {
        model.selectProject(top.project)
    }

    let content = Group {
        if wantsDashboard {
            DashboardContent(model: model).frame(width: 880)
                .background(CapacityField(intensities: model.fieldIntensities))
        } else {
            DetailView(model: model)
                .background(Palette.paper)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(20)
        }
    }
    .background(Palette.paper)
    .environment(\.allowsLiquidGlass, false)   // ImageRenderer cannot capture it

    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    // Without this the PNG keeps an alpha channel, and GitHub's dark theme shows
    // straight through the light UI.
    renderer.isOpaque = true

    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("render failed\n".utf8))
        return 1
    }

    try? png.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)  \(Int(image.size.width * 2))x\(Int(image.size.height * 2))")
    return 0
}

if CommandLine.arguments.contains("--backfill") {
    exit(await backfill())
}
if CommandLine.arguments.contains("--glyphs") {
    let out = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
    exit(await glyphSheet(to: out ?? "build/glyphs.png"))
}
exit(await render())
