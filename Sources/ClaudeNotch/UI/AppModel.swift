import Foundation
import SwiftUI

@MainActor @Observable
final class AppModel {
    private(set) var snapshot: UsageSnapshot = .empty
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

    private let store = UsageStore()
    private let loader = LogLoader()
    private let claudeAPI = ClaudeAPIService()
    private let lifetimeScanner = LifetimeScanner()
    private var watcher: LogWatcher?
    private var ticker: Timer?
    private var limitsTimer: Timer?
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

    var sessionUsage: Double? {
        limits?.sessionPct ?? statuslineUsage ?? (snapshot.isEmpty ? nil : snapshot.blockUsageEstimate)
    }
    var weeklyUsage: Double? { limits?.weeklyPct }
    var fableUsage: Double? { limits?.fablePct }          // Fable's own weekly limit (if provided)
    var fableResetsAt: Date? { limits?.fableResetsAt }
    var sessionResetsAt: Date? { limits?.sessionResetsAt }
    var weeklyResetsAt: Date? { limits?.weeklyResetsAt ?? weeklyResetFromConfig }
    var lastFetch: Date? { limits?.fetchedAt }
    var usageSource: String {
        if let l = limits { return l.source ?? "claude.ai" }
        if statuslineUsage != nil { return "terminal" }
        return "estimate"
    }
    /// True when live limits exist but haven't refreshed recently (fetches failing) — the UI
    /// dims the numbers so a frozen value is never shown as if it were current.
    var isStale: Bool {
        guard let f = limits?.fetchedAt else { return false }
        return Date().timeIntervalSince(f) > staleAfter
    }
    private let staleAfter: TimeInterval = 150   // ~2–3 missed 60s fetches

    /// Estimated time until the 5-hour limit at the current pace (nil if usage isn't trending
    /// up, or if the block resets first). Uses the slope of session % — no token cap needed.
    var etaToLimit: TimeInterval? {
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
    var iconUrgency: Double { max(sessionUsage ?? 0, limits?.weeklyPct ?? 0) }

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
    var creditsValue: String {
        if let minor = limits?.creditsBalanceMinor, let currency = limits?.creditsCurrency {
            return Fmt.money(minor: minor, currency: currency)
        }
        return limits?.creditsPct.map { Fmt.pct($0) + " used" } ?? "none"
    }
    /// When the balance is the headline, the monthly spend percent moves to the subline.
    var creditsSubtitle: String? {
        guard limits?.creditsBalanceMinor != nil else { return nil }
        return limits?.creditsPct.map { Fmt.pct($0) + " used" }
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
        Task { await ingest(ClaudePaths.recentLogFiles(within: 2)) }
        fetchLimits()
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

    func togglePause() { isPaused.toggle(); if !isPaused { refresh() } }
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
        Task { [claudeAPI] in
            if let l = await claudeAPI.fetch(), l.sessionPct != nil { self.applyLimits(l) }
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
