import Foundation
import SwiftUI

@MainActor @Observable
final class AppModel {
    private(set) var snapshot: UsageSnapshot = .empty
    var isExpanded = false
    var isPaused = false
    var claudeRunning = false
    var avatarStyle: AvatarStyle = AvatarStyle.selected
    /// Whether the icon (Clawd / Spark) animates. Persisted; default on.
    var animateIcon: Bool = (UserDefaults.standard.object(forKey: "animateIcon") as? Bool) ?? true

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
    /// A newer release version if one exists (surfaced in the right-click menu).
    private(set) var updateAvailable: String?

    private let store = UsageStore()
    private let loader = LogLoader()
    private let claudeAPI = ClaudeAPIService()
    private var watcher: LogWatcher?
    private var ticker: Timer?
    private var limitsTimer: Timer?

    // MARK: display values (prefer live limits, then terminal feed, then estimate)

    var sessionUsage: Double? {
        limits?.sessionPct ?? statuslineUsage ?? (snapshot.isEmpty ? nil : snapshot.blockUsageEstimate)
    }
    var weeklyUsage: Double? { limits?.weeklyPct }
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
            Task { @MainActor in self?.refresh() }
        }
        limitsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchLimits() }
        }
        Task { await ingest(ClaudePaths.recentLogFiles(within: 2)) }
        fetchLimits()
        checkForUpdate()
    }

    func checkForUpdate() {
        Task { self.updateAvailable = await UpdateChecker.latestIfNewer(than: AppInfo.version) }
    }

    func togglePause() { isPaused.toggle(); if !isPaused { refresh() } }
    func cycleAvatar() { setAvatar(avatarStyle.next) }
    func setAvatar(_ s: AvatarStyle) { avatarStyle = s; AvatarStyle.selected = s }
    func toggleAnimateIcon() {
        animateIcon.toggle()
        UserDefaults.standard.set(animateIcon, forKey: "animateIcon")
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
        let parsed = await loader.parse(files)
        for item in parsed { store.ingest(fileURL: item.url, events: item.events) }
        refresh()
    }

    func refresh() {
        snapshot = store.snapshot(now: Date())
        readStatusFeed()
    }

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
