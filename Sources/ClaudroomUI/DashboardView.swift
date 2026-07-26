import SwiftUI
import Charts
import ClaudroomCore

public enum DashboardWindow {
    public static let id = "dashboard"
}

/// Scrolling wrapper for the window. Kept separate from `DashboardContent` because
/// ImageRenderer cannot render a ScrollView — it has no intrinsic size offscreen and
/// comes out blank.
public struct DashboardView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ScrollView {
            DashboardContent(model: model)
        }
        .background(CapacityField(intensities: model.fieldIntensities))
        .frame(minWidth: 820, minHeight: 600)
        .onAppear { model.loadActivity() }
    }
}

public struct DashboardContent: View {
    @Bindable var model: AppModel
    @State private var showAllProjects = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            masthead
            cycleHero
            readingRow
            whereItWent
            byProject
            whenYouWork
            byModel
            footnote
        }
        .padding(26)
    }

    // MARK: - Masthead

    private var masthead: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Claudroom")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)

            HStack(spacing: 3) {
                ForEach(DashboardRange.allCases) { option in
                    RangeChip(label: option.label,
                              isOn: model.range == option) {
                        model.setRange(option)
                    }
                }
            }
            .padding(.leading, 6)

            Spacer()
            if let progress = model.backfillProgress {
                HStack(spacing: 8) {
                    ProgressView(value: progress).frame(width: 90).controlSize(.small)
                    Text("\(Int(progress * 100))%")
                        .font(TypeScale.reading(10)).foregroundStyle(Palette.inkSoft)
                }
            } else {
                Button(model.hasBackfilled ? "Rescan history" : "Load full history") {
                    Task { await model.backfillHistory() }
                }
                .font(TypeScale.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Palette.clayDeep)
            }
            if let tier = model.tier {
                Eyebrow(tier.displayName, tint: Palette.inkSoft)
            }
        }
    }

    // MARK: - Hero: the cycle as a bar of material

    private var cycleHero: some View {
        let buckets = model.cycleActivity()
        let peak = max(1, ActivityTimeline.peakTokens(buckets))
        let weekly = model.snapshot?.weekly

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("This cycle")
                Spacer()
                if let resetsAt = weekly?.resetsAt {
                    Eyebrow("resets \(relative(to: resetsAt))", tint: Palette.inkFaint)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(weekly.map { String(format: "%.0f", (1 - $0.fraction) * 100) } ?? "—")
                    .font(.system(size: 62, weight: .medium, design: .monospaced))
                    .tracking(-2)
                    .foregroundStyle(Palette.ink)
                VStack(alignment: .leading, spacing: -2) {
                    Text("%").font(TypeScale.reading(20)).foregroundStyle(Palette.inkSoft)
                    Text("left").font(TypeScale.body).foregroundStyle(Palette.inkSoft)
                }
                Spacer()
                if let weekly {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "%.0f%%", weekly.fraction * 100))
                            .font(TypeScale.reading(15))
                            .foregroundStyle(Palette.clayDeep)
                        Eyebrow("spent", tint: Palette.inkFaint)
                    }
                }
            }

            WeekMaterial(buckets: buckets, peak: peak)

            HStack {
                Eyebrow("\(ActivityTimeline.activeHours(buckets)) active hours",
                        tint: Palette.inkFaint)
                Spacer()
                Eyebrow("\(ActivityTimeline.idleElapsedHours(buckets)) idle so far",
                        tint: Palette.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 22)
    }

    // MARK: - Three readings

    private var readingRow: some View {
        HStack(spacing: 14) {
            Reading(
                label: "5-hour window",
                value: model.snapshot?.fiveHour.map {
                    String(format: "%.0f%%", (1 - $0.fraction) * 100)
                } ?? "—",
                unit: "left",
                note: model.snapshot?.fiveHour?.resetsAt.map { "resets \(relative(to: $0))" }
                    ?? "no window running",
                tint: sessionTint)

            Reading(
                label: "Pace",
                value: model.pace.map { String(format: "%.0f%%", $0.projectedClose * 100) } ?? "—",
                unit: "at close",
                note: paceNote,
                tint: paceTint)

            Reading(
                label: "Rhythm",
                value: model.peakHours.map { String(format: "%02d–%02d", $0.start, $0.end) } ?? "—",
                unit: "busiest",
                note: model.peakHours == nil ? "no clear peak" : "start windows here",
                tint: Palette.series[1])

            Reading(
                label: "API equivalent",
                value: Pricing.money(model.totalAPICost),
                unit: "list price",
                note: model.activeDays > 0 ? "across \(model.activeDays) active days"
                                           : "nothing recorded yet",
                tint: Palette.series[2])
        }
    }

    private var paceNote: String {
        guard let pace = model.pace else { return "too early to project" }
        if pace.projectedClose >= 1 { return "heading past the cap" }
        return pace.projectedClose < 0.5 ? "over half will expire" : "on this trajectory"
    }

    private var sessionTint: Color {
        guard let five = model.snapshot?.fiveHour else { return Palette.inkFaint }
        return five.fraction >= 0.85 ? Palette.clayDeep : Palette.clay
    }

    private var paceTint: Color {
        guard let pace = model.pace else { return Palette.inkFaint }
        if pace.projectedClose >= 1 { return Palette.clayDeep }
        return pace.projectedClose < 0.5 ? Palette.series[2] : Palette.clay
    }

    // MARK: - Where it went

    private var whereItWent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("Where it went")
                Spacer()
                // The span actually being reported, not just its start — with a
                // range filter, "since 29 May" no longer says where it ends.
                if let first = model.activityFirstDay, let last = model.activityLastDay {
                    let fmt = Date.FormatStyle.dateTime.day().month(.abbreviated)
                    Eyebrow("\(first.formatted(fmt)) – \(last.formatted(fmt))",
                            tint: Palette.inkFaint)
                }
            }

            if model.dailyActivity.isEmpty {
                emptyHistoryHint
            } else {
                Chart(model.dailyActivity) { entry in
                    BarMark(
                        x: .value("Day", entry.day, unit: .day),
                        y: .value("Output", entry.outputTokens)
                    )
                    .foregroundStyle(by: .value("Model", entry.displayName))
                    .cornerRadius(1.5)
                }
                .chartForegroundStyleScale(
                    domain: model.orderedModelNames,
                    range: Array(Palette.series.prefix(max(1, model.orderedModelNames.count))))
                .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                .chartYAxis { compactAxis }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 14)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 190)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    @ViewBuilder private var emptyHistoryHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No history yet.").font(TypeScale.body).foregroundStyle(Palette.ink)
            Text("Routine scans only read transcripts touched since this cycle began. Load full history to read them all once.")
                .font(TypeScale.caption).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Which projects

    private var byProject: some View {
        let rows = model.projectUsage
        // Ranked and drawn by cost rather than output tokens: a cache-heavy
        // project can cost more than one that generated twice the output.
        let grand = max(0.01, rows.reduce(0) { $0 + $1.apiCost })

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("Which projects")
                Spacer()
                Eyebrow("API equivalent · output", tint: Palette.inkFaint)
            }

            if rows.isEmpty {
                Text("Nothing recorded yet.").font(TypeScale.body).foregroundStyle(Palette.inkSoft)
            } else {
                let shown = showAllProjects ? rows : Array(rows.prefix(8))
                VStack(spacing: 3) {
                    ForEach(shown) { row in
                        let isOpen = model.selectedProject?.project == row.project
                        ProjectRow(row: row,
                                   share: row.apiCost / grand,
                                   isOpen: isOpen) {
                            model.selectProject(row.project)
                        }

                        if isOpen, let detail = model.selectedProject {
                            projectBreakdown(detail)
                        }
                    }
                }

                if rows.count > 8 {
                    TapLabel(showAllProjects
                             ? "show fewer"
                             : "show \(rows.count - 8) more") {
                        showAllProjects.toggle()
                    }
                }

                if model.selectedProject == nil {
                    Eyebrow("click a project for its cost breakdown", tint: Palette.inkFaint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    /// Why a project costs what it does. Ranked by cost within the project, which
    /// is usually a surprise: output is the line people expect to lead and cache
    /// reads are the line that actually does.
    private func projectBreakdown(_ detail: ProjectDetail) -> some View {
        let grand = max(0.01, detail.totalCost)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Pricing.money(detail.totalCost))
                    .font(TypeScale.reading(16))
                    .foregroundStyle(Palette.clayDeep)
                Text("\(compact(detail.totalTokens)) tokens · \(compact(detail.messages)) messages")
                    .font(TypeScale.caption)
                    .foregroundStyle(Palette.inkSoft)
                Spacer()
                Eyebrow("where the cost is", tint: Palette.inkFaint)
            }

            costLines(detail.byTokenClass, grand: grand, tint: Palette.clay)

            if detail.byModel.count > 1 {
                Divider().overlay(Palette.ink.opacity(0.07)).padding(.vertical, 1)
                costLines(detail.byModel, grand: grand, tint: Palette.series[1])
            }

            if detail.unpricedTokens > 0 {
                Text("\(compact(detail.unpricedTokens)) tokens on unpriced models, excluded above.")
                    .font(TypeScale.caption)
                    .foregroundStyle(Palette.inkFaint)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.ink.opacity(0.04)))
        .padding(.leading, 14)
        .padding(.top, 2)
    }

    private func costLines(_ lines: [Pricing.Line], grand: Double, tint: Color) -> some View {
        VStack(spacing: 6) {
            ForEach(lines) { line in
                HStack(spacing: 10) {
                    Text(line.label)
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.inkSoft)
                        .lineLimit(1)
                        .frame(width: 82, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.ink.opacity(0.05))
                            Capsule().fill(tint.opacity(0.75))
                                .frame(width: max(2, geo.size.width * CGFloat(line.cost / grand)))
                        }
                    }
                    .frame(height: 4)
                    Text(compact(line.tokens))
                        .font(TypeScale.reading(10))
                        .foregroundStyle(Palette.inkFaint)
                        .frame(width: 52, alignment: .trailing)
                    Text(Pricing.money(line.cost))
                        .font(TypeScale.reading(10))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 54, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - When you work

    private var whenYouWork: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("When you work")
                Spacer()
                Eyebrow("local time", tint: Palette.inkFaint)
            }

            if model.hourProfile.allSatisfy({ $0 == 0 }) {
                Text("No activity recorded yet.")
                    .font(TypeScale.body).foregroundStyle(Palette.inkSoft)
            } else {
                Chart(Array(model.hourProfile.enumerated()), id: \.offset) { hour, tokens in
                    BarMark(
                        x: .value("Hour", hour),
                        y: .value("Output", tokens),
                        width: .fixed(9)
                    )
                    .foregroundStyle(inPeak(hour) ? Palette.clay : Palette.clay.opacity(0.28))
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                        AxisValueLabel {
                            if let h = value.as(Int.self) {
                                Text(String(format: "%02d", h)).font(TypeScale.eyebrow)
                            }
                        }
                    }
                }
                .chartYAxis { compactAxis }
                .frame(height: 110)

                Eyebrow(model.peakHours.map {
                    "darker bars mark \(String(format: "%02d:00–%02d:59", $0.start, $0.end))"
                } ?? "no clear peak", tint: Palette.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private func inPeak(_ hour: Int) -> Bool {
        guard let peak = model.peakHours else { return false }
        if peak.start <= peak.end { return hour >= peak.start && hour <= peak.end }
        return hour >= peak.start || hour <= peak.end
    }

    // MARK: - By model

    private var byModel: some View {
        let totals = model.modelTotals
        // Cost, to match the number beside the bar and the projects panel. Drawing
        // output share here while printing cost put two different quantities on
        // one row and read as a rendering bug.
        let grand = max(0.01, totals.reduce(0.0) { $0 + ($1.cost ?? 0) })

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("By model")
                Spacer()
                Eyebrow("API equivalent · output", tint: Palette.inkFaint)
            }

            if totals.isEmpty {
                Text("Nothing recorded yet.").font(TypeScale.body).foregroundStyle(Palette.inkSoft)
            } else {
                VStack(spacing: 9) {
                    ForEach(Array(totals.enumerated()), id: \.element.name) { index, row in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Palette.series[index % Palette.series.count])
                                .frame(width: 3, height: 20)
                            Text(row.name)
                                .font(TypeScale.body)
                                .foregroundStyle(Palette.ink)
                                .frame(width: 84, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Palette.ink.opacity(0.06))
                                    Capsule()
                                        .fill(Palette.series[index % Palette.series.count])
                                        .frame(width: max(3, geo.size.width
                                               * CGFloat((row.cost ?? 0) / grand)))
                                }
                            }
                            .frame(height: 5)
                            Text(row.cost.map(Pricing.money) ?? "—")
                                .font(TypeScale.reading(11))
                                .foregroundStyle(row.cost == nil ? Palette.inkFaint : Palette.ink)
                                .frame(width: 58, alignment: .trailing)
                            Text(compact(row.tokens))
                                .font(TypeScale.reading(10))
                                .foregroundStyle(Palette.inkFaint)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    // MARK: - Footnote

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("API equivalent is what this work would have cost at pay-as-you-go list prices — cache reads bill at a tenth of input, cache writes at double. You pay a flat licence and owe none of it.")
                .font(TypeScale.caption)
                .foregroundStyle(Palette.inkFaint)
            Text("Neither column is a share of your rate limit — models consume the cap at different rates and the weighting is not published.")
                .font(TypeScale.caption)
                .foregroundStyle(Palette.inkFaint)
            if model.unpricedTokens > 0 {
                Text("\(compact(model.unpricedTokens)) tokens came from models with no published price on file and are excluded from the cost figures.")
                    .font(TypeScale.caption)
                    .foregroundStyle(Palette.inkFaint)
            }
            if let cache = model.cacheHealth {
                Text(String(format: "%.0f%% of cached context reused%@",
                            cache.reuseFraction * 100,
                            cache.isHealthy ? "." : " — context is being rebuilt often."))
                    .font(TypeScale.caption)
                    .foregroundStyle(Palette.inkFaint)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    private var compactAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine().foregroundStyle(Palette.ink.opacity(0.07))
            AxisValueLabel {
                if let n = value.as(Int.self) {
                    Text(compact(n)).font(TypeScale.eyebrow)
                }
            }
        }
    }

    private func relative(to date: Date) -> String {
        let secs = max(0, date.timeIntervalSinceNow)
        let minutes = Int(secs) / 60
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        if d > 0 { return "in \(d)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(m)m"
    }

    private func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...:     return String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...:         return String(format: "%.0fK", Double(n) / 1e3)
        default:               return "\(n)"
        }
    }
}

/// The signature element: the cycle drawn as a bar of material being consumed.
///
/// 168 hours wide. Clay marks hours where work happened, sized by how much. The
/// elapsed-but-empty hours are the gap the app exists to show, so they stay as
/// visible voids rather than being compressed away. A hairline marks now.
struct WeekMaterial: View {
    let buckets: [ActivityBucket]
    let peak: Int

    var body: some View {
        GeometryReader { geo in
            let count = max(buckets.count, 1)
            let unit = geo.size.width / CGFloat(count)
            let nowIndex = buckets.firstIndex(where: \.isFuture)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Palette.ink.opacity(0.05))

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                        Rectangle()
                            .fill(fill(bucket))
                            .frame(width: max(0.6, unit - 0.35),
                                   height: height(bucket, full: geo.size.height))
                            .frame(height: geo.size.height, alignment: .bottom)
                            .padding(.trailing, 0.35)
                    }
                }

                if let nowIndex {
                    Rectangle()
                        .fill(Palette.ink.opacity(0.45))
                        .frame(width: 1)
                        .offset(x: unit * CGFloat(nowIndex))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 46)
    }

    private func fill(_ bucket: ActivityBucket) -> Color {
        if bucket.isActive { return Palette.clay }
        return bucket.isFuture ? Palette.ink.opacity(0.04) : Palette.rest.opacity(0.5)
    }

    private func height(_ bucket: ActivityBucket, full: CGFloat) -> CGFloat {
        guard bucket.isActive else { return bucket.isFuture ? full : 2.5 }
        return max(3, full * CGFloat(bucket.outputTokens) / CGFloat(peak))
    }
}

/// One instrument reading. Deliberately spare: a label, a number, a unit, a note.
/// One clickable project row.
///
/// A tap gesture on the row rather than a `Button`: with `.buttonStyle(.plain)`
/// the hit area follows the label's own shape, which a row built from a
/// `GeometryReader` and fixed-width columns does not reliably fill. The hover
/// highlight is also the diagnostic — if the row lights up, it is receiving mouse
/// events, and any remaining problem is downstream of hit testing.
struct ProjectRow: View {
    let row: ProjectUsageRow
    let share: Double
    let isOpen: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(row.project)
                .font(TypeScale.body)
                .foregroundStyle(isOpen ? Palette.clayDeep : Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 146, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.ink.opacity(0.06))
                    Capsule()
                        .fill(isOpen ? Palette.clayDeep : Palette.clay.opacity(0.85))
                        .frame(width: max(3, geo.size.width * CGFloat(share)))
                }
            }
            .frame(height: 5)
            Text(Pricing.money(row.apiCost))
                .font(TypeScale.reading(11))
                .foregroundStyle(isOpen ? Palette.clayDeep : Palette.ink)
                .frame(width: 58, alignment: .trailing)
            Text(compactTokens(row.outputTokens))
                .font(TypeScale.reading(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Palette.ink.opacity(isOpen ? 0.06 : (hovering ? 0.045 : 0)))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .help(isOpen ? "Hide breakdown" : "Show where this project's cost came from")
    }
}

/// One segment of the range filter.
struct RangeChip: View {
    let label: String
    let isOn: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Text(label)
            .font(TypeScale.reading(10))
            .tracking(0.3)
            .foregroundStyle(isOn ? Palette.paper : Palette.inkSoft)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isOn ? Palette.clay
                                    : Palette.ink.opacity(hovering ? 0.07 : 0.04))
            )
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onTap)
    }
}

/// A text control that behaves like a link. Same reasoning as `ProjectRow`.
struct TapLabel: View {
    let text: String
    let onTap: () -> Void
    @State private var hovering = false

    init(_ text: String, onTap: @escaping () -> Void) {
        self.text = text
        self.onTap = onTap
    }

    var body: some View {
        Eyebrow(text, tint: hovering ? Palette.clayDeep : Palette.clay)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onTap)
    }
}

/// Shared by the row views, which sit outside `DashboardContent` and so cannot
/// reach its private formatter.
func compactTokens(_ n: Int) -> String {
    switch n {
    case ..<1_000: return "\(n)"
    case ..<1_000_000: return String(format: "%.0fK", Double(n) / 1_000)
    case ..<1_000_000_000: return String(format: "%.1fM", Double(n) / 1_000_000)
    default: return String(format: "%.1fB", Double(n) / 1_000_000_000)
    }
}

struct Reading: View {
    let label: String
    let value: String
    let unit: String
    let note: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Eyebrow(label)
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(value)
                    .font(TypeScale.reading(23))
                    .tracking(-0.6)
                    .foregroundStyle(tint)
                Text(unit).font(TypeScale.caption).foregroundStyle(Palette.inkSoft)
            }
            Text(note)
                .font(TypeScale.caption)
                .foregroundStyle(Palette.inkFaint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 14)
    }
}
