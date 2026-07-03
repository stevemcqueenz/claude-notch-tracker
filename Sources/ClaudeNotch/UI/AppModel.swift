import Foundation
import SwiftUI

@MainActor @Observable
final class AppModel {
    private(set) var snapshot: UsageSnapshot = .empty
    var isExpanded = false
    var isPaused = false
    var claudeRunning = false
    var avatarStyle: AvatarStyle = AvatarStyle.selected

    /// Live account limits from claude.ai (authoritative, matches Claude Desktop).
    private(set) var limits: ClaudeLimits?
    /// Context window remaining, 0…1, from the terminal statusline feed (nil if unknown).
    private(set) var contextRemaining: Double?
    private var statuslineUsage: Double?
    private var weeklyResetFromConfig: Date?

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
        if limits != nil { return "Claude Desktop" }
        if statuslineUsage != nil { return "terminal" }
        return "estimate"
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
            Task { @MainActor in self?.refresh() }
        }
        limitsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchLimits() }
        }
        Task { await ingest(ClaudePaths.recentLogFiles(within: 2)) }
        fetchLimits()
    }

    func togglePause() { isPaused.toggle(); if !isPaused { refresh() } }
    func cycleAvatar() { setAvatar(avatarStyle.next) }
    func setAvatar(_ s: AvatarStyle) { avatarStyle = s; AvatarStyle.selected = s }

    /// Fetch live claude.ai limits off-main (Keychain prompt appears on first run).
    func fetchLimits() {
        Task { [claudeAPI] in
            if let l = await claudeAPI.fetch() { self.limits = l }
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
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gb = root["cachedGrowthBookFeatures"] as? [String: Any],
              let lattice = gb["tengu_saffron_lattice"] as? [String: Any],
              let iso = lattice["planLimitsEndDate"] as? String
        else { return }
        weeklyResetFromConfig = ISO8601DateFormatter().date(from: iso)
    }
}
