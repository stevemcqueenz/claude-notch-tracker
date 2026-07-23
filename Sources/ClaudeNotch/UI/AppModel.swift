import Foundation
import SwiftUI

@MainActor @Observable
final class AppModel {
    private(set) var snapshot: UsageSnapshot = .empty
    private(set) var codexSnapshot: ProviderUsageSnapshot = .unavailable(.codex)
    private(set) var selectedProvider = UsageProviderID(
        rawValue: UserDefaults.standard.string(forKey: "selectedProvider") ?? ""
    ) ?? .claude
    /// Projects worked in today with their spend (from the logs), most-recently-active first.
    var sessionsToday: [ProjectUsage] { snapshot.projectsToday }
    var isExpanded = false
    var isPaused = false
    var claudeRunning = false
    var avatarStyle: AvatarStyle = AvatarStyle.selected
    /// Whether the icon (Clawd / Spark) animates. Persisted; default on.
    var animateIcon: Bool = (UserDefaults.standard.object(forKey: "animateIcon") as? Bool) ?? true
    /// Hide the island while a fullscreen app is frontmost (menu bar hidden). Persisted; default off.
    var hideInFullscreen: Bool = UserDefaults.standard.bool(forKey: "hideInFullscreen")
    /// Notch geometry of the screen the island lives on (updated on display changes).
    var notchWidth: CGFloat = 190
    var topInset: CGFloat = 32

    /// Live account limits from claude.ai (authoritative, matches Claude Desktop).
    private(set) var limits: ClaudeLimits?
    /// Context window remaining, 0…1, from the terminal statusline feed (nil if unknown).
    private(set) var contextRemaining: Double?
    /// Friendly plan name, e.g. "Claude Max 5x" (from ~/.claude.json).
    private(set) var planName: String?
    private var statuslineUsage: Double?
    private var weeklyResetFromConfig: Date?
    /// Recent (time, session %) samples for the burn-rate ETA.
    private var pctHistory: [(t: Date, pct: Double)] = []

    /// Lifetime tokens + cost across every log (scanned off-main, refreshed periodically).
    private(set) var lifetime: LifetimeScanner.Totals = .init()
    /// Local per-day activity for the week chart (scanner data, today overridden live).
    /// Recomputed on each refresh() tick rather than per render.
    private(set) var claudeDailySeries: [DailyUsagePoint] = []

    private let store = UsageStore()
    private let loader = LogLoader()
    private let claudeAPI = ClaudeAPIService()
    private let codexProvider = CodexUsageProvider()
    private let lifetimeScanner = LifetimeScanner()
    private var watcher: LogWatcher?
    private var ticker: Timer?
    private var limitsTimer: Timer?
    private var codexTimer: Timer?
    private var lifetimeTimer: Timer?
    /// mtime of each log file the last time we parsed it, so the periodic sweep re-reads only
    /// files that actually grew and skips the rest.
    private var parsedMTimes: [URL: Date] = [:]
    /// Byte offset consumed so far per file, so we tail-parse only newly-appended bytes.
    private var parsedOffsets: [URL: UInt64] = [:]
    /// Conversation titles (sessionId → sidebar name), accumulated as logs are parsed.
    private var titlesBySession: [String: String] = [:]
    private var lastReingest = Date.distantPast

    // MARK: display values (prefer live limits, then terminal feed, then estimate)

    private var claudeSessionUsage: Double? {
        limits?.sessionPct ?? statuslineUsage ?? (snapshot.isEmpty ? nil : snapshot.blockUsageEstimate)
    }
    var sessionUsage: Double? { activeProviderSnapshot.primaryUsage }
    var weeklyUsage: Double? { limits?.weeklyPct }
    var fableUsage: Double? { limits?.fablePct }          // Fable's own weekly limit (if provided)
    var fableResetsAt: Date? { limits?.fableResetsAt }
    var sessionResetsAt: Date? { limits?.sessionResetsAt }
    var weeklyResetsAt: Date? { limits?.weeklyResetsAt ?? weeklyResetFromConfig }
    var lastFetch: Date? { limits?.fetchedAt }
    private var claudeUsageSource: String {
        if let l = limits { return l.source ?? "claude.ai" }
        if statuslineUsage != nil { return "terminal" }
        return "estimate"
    }
    /// True when live limits exist but haven't refreshed recently (fetches failing) — the UI
    /// dims the numbers so a frozen value is never shown as if it were current.
    var isStale: Bool {
        activeProviderSnapshot.isStale(after: staleAfter)
    }
    private let staleAfter: TimeInterval = 150   // ~2–3 missed 60s fetches

    /// Estimated time until the 5-hour limit at the current pace (nil if usage isn't trending
    /// up, or if the block resets first). Uses the slope of session % — no token cap needed.
    var etaToLimit: TimeInterval? {
        guard selectedProvider == .claude else { return nil }
        guard let cur = limits?.sessionPct, cur < 0.999, pctHistory.count >= 2 else { return nil }
        let recent = Array(pctHistory.suffix(8))
        guard let first = recent.first, let last = recent.last else { return nil }
        let dt = last.t.timeIntervalSince(first.t)
        let dpct = last.pct - first.pct
        guard dt > 60, dpct > 0.005 else { return nil }
        let eta = (1.0 - cur) / (dpct / dt)
        if let reset = limits?.sessionResetsAt, eta >= reset.timeIntervalSinceNow { return nil }
        return (eta > 0 && eta < 6 * 3600) ? eta : nil
    }

    /// How urgent the icon should look (0…1) — drives Clawd's walk speed.
    ///
    /// Claude deliberately uses only the 5-hour and 7-day limits, as before multi-provider: the
    /// Fable weekly limit is a per-model cap, and a maxed Fable would otherwise freeze Clawd at
    /// "out of budget" while the account still has plenty of session/weekly headroom.
    var iconUrgency: Double {
        switch selectedProvider {
        case .claude: max(claudeSessionUsage ?? 0, weeklyUsage ?? 0)
        case .codex: codexSnapshot.maximumUsage
        }
    }

    /// A limit (5-hour or 7-day) is used up — there's nothing left to spend, so Clawd stops
    /// walking and stands still rather than sprinting at max speed.
    var isAtLimit: Bool { iconUrgency >= 0.999 }

    /// Projected end-of-day cost if today keeps up its average spend rate so far. nil before any
    /// spend, or too early in the day for the extrapolation to mean anything.
    var projectedCostToday: Double? {
        let cost = snapshot.costToday
        guard cost > 0 else { return nil }
        let dayFraction = Date().timeIntervalSince(Calendar.current.startOfDay(for: Date())) / 86_400
        guard dayFraction > 0.1 else { return nil }   // before ~2:24am it's just noise
        return cost / dayFraction
    }

    /// Credits tile: the purchased usage-credit balance when known (what claude.ai settings calls
    /// "Current balance"), else the extra-usage spend percent, else "none".
    private var creditsValue: String {
        if let minor = limits?.creditsBalanceMinor, let currency = limits?.creditsCurrency {
            return Fmt.money(minor: minor, currency: currency)
        }
        return limits?.creditsPct.map { Fmt.pct($0) + " used" } ?? "none"
    }
    /// When the balance is the headline, the monthly spend percent moves to the subline.
    private var creditsSubtitle: String? {
        guard limits?.creditsBalanceMinor != nil else { return nil }
        return limits?.creditsPct.map { Fmt.pct($0) + " used" }
    }

    var activeProviderSnapshot: ProviderUsageSnapshot {
        switch selectedProvider {
        case .claude: claudeProviderSnapshot
        case .codex: codexSnapshot
        }
    }

    private var claudeProviderSnapshot: ProviderUsageSnapshot {
        var usageLimits = [
            UsageLimitMetric(id: "claude-session", label: "5-Hour",
                             usedFraction: claudeSessionUsage, resetsAt: sessionResetsAt),
            UsageLimitMetric(id: "claude-weekly", label: "7-Day",
                             usedFraction: weeklyUsage, resetsAt: weeklyResetsAt),
        ]
        if fableUsage != nil {
            usageLimits.append(UsageLimitMetric(id: "claude-fable", label: "Fable",
                                                usedFraction: fableUsage, resetsAt: fableResetsAt))
        }

        var stats = [
            UsageStatMetric(id: "cost-today", label: "cost today · local",
                            value: snapshot.isEmpty ? "—" : Fmt.usd(snapshot.costToday),
                            subtitle: projectedCostToday.map { "~\(Fmt.usd($0)) by tonight" }),
            UsageStatMetric(id: "credits", label: "credits",
                            value: creditsValue, subtitle: creditsSubtitle),
            // All-time lives here now; the detail page belongs to the week chart + sessions,
            // and "tokens today" is redundant with the chart's highlighted today bar.
            UsageStatMetric(id: "all-time", label: "all-time · local",
                            value: lifetime.tokens == 0 ? "—" : Fmt.usd(lifetime.cost),
                            subtitle: lifetime.tokens == 0 ? nil : Fmt.tokens(lifetime.tokens)),
        ]
        if fableUsage == nil {
            stats.insert(
                UsageStatMetric(id: "fable-tokens", label: "Fable",
                                value: lifetime.fableTokens == 0 ? "—" : Fmt.tokens(lifetime.fableTokens),
                                subtitle: "all-time"),
                at: 0
            )
        }

        var currentSessions = sessionsToday.map {
            UsageSessionMetric(id: $0.id, name: $0.name, cost: $0.cost,
                               tokens: $0.tokens, last: $0.last)
        }
        if currentSessions.isEmpty, !snapshot.isEmpty {
            currentSessions.append(UsageSessionMetric(
                id: "claude-active-session",
                name: "this session",
                cost: snapshot.activeSessionCost,
                tokens: snapshot.activeSessionTokens,
                last: Date()
            ))
        }

        return ProviderUsageSnapshot(
            provider: .claude,
            limits: usageLimits,
            stats: stats,
            todayCost: snapshot.isEmpty ? nil : snapshot.costToday,
            todayTokens: snapshot.isEmpty ? nil : snapshot.tokensToday,
            lifetimeCost: lifetime.tokens == 0 ? nil : lifetime.cost,
            lifetimeTokens: lifetime.tokens == 0 ? nil : lifetime.tokens,
            dailySeries: claudeDailySeries,
            chartTitle: "last 7 days · local",
            chartOnDetailPage: true,
            sessionsTitle: "active sessions",
            sessions: currentSessions,
            alternateSessionsTitle: "all-time · top projects",
            alternateSessions: lifetime.projects.map {
                UsageSessionMetric(id: $0.id, name: $0.name, cost: $0.cost,
                                   tokens: $0.tokens, last: $0.last)
            },
            planName: planName,
            source: claudeUsageSource,
            fetchedAt: limits?.fetchedAt
        )
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var usageFileURL: URL { home.appendingPathComponent(".claude/notch-usage.json") }
    private var configURL: URL { home.appendingPathComponent(".claude.json") }

    func start() {
        readPlanLimits()
        watcher = LogWatcher { [weak self] urls in
            guard let self, !self.isPaused else { return }
            Task { await self.ingest(urls) }
        }
        watcher?.start()
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        limitsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchLimits() }
        }
        codexTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchCodexUsage() }
        }
        Task { await ingest(ClaudePaths.recentLogFiles(within: 2)) }
        fetchLimits()
        fetchCodexUsage()
        scanLifetime()
        lifetimeTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanLifetime() }
        }
    }

    /// Total all-time tokens + cost, scanned off-main so the (potentially many-GB) sweep never
    /// blocks the UI.
    private func scanLifetime() {
        Task { [lifetimeScanner] in
            let totals = await lifetimeScanner.scan()
            self.lifetime = totals
        }
    }

    func togglePause() {
        isPaused.toggle()
        if !isPaused {
            refresh()
            fetchLimits()
            fetchCodexUsage()
        }
    }
    func selectProvider(_ provider: UsageProviderID) {
        selectedProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "selectedProvider")
        switch provider {
        case .claude: fetchLimits()
        case .codex: fetchCodexUsage()
        }
    }
    /// Advance to the next provider (icon click) — with two providers this is a toggle.
    func cycleProvider() {
        let providers = UsageProviderID.allCases
        guard let index = providers.firstIndex(of: selectedProvider) else { return }
        selectProvider(providers[(index + 1) % providers.count])
    }
    func cycleAvatar() { setAvatar(avatarStyle.next) }
    func setAvatar(_ s: AvatarStyle) { avatarStyle = s; AvatarStyle.selected = s }
    func toggleAnimateIcon() {
        animateIcon.toggle()
        UserDefaults.standard.set(animateIcon, forKey: "animateIcon")
    }
    func toggleHideInFullscreen() {
        hideInFullscreen.toggle()
        UserDefaults.standard.set(hideInFullscreen, forKey: "hideInFullscreen")
    }

    /// Fetch live claude.ai limits off-main (Keychain prompt appears on first run).
    /// Only replaces the last-known-good limits with a response that actually carries a
    /// session %, so a partial/failed read can never clobber correct data.
    func fetchLimits() {
        guard !isPaused, selectedProvider == .claude else { return }
        Task { [claudeAPI] in
            if let l = await claudeAPI.fetch(), l.sessionPct != nil { self.applyLimits(l) }
        }
    }

    func fetchCodexUsage() {
        guard !isPaused, selectedProvider == .codex else { return }
        Task { [codexProvider] in
            self.codexSnapshot = await codexProvider.fetch()
        }
    }

    /// Store new limits and track the % trend for the burn-rate ETA.
    private func applyLimits(_ l: ClaudeLimits) {
        // A new block (reset time jumped later) → clear the ETA trend.
        if let prev = limits?.sessionResetsAt, let now = l.sessionResetsAt,
           now > prev.addingTimeInterval(60) {
            pctHistory.removeAll()
        }
        limits = l
        if let p = l.sessionPct {
            pctHistory.append((Date(), p))
            if pctHistory.count > 20 { pctHistory.removeFirst(pctHistory.count - 20) }
        }
    }

    private func ingest(_ files: [URL]) async {
        let requests = files.map { (url: $0, offset: parsedOffsets[$0] ?? 0) }
        let results = await loader.parse(requests)
        for r in results {
            // A fresh/full read (first time, or after truncation) replaces; a tail read appends.
            if r.reset { store.ingest(fileURL: r.url, events: r.events) }
            else { store.append(fileURL: r.url, events: r.events) }
            parsedOffsets[r.url] = r.newOffset
            for (sid, title) in r.titles { titlesBySession[sid] = title }
        }
        for url in files { parsedMTimes[url] = Self.mtime(url) }
        refresh()
    }

    /// Fires every 5s: re-read any grown log files (freshness safety net that doesn't depend on
    /// the FSEvents watcher), then recompute the snapshot.
    private func tick() {
        reingestChangedFiles()
        refresh()
    }

    /// Re-parse recent log files whose mtime advanced since we last read them. This makes local
    /// token/cost stay fresh even if the FSEvents watcher misses an append (e.g. after a launch
    /// with no prior same-day activity). Throttled and mtime-gated so unchanged files are skipped.
    private func reingestChangedFiles() {
        guard !isPaused, Date().timeIntervalSince(lastReingest) >= 10 else { return }
        let changed = ClaudePaths.recentLogFiles(within: 2)
            .filter { Self.mtime($0) > (parsedMTimes[$0] ?? .distantPast) }
        guard !changed.isEmpty else { return }
        lastReingest = Date()
        Task { await ingest(changed) }
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    func refresh() {
        snapshot = store.snapshot(now: Date(), titles: titlesBySession)
        readStatusFeed()
        claudeDailySeries = buildClaudeDailySeries()
    }

    /// The scanner aggregates whole days every ten minutes; today's bar is overridden with the
    /// live figures so it never lags. Empty until either source has something to show.
    private func buildClaudeDailySeries() -> [DailyUsagePoint] {
        guard !lifetime.recentDays.isEmpty || !snapshot.isEmpty else { return [] }
        let calendar = Calendar.current
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let now = Date()
        return (0..<7).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
            let key = f.string(from: day)
            var tokens = lifetime.recentDays[key]?.tokens ?? 0
            var cost = lifetime.recentDays[key]?.cost ?? 0
            if back == 0 {
                tokens = max(tokens, snapshot.tokensToday)
                cost = max(cost, snapshot.costToday)
            }
            return DailyUsagePoint(date: day, tokens: tokens, cost: cost)
        }
    }

    /// Expanded drop-down height — fixed, since the expanded view is a fixed-size two-page pager.
    /// Read by both the view and the window's click-zone.
    var expandedDropHeight: CGFloat { 234 }

    /// Terminal statusline feed (fallback source for session % and context).
    private func readStatusFeed() {
        guard let data = try? Data(contentsOf: usageFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let rem = (obj["rate_remaining"] as? NSNumber)?.doubleValue {
            statuslineUsage = max(0, min(1, (100 - rem) / 100))
        }
        if let ctx = (obj["ctx_remaining"] as? NSNumber)?.doubleValue {
            contextRemaining = max(0, min(1, ctx / 100))
        }
    }

    /// Weekly reset fallback from ~/.claude.json (used only until the live fetch lands).
    private func readPlanLimits() {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let gb = root["cachedGrowthBookFeatures"] as? [String: Any],
           let lattice = gb["tengu_saffron_lattice"] as? [String: Any],
           let iso = lattice["planLimitsEndDate"] as? String {
            weeklyResetFromConfig = ISO8601DateFormatter().date(from: iso)
        }
        if let oauth = root["oauthAccount"] as? [String: Any],
           let tier = oauth["organizationRateLimitTier"] as? String {
            planName = Fmt.planLabel(tier)
        }
    }
}
