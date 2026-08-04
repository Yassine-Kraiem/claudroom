import Foundation
import SwiftUI
import UserNotifications
import ClaudroomCore

@MainActor
@Observable
public final class AppModel {
    public private(set) var label: MenuBarLabel = .stale
    public private(set) var snapshot: UsageSnapshot?
    public private(set) var verdict: RightSizingVerdict = .collecting(have: 0, need: Analytics.minimumCycles)
    public private(set) var lastSuccess: Date?
    public private(set) var lastError: String?
    public private(set) var hasCredentials = true
    /// Claude Code's Keychain item needs authorising again. Not an error — a
    /// decision waiting for the user, so nothing retries into it automatically.
    public private(set) var needsAuthorization = false
    public private(set) var tier: PlanTier?
    public private(set) var modelUsage: [ModelUsageRow] = []
    public private(set) var isScanning = false
    public private(set) var advice: SessionAdvice?
    public private(set) var backfillProgress: Double?
    public private(set) var dailyActivity: [DailyActivity] = []
    public private(set) var activityFirstDay: Date?
    public private(set) var activityLastDay: Date?
    public private(set) var projectUsage: [ProjectUsageRow] = []
    /// Per-model totals across all recorded history, as opposed to `modelUsage`,
    /// which covers the open cycle only. Cost needs the full input/cache
    /// breakdown, which the daily rows do not carry.
    public private(set) var lifetimeModelUsage: [ModelUsageRow] = []
    public private(set) var pace: CyclePace?
    public private(set) var cacheHealth: CacheHealth?
    public private(set) var hourProfile: [Int] = []
    public private(set) var peakHours: (start: Int, end: Int)?
    public private(set) var idleDays: Int = 0
    public private(set) var activeDays: Int = 0

    private let store: Store
    private let client: any UsageFetching
    private var pollTask: Task<Void, Never>?
    /// Held in memory so the Keychain is touched about once per token lifetime
    /// rather than once per poll. See `credentials(now:)`.
    private var cachedCredentials: Credentials?

    /// Stale once roughly two idle-interval polls have failed in a row.
    private static let stalenessWindow: TimeInterval = 25 * 60
    private static let activeInterval: TimeInterval = 60
    private static let idleInterval: TimeInterval = 600
    private static let coldStartInterval: TimeInterval = 15
    private static let maxBackoff: TimeInterval = 600

    public static func defaultStoreDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claudroom", isDirectory: true)
    }

    /// `client` and `storeDirectory` are injectable so the screenshot renderer can
    /// drive the real views without touching the network. `autoStart: false` keeps
    /// it a one-shot read instead of a live poller.
    public init(client: (any UsageFetching)? = nil,
                storeDirectory: URL? = nil,
                autoStart: Bool = true) {
        let dir = storeDirectory ?? Self.defaultStoreDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let db = try! Database(path: dir.appendingPathComponent("usage.sqlite").path)
        self.store = try! Store(database: db)
        self.client = client ?? UsageClient()

        loadSettings()
        // Show the last known reading immediately rather than an em dash while the
        // first poll runs.
        hydrateFromStore()
        loadActivity()
        // Polling starts at launch, not when the popover is first opened — the
        // whole point is watching stretches where you aren't looking at it.
        if autoStart { start() }

        // Dev aid for verifying the login item registers without clicking through
        // Settings; SMAppService only works from a real bundle.
        if ProcessInfo.processInfo.environment["CLAUDROOM_ENABLE_LOGIN_ITEM"] == "1" {
            try? LaunchAtLogin.set(true)
        }
        // Recorded so the state can be inspected without clicking into Settings.
        try? store.setSetting("launch_at_login", LaunchAtLogin.isEnabled ? "1" : "0")
    }

    // MARK: - Settings

    private func loadSettings() {
    }



    /// Rebuilds display state from the database alone — no network, no Keychain.
    /// Used at launch for an instant first paint, and by the screenshot renderer,
    /// which runs unsigned and must never trigger a credential prompt.
    public func hydrateFromStore() {
        guard let last = (try? store.recentSamples(limit: 1))?.first,
              let raw = try? store.rawJSON(at: last.observedAt),
              let snap = try? UsageDecoder.decode(data: Data(raw.utf8),
                                                  observedAt: last.observedAt)
        else { return }

        snapshot = snap
        lastSuccess = last.observedAt
        if tier == nil, let rawTier = try? store.planTier(at: last.observedAt) {
            tier = PlanTier.from(rawTier: rawTier)
        }
        if let weeklyResetsAt = snap.weekly?.resetsAt {
            let cycleStart = weeklyResetsAt.addingTimeInterval(-7 * 86400)
            modelUsage = (try? store.modelUsage(since: cycleStart)) ?? []
        }
        recompute(now: Date())
    }

    // MARK: - Historical backfill

    public var hasBackfilled: Bool {
        ((try? store.setting("backfill_done")) ?? nil) == "1"
    }

    /// Re-reads every transcript from byte zero to populate per-model history for
    /// the dashboard. Normal scans deliberately skip files untouched since the
    /// current cycle began, so without this the charts only ever show one week.
    ///
    /// Clears derived rows first: re-reading files that an incremental scan already
    /// consumed would otherwise double-count them.
    public func backfillHistory() async {
        guard backfillProgress == nil else { return }
        backfillProgress = 0

        try? store.clearModelUsage()
        try? store.clearScanOffsets()

        let root = TranscriptScanner.defaultRoot()
        // The reporting closure is @Sendable and hops back to the main actor itself,
        // so the detached scan never touches actor-isolated state directly.
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.backfillProgress = fraction }
        }
        let result = await Task.detached(priority: .utility) {
            TranscriptScanner.scan(root: root, priorOffsets: [:], since: nil) { done, total in
                guard total > 0 else { return }
                report(Double(done) / Double(total))
            }
        }.value

        try? store.record(events: result.events)
        try? store.setScanOffsets(result.offsets)
        try? store.setSetting("backfill_done", "1")

        backfillProgress = nil
        loadActivity()
        if let weeklyResetsAt = snapshot?.weekly?.resetsAt {
            let cycleStart = weeklyResetsAt.addingTimeInterval(-7 * 86400)
            modelUsage = (try? store.modelUsage(since: cycleStart)) ?? []
        }
        recompute(now: Date())
    }

    /// Sends a notification immediately so delivery can be verified without
    /// waiting for a real threshold. Reports the authorisation state, because a
    /// silently denied permission is indistinguishable from "no alert was due".
    public func sendTestNotification() async -> String {
        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()

        switch settings.authorizationStatus {
        case .denied:
            return "Notifications are denied for Claudroom in System Settings."
        case .notDetermined:
            await Notifications.requestAuthorization()
            let retry = await centre.notificationSettings().authorizationStatus
            guard retry == .authorized || retry == .provisional else {
                return "Permission was not granted."
            }
        default:
            break
        }

        await Notifications.post(
            title: "Claudroom alerts are working",
            body: "This is what a session or waste alert will look like.")
        return "Sent — check Notification Centre."
    }

    /// Models ordered by total output, biggest first. Single source of truth for
    /// both the chart's colour domain and the totals list — deriving them apart
    /// once gave the same model two different colours on one screen.
    ///
    /// Grouped by display name, not by raw id: a dated snapshot and its alias
    /// (`claude-haiku-4-5-20251001`, `claude-haiku-4-5`) are separate rows in the
    /// store but one model on screen, and leaving them apart puts two identical
    /// labels in a `ForEach` keyed on that label.
    public var modelTotals: [(name: String, tokens: Int, messages: Int, cost: Double?)] {
        Dictionary(grouping: lifetimeModelUsage, by: \.displayName)
            .map { name, rows in
                let costs = rows.map(\.apiCost)
                return (name: name,
                        tokens: rows.reduce(0) { $0 + $1.outputTokens },
                        messages: rows.reduce(0) { $0 + $1.messages },
                        // One unpriced variant suppresses the whole figure rather
                        // than quietly reporting a partial total as a full one.
                        cost: costs.contains(where: { $0 == nil })
                            ? nil : costs.compactMap { $0 }.reduce(0, +))
            }
            // By cost, to match what the panel prints and draws. Sorting by output
            // while displaying cost put a $632 row above a $1.5k row with a
            // shorter bar, which reads as a broken chart.
            .sorted {
                ($0.cost ?? -1, $0.tokens) > ($1.cost ?? -1, $1.tokens)
            }
    }

    /// The project currently opened up in the dashboard, if any.
    public private(set) var selectedProject: ProjectDetail?

    /// The window every dashboard panel reports on. Defaults to the whole history
    /// so a first open shows everything there is rather than an arbitrary slice.
    public private(set) var range: DashboardRange = .all

    /// Toggles the drill-down. Reads the store once here rather than from the
    /// view body, which SwiftUI re-evaluates far more often than the selection
    /// actually changes.
    public func selectProject(_ project: String?, now: Date = Date()) {
        guard let project, project != selectedProject?.project,
              let window = currentWindow(now: now) else {
            selectedProject = nil
            return
        }
        selectedProject = (try? store.projectDetail(project: project,
                                                    since: window.from,
                                                    until: window.to)) ?? nil
    }

    /// The selected range resolved against the data on hand. Nil when nothing has
    /// been recorded at all.
    private func currentWindow(now: Date) -> (from: Date, to: Date)? {
        guard let bounds = (try? store.activityRange()) ?? nil else { return nil }
        let cycleStart = snapshot?.weekly?.resetsAt.map { $0.addingTimeInterval(-7 * 86400) }
        return range.window(now: now, cycleStart: cycleStart,
                            earliest: bounds.first, latest: bounds.last)
    }

    /// What the whole tracked history would have cost on the metered API. Not a
    /// bill — the subscription is flat and none of this is owed. It is the
    /// pay-as-you-go price of the same work.
    public var totalAPICost: Double { projectUsage.reduce(0) { $0 + $1.apiCost } }

    /// Tokens excluded from `totalAPICost` because their model has no published
    /// price on file.
    public var unpricedTokens: Int { projectUsage.reduce(0) { $0 + $1.unpricedTokens } }

    public var orderedModelNames: [String] { modelTotals.map(\.name) }

    /// Normalised daily intensities for the ambient backdrop, oldest first. The
    /// glass has the user's own activity behind it rather than a decorative blur.
    public var fieldIntensities: [Double] {
        let byDay = Dictionary(grouping: dailyActivity, by: \.day)
            .map { (day: $0.key, tokens: $0.value.reduce(0) { $0 + $1.outputTokens }) }
            .sorted { $0.day < $1.day }
            .suffix(14)
        guard let peak = byDay.map(\.tokens).max(), peak > 0 else {
            return [Double](repeating: 0.12, count: 6)
        }
        return byDay.map { Double($0.tokens) / Double(peak) }
    }

    /// Switches the window every panel reports on, and reloads.
    public func setRange(_ newRange: DashboardRange, now: Date = Date()) {
        range = newRange
        loadActivity(now: now)
    }

    public func loadActivity(now: Date = Date()) {
        guard let bounds = (try? store.activityRange()) ?? nil else {
            dailyActivity = []
            lifetimeModelUsage = []
            projectUsage = []
            selectedProject = nil
            activityFirstDay = nil
            activityLastDay = nil
            activeDays = 0
            idleDays = 0
            hourProfile = []
            peakHours = nil
            return
        }

        _ = bounds
        guard let window = currentWindow(now: now) else { return }
        activityFirstDay = window.from
        activityLastDay = window.to

        dailyActivity = (try? store.dailyActivity(from: window.from, to: window.to)) ?? []

        let hourly = (try? store.hourlyOutput(from: window.from, to: window.to)) ?? [:]
        hourProfile = UsageInsights.hourOfDayProfile(hourly)
        peakHours = UsageInsights.peakWindow(hourProfile)

        let days = Set(dailyActivity.map { Calendar.current.startOfDay(for: $0.day) })
        activeDays = days.count
        idleDays = UsageInsights.idleDays(activeDays: days, from: window.from, to: window.to)
        cacheHealth = UsageInsights.cacheHealth(modelUsage)
        projectUsage = (try? store.projectUsage(since: window.from, until: window.to)) ?? []
        lifetimeModelUsage = (try? store.modelUsage(since: window.from, until: window.to)) ?? []

        // The open breakdown belongs to the previous window. Re-read it so its
        // numbers match the rows above it, and drop it if the project has no
        // activity in the new window at all.
        if let open = selectedProject?.project {
            selectedProject = (try? store.projectDetail(project: open,
                                                        since: window.from,
                                                        until: window.to)) ?? nil
        }
    }

    /// Hourly buckets across the open cycle, zero-filled so idle stretches show.
    public func cycleActivity(now: Date = Date()) -> [ActivityBucket] {
        guard let resetsAt = snapshot?.weekly?.resetsAt else { return [] }
        let start = resetsAt.addingTimeInterval(-7 * 86400)
        let usage = (try? store.hourlyOutput(from: start, to: resetsAt)) ?? [:]
        return ActivityTimeline.buckets(from: start, to: resetsAt, now: now, usage: usage)
    }

    // MARK: - Polling

    public func start() {
        guard pollTask == nil else { return }
        Task { await Notifications.requestAuthorization() }

        pollTask = Task { [weak self] in
            var backoff: TimeInterval = 0
            while !Task.isCancelled {
                guard let self else { return }
                let ok = await self.pollOnce()
                backoff = ok ? 0 : (backoff == 0 ? Self.coldStartInterval
                                                 : min(backoff * 2, Self.maxBackoff))
                try? await Task.sleep(for: .seconds(backoff == 0 ? self.baseInterval : backoff))
            }
        }
    }

    /// Cadence for the *next* successful-path poll.
    ///
    /// Before the first success the app retries quickly: a cold start that trips the
    /// Keychain prompt would otherwise sit dead for a full idle interval while the
    /// user stares at an empty menu bar.
    private var baseInterval: TimeInterval {
        if lastSuccess == nil { return Self.coldStartInterval }
        return sessionIsActive ? Self.activeInterval : Self.idleInterval
    }

    private var sessionIsActive: Bool {
        guard let five = snapshot?.fiveHour else { return false }
        return five.isActive(at: Date())
    }

    @discardableResult
    public func pollOnce() async -> Bool {
        let now = Date()

        let creds: Credentials
        do {
            creds = try credentials(now: now)
            hasCredentials = true
        } catch KeychainError.authorizationRequired {
            // The credential is there; we just declined to interrupt for it.
            // Distinct from being signed out, and it must not read as an error —
            // otherwise the popover tells people to run `claude` when the real
            // answer is one click.
            hasCredentials = true
            lastError = nil
            recompute(now: now)
            return false
        } catch {
            hasCredentials = false
            needsAuthorization = false
            lastError = "Not signed in to Claude Code"
            recompute(now: now)
            return false
        }

        if tier == nil, let raw = creds.rawTier {
            tier = PlanTier.from(rawTier: raw)
        }

        do {
            let snap = try await client.fetchUsage(token: creds.accessToken, now: now)
            snapshot = snap
            lastSuccess = now
            lastError = nil

            let tierString = creds.rawTier ?? ""
            try? store.insert(sample: snap, planTier: tierString)
            try? store.pruneSamples(olderThan: now.addingTimeInterval(-7 * 86400))

            let open = (try? store.openCycle()) ?? nil
            let recon = CycleTracker.reconcile(open: open, snapshot: snap,
                                               planTier: tierString,
                                               pollInterval: Self.activeInterval)
            if let closing = recon.toClose { try? store.upsert(cycle: closing) }
            if recon.open.resetsAt != .distantPast { try? store.upsert(cycle: recon.open) }

            recompute(now: now)
            await fireAlertsIfNeeded(now: now)
            if let weeklyResetsAt = snap.weekly?.resetsAt {
                await refreshModelUsage(cycleStart: weeklyResetsAt.addingTimeInterval(-7 * 86400))
            }
            return true
        } catch {
            if case UsageClientError.unauthorized = error {
                invalidateCachedCredentials()
            }
            lastError = describe(error)
            recompute(now: now)
            return false
        }
    }

    /// Reads the Keychain only when the cached token is missing or close to expiry.
    ///
    /// This matters far more than it looks. Claude Code rewrites its credential item
    /// whenever it refreshes the OAuth token, and rewriting a Keychain item resets
    /// that item's ACL — which drops Claudroom from the trusted list, so macOS asks
    /// for authorisation again. Reading once per poll meant a prompt could appear
    /// within 60 seconds of every refresh. Caching reduces that to roughly one
    /// prompt per token lifetime.
    private static let credentialRefreshMargin: TimeInterval = 5 * 60
    /// Fallback lifetime when the token carries no expiry.
    private static let credentialBlindCacheLifetime: TimeInterval = 30 * 60
    private var credentialsReadAt: Date?

    /// `allowInteraction` must be false for anything a timer started. Claude Code
    /// drops Claudroom from its item's ACL every time it refreshes, so this read
    /// needs authorising every few hours — and a background poll asking for it is
    /// what puts a password dialog over whatever the user was actually doing.
    private func credentials(now: Date, allowInteraction: Bool = false) throws -> Credentials {
        if let cached = cachedCredentials, isUsable(cached, now: now) { return cached }

        // Our own Keychain item, which survives app restarts and never prompts
        // because Claudroom created it.
        if let stored = CredentialCache.load(), isUsable(stored, now: now) {
            cachedCredentials = stored
            credentialsReadAt = now
            needsAuthorization = false
            return stored
        }

        // Only now do we touch Claude Code's item — the one whose ACL keeps being
        // reset, and therefore the one that can raise an authorisation prompt.
        do {
            let fresh = try Keychain.readClaudeCodeCredentials(allowInteraction: allowInteraction)
            cachedCredentials = fresh
            credentialsReadAt = now
            needsAuthorization = false
            CredentialCache.save(fresh)
            return fresh
        } catch KeychainError.authorizationRequired {
            // Not an error state to retry into — it is a decision waiting for the
            // user. Surfaced in the popover with a button, and polling backs off
            // rather than hammering a dialog that will not appear.
            needsAuthorization = true
            throw KeychainError.authorizationRequired
        }
    }

    /// Reads Claude Code's item *with* the authorisation dialog allowed. Only ever
    /// called from an explicit user action, so the prompt appears when the user is
    /// looking at Claudroom rather than mid-sentence in another app.
    public func authorizeNow() async {
        needsAuthorization = false
        do {
            let fresh = try Keychain.readClaudeCodeCredentials(allowInteraction: true)
            cachedCredentials = fresh
            credentialsReadAt = Date()
            CredentialCache.save(fresh)
            hasCredentials = true
            lastError = nil
            await pollOnce()
        } catch KeychainError.authorizationRequired {
            // Cancelled or denied. Leave the banner up; do not retry unasked.
            needsAuthorization = true
        } catch {
            hasCredentials = false
        }
    }

    private func isUsable(_ credentials: Credentials, now: Date) -> Bool {
        if let expiry = credentials.expiresAt {
            return expiry > now.addingTimeInterval(Self.credentialRefreshMargin)
        }
        guard let readAt = credentialsReadAt else { return false }
        return now.timeIntervalSince(readAt) < Self.credentialBlindCacheLifetime
    }

    /// Forces the next poll to re-read. Called when the server rejects the token,
    /// which is the only reliable signal that the cached copy is stale.
    private func invalidateCachedCredentials() {
        cachedCredentials = nil
        credentialsReadAt = nil
        CredentialCache.clear()
    }

    /// Removes Claudroom's copy of the token. Claude Code's own credential is
    /// untouched, so this only means the next poll asks for authorisation again.
    public func forgetStoredCredential() {
        invalidateCachedCredentials()
    }

    private func describe(_ error: any Error) -> String {
        guard let e = error as? UsageClientError else { return "Usage data unavailable" }
        switch e {
        case .unauthorized: return "Token expired — open Claude Code to refresh"
        case .rateLimited:  return "Rate limited — backing off"
        case .server(let c): return "Server error \(c)"
        case .transport:    return "Offline"
        }
    }


    private var isStale: Bool {
        guard let lastSuccess else { return true }
        return Date().timeIntervalSince(lastSuccess) > Self.stalenessWindow
    }

    // MARK: - Derived state

    private func recompute(now: Date) {
        let closed = (try? store.closedCycles(limit: Analytics.peakWindow)) ?? []
        verdict = Analytics.rightSizing(closedCycles: closed, currentTier: tier)

        if let resetsAt = snapshot?.weekly?.resetsAt, let weekly = snapshot?.weekly {
            pace = UsageInsights.cyclePace(
                cycleStart: resetsAt.addingTimeInterval(-7 * 86400),
                cycleEnd: resetsAt,
                now: now,
                utilization: weekly.fraction)
        } else {
            pace = nil
        }

        advice = computeAdvice(now: now)

        label = MenuBarLabelSelector.select(LabelInput(
            snapshot: snapshot, now: now, isStale: isStale,
            hasCredentials: hasCredentials,
            underusedThresholdPct: AlertThresholds.default.closing24hPct))
    }

    /// Burn rate is measured only across samples belonging to the *current* 5-hour
    /// window: a reset partway through the lookback would otherwise read as a large
    /// negative burn.
    private func computeAdvice(now: Date) -> SessionAdvice? {
        guard let snapshot else { return nil }

        var burn: BurnRate?
        if let fiveResetsAt = snapshot.fiveHour?.resetsAt {
            let recent = (try? store.recentSamples(limit: 120)) ?? []
            let sameWindow = recent
                .filter { $0.fiveHourResetsAt == fiveResetsAt }
                .compactMap { sample -> (at: Date, fraction: Double)? in
                    guard let f = sample.fiveHourFrac else { return nil }
                    return (sample.observedAt, f)
                }
            burn = BurnEstimator.estimate(samples: sameWindow, now: now)
        }

        // Whichever model produced most output since this window opened.
        var dominant: String?
        if let fiveResetsAt = snapshot.fiveHour?.resetsAt {
            let windowStart = fiveResetsAt.addingTimeInterval(-5 * 3600)
            let rows = (try? store.modelUsage(since: windowStart)) ?? []
            dominant = rows.max { $0.outputTokens < $1.outputTokens }?.displayName
        }

        return SessionAdvisor.advise(fiveHour: snapshot.fiveHour,
                                     weekly: snapshot.weekly,
                                     burn: burn,
                                     now: now,
                                     dominantModel: dominant)
    }

    /// Scans Claude Code transcripts for per-model token usage in the current cycle.
    ///
    /// The corpus is ~1 GB, so the scan runs off the main actor and is bounded twice
    /// over: files untouched since the cycle started are never opened, and large
    /// active files are entered via binary search rather than read from byte zero.
    /// Steady-state rescans touch no file contents at all.
    private func refreshModelUsage(cycleStart: Date) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let priorOffsets = (try? store.scanOffsets()) ?? [:]
        let root = TranscriptScanner.defaultRoot()

        let result = await Task.detached(priority: .utility) {
            TranscriptScanner.scan(root: root, priorOffsets: priorOffsets, since: cycleStart)
        }.value

        try? store.record(events: result.events)
        try? store.setScanOffsets(result.offsets)
        modelUsage = (try? store.modelUsage(since: cycleStart)) ?? []
    }

    private func fireAlertsIfNeeded(now: Date) async {
        guard let weekly = snapshot?.weekly, let weeklyResetsAt = weekly.resetsAt else { return }

        var fired: Set<AlertRule> = []
        for rule in AlertRule.allCases {
            if (try? store.hasFired(rule: rule.rawValue,
                                    cycleResetsAt: weeklyResetsAt)) == true {
                fired.insert(rule)
            }
        }


        let pending = AlertEngine.evaluate(
            weeklyFraction: weekly.fraction, resetsAt: weeklyResetsAt, now: now,
            thresholds: .default, alreadyFired: fired)

        for alert in pending {
            await Notifications.post(title: alert.title, body: alert.body)
            try? store.markFired(rule: alert.rule.rawValue,
                                 cycleResetsAt: weeklyResetsAt, at: now)
        }

        await fireSessionAlertsIfNeeded(now: now)
    }

    /// Session alerts dedupe on the 5-hour window's own reset timestamp, so each
    /// window can warn once and a new window starts clean.
    private func fireSessionAlertsIfNeeded(now: Date) async {
        guard let five = snapshot?.fiveHour, let windowKey = five.resetsAt else { return }

        var fired: Set<AlertRule> = []
        for rule in [AlertRule.session80, .session90, .sessionCapped] {
            if (try? store.hasFired(rule: rule.rawValue, cycleResetsAt: windowKey)) == true {
                fired.insert(rule)
            }
        }

        let pending = AlertEngine.evaluateSession(
            fiveHour: five,
            weeklyFraction: snapshot?.weekly?.fraction,
            now: now,
            dominantModel: advice?.dominantModel,
            thresholds: .default,
            alreadyFired: fired)

        for alert in pending {
            await Notifications.post(title: alert.title, body: alert.body)
            // The superseded rules are recorded but never posted, so a jump past
            // both thresholds sends one notification and the lower one cannot
            // arrive later out of order.
            for rule in [alert.rule] + alert.supersedes {
                try? store.markFired(rule: rule.rawValue,
                                     cycleResetsAt: windowKey, at: now)
            }
        }
    }
}

enum Notifications {
    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    static func post(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}
