import SwiftUI
import AppKit
import ClaudroomCore


public struct DetailView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false

    public init(model: AppModel) { self.model = model }

    @Environment(\.openWindow) private var openWindow
    /// Drives countdown text; the model itself only refreshes on poll.
    @State private var tick = Date()

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.needsAuthorization {
                Divider().padding(.vertical, 10)
                authorizationBanner
            }
            Divider().padding(.vertical, 10)
            capacity
            Divider().padding(.vertical, 10)
            adviceSection
            Divider().padding(.vertical, 10)
            models
            Divider().padding(.vertical, 10)
            verdictSection
            if showSettings {
                Divider().padding(.vertical, 10)
                SettingsView(model: model)
            }
            Divider().padding(.vertical, 10)
            footer
        }
        .padding(14)
        .frame(width: 316)
        .onReceive(ticker) { tick = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claudroom")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            }
            if let tier = model.tier {
                Text(tier.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    /// Claude Code drops Claudroom from its Keychain item's ACL every time it
    /// refreshes its token, so authorisation is needed again every few hours.
    /// Background polls never ask — they would put a password dialog over whatever
    /// the user is doing, for an app they are not looking at. It waits here
    /// instead, and the dialog only appears because a button was pressed.
    private var authorizationBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.clay)
                Text("Keychain access needed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.ink)
            }
            Text("Claude Code refreshed its token, which resets the permission. Numbers are the last known reading until you reconnect.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reconnect") {
                Task { await model.authorizeNow() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Palette.clay)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Capacity — the weekly cap is the budget, the 5h window is a rate limit

    @ViewBuilder private var capacity: some View {
        if let snap = model.snapshot {
            VStack(alignment: .leading, spacing: 12) {
                if let weekly = snap.weekly {
                    CapacityMeter(
                        title: "This week",
                        used: weekly.fraction,
                        detail: countdown(to: weekly.resetsAt),
                        prominent: true)
                }
                if let five = snap.fiveHour {
                    CapacityMeter(
                        title: "5-hour window",
                        used: five.fraction,
                        detail: countdown(to: five.resetsAt),
                        prominent: false)
                } else {
                    // Never let a limiter silently disappear — say it is unavailable.
                    HStack {
                        Text("5-hour window").font(.system(size: 11))
                        Spacer()
                        Text("unavailable").font(.system(size: 11))
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        } else {
            Text(model.lastError ?? "Waiting for first reading…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Session advice

    @ViewBuilder private var adviceSection: some View {
        if let advice = model.advice, advice.limiter != .unknown {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: adviceSymbol(advice.limiter))
                        .foregroundStyle(adviceTint(advice.limiter))
                        .font(.system(size: 11, weight: .semibold))
                    Text(advice.headline)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(adviceTint(advice.limiter))
                }
                Text(advice.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let burn = advice.burnPerHour, burn > 0.0005 {
                    HStack(spacing: 4) {
                        Text(String(format: "burning %.1f%%/h", burn * 100))
                        if let capAt = advice.projectedCapAt {
                            Text("· caps \(capAt.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                }
            }
        }
    }

    private func adviceSymbol(_ l: BindingLimiter) -> String {
        switch l {
        case .rateLimited: return "bolt.horizontal.circle"
        case .planCeiling: return "exclamationmark.triangle"
        case .underUsing:  return "leaf"
        case .frontLoaded: return "gauge.with.needle"
        case .unknown:     return "questionmark.circle"
        }
    }

    private func adviceTint(_ l: BindingLimiter) -> Color {
        switch l {
        case .rateLimited: return Palette.clayDeep
        case .planCeiling: return Palette.clayDeep
        case .underUsing:  return Palette.series[3]
        case .frontLoaded: return Palette.series[2]
        case .unknown:     return Palette.inkSoft
        }
    }

    // MARK: - Per-model split

    @ViewBuilder private var models: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("By model")
                Spacer()
                Eyebrow("this cycle", tint: Palette.inkFaint)
            }

            let shares = ModelShare.shares(model.modelUsage)
            if shares.isEmpty {
                Text(model.isScanning ? "Reading transcripts…" : "No model activity yet this cycle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(shares.prefix(6).enumerated()), id: \.element.row.model) { index, entry in
                    ModelRow(row: entry.row, share: entry.share, index: index)
                }
                Text("Share of output tokens — not of your rate limit.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Right-sizing

    @ViewBuilder private var verdictSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.verdict {
            case .collecting(let have, let need):
                Label("Right-sizing: \(have)/\(need) cycles collected",
                      systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            case .stay(let peak):
                Label(String(format: "Plan fits — peak %.0f%% over recent cycles", peak),
                      systemImage: "checkmark.circle")
                    .font(.caption)
            case .downgrade(let to, let projected):
                Label(String(format: "%@ would cover you — projected %.0f%%",
                             to.displayName, projected),
                      systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(.green)
            case .upgrade(let to, let capped):
                Label("Capped out in \(capped) of last 4 cycles — consider \(to.displayName)",
                      systemImage: "arrow.up.circle")
                    .font(.caption).foregroundStyle(.orange)
            case .unavailable:
                Label("Right-sizing unavailable for this plan", systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let err = model.lastError {
                Label(err, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            } else if let last = model.lastSuccess {
                Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Activity") {
                // Activate first, then open. An LSUIElement app is not frontmost
                // when the menu bar popover is showing, and a window created
                // while the app is inactive comes up non-key: it draws correctly
                // but swallows the first click, which reads as "nothing is
                // clickable". Activating first means the window is born key.
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: DashboardWindow.id)
                // Re-assert on the next runloop turn: openWindow is async, and on
                // a cold open the window can still land behind the previously
                // active app.
                DispatchQueue.main.async {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.windows
                        .first { $0.identifier?.rawValue.contains(DashboardWindow.id) == true }?
                        .makeKeyAndOrderFront(nil)
                }
            }
            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.tint)
            Button(showSettings ? "Done" : "Settings") { showSettings.toggle() }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.tint)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.tint)
        }
    }

    // MARK: - Formatting

    private func countdown(to date: Date?) -> String {
        // No reset timestamp means no window is running — normal right after a
        // 5-hour window resets and before the next request starts a new one.
        guard let date else { return "no active window" }
        let secs = max(0, date.timeIntervalSince(tick))
        let minutes = Int(secs) / 60
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        if d > 0 { return "resets in \(d)d \(h)h" }
        if h > 0 { return "resets in \(h)h \(m)m" }
        return "resets in \(m)m"
    }
}

/// Shows what is LEFT, not what is spent — the app is named for the gap.
struct CapacityMeter: View {
    let title: String
    let used: Double
    let detail: String
    let prominent: Bool

    private var remaining: Double { max(0, 1 - used) }

    /// Clay throughout, deepening as the window fills. One accent doing the work,
    /// rather than a traffic light — the app is about how much is left, not alarm.
    private var tint: Color {
        used < 0.85 ? Palette.clay : Palette.clayDeep
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: prominent ? 12 : 11,
                                  weight: prominent ? .medium : .regular))
                Spacer()
                Text(String(format: "%.0f%% left", remaining * 100))
                    .font(.system(size: prominent ? 16 : 11,
                                  weight: prominent ? .semibold : .regular,
                                  design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(prominent ? tint : Palette.inkSoft)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.ink.opacity(0.07))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * min(max(used, 0), 1))
                }
            }
            .frame(height: prominent ? 6 : 4)
            HStack {
                Text(String(format: "%.0f%% used", used * 100))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ModelRow: View {
    let row: ModelUsageRow
    let share: Double
    let index: Int

    /// By position, so adjacent rows are always visually distinct. Hashing the model
    /// name looked stable but collided — Opus 4.8 and Haiku 4.5 both landed on brown.
    private var color: Color { Palette.series[index % Palette.series.count] }

    private func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(row.displayName).font(.system(size: 11))
                Spacer()
                Text(String(format: "%.0f%%", share * 100))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.ink.opacity(0.07))
                    Capsule().fill(color)
                        .frame(width: max(2, geo.size.width * min(max(share, 0), 1)))
                }
            }
            .frame(height: 3)
            Text("\(compact(row.outputTokens)) out · \(compact(row.messages)) msgs")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}
