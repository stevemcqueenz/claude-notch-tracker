import Foundation
import SwiftUI

@MainActor @Observable
final class AppModel {
    private(set) var snapshot: UsageSnapshot = .empty
    var isExpanded = false
    var isPaused = false
    var claudeRunning = false
    var avatarStyle: AvatarStyle = AvatarStyle.selected

    /// 5-hour session usage, 0…1 consumed. Authoritative value comes from Claude Code's
    /// statusline feed (~/.claude/notch-usage.json); falls back to a token-based estimate.
    private(set) var sessionUsage: Double?
    /// Context window remaining, 0…1, from the statusline feed (nil if unknown).
    private(set) var contextRemaining: Double?
    /// When the weekly (7-day) plan limit resets, from ~/.claude.json (nil if unknown).
    private(set) var weeklyResetDate: Date?

    private let store = UsageStore()
    private let loader = LogLoader()
    private var watcher: LogWatcher?
    private var ticker: Timer?

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
        // Re-read every 5s so the live session % and the block clock stay current.
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        Task { await ingest(ClaudePaths.recentLogFiles(within: 2)) }
    }

    func togglePause() { isPaused.toggle(); if !isPaused { refresh() } }

    func cycleAvatar() { setAvatar(avatarStyle.next) }
    func setAvatar(_ s: AvatarStyle) { avatarStyle = s; AvatarStyle.selected = s }

    private func ingest(_ files: [URL]) async {
        let parsed = await loader.parse(files)
        for item in parsed { store.ingest(fileURL: item.url, events: item.events) }
        refresh()
    }

    func refresh() {
        snapshot = store.snapshot(now: Date())
        readStatusFeed()
    }

    /// Prefer the authoritative statusline rate-limit %; fall back to the token estimate.
    private func readStatusFeed() {
        var rateRemaining: Double?
        if let data = try? Data(contentsOf: usageFileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rateRemaining = (obj["rate_remaining"] as? NSNumber)?.doubleValue
            if let ctx = (obj["ctx_remaining"] as? NSNumber)?.doubleValue {
                contextRemaining = max(0, min(1, ctx / 100))
            }
        }
        if let rem = rateRemaining {
            sessionUsage = max(0, min(1, (100 - rem) / 100))
        } else {
            sessionUsage = snapshot.isEmpty ? nil : snapshot.blockUsageEstimate
        }
    }

    /// Read the weekly plan-limit reset date from ~/.claude.json (best-effort).
    private func readPlanLimits() {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gb = root["cachedGrowthBookFeatures"] as? [String: Any],
              let lattice = gb["tengu_saffron_lattice"] as? [String: Any],
              let iso = lattice["planLimitsEndDate"] as? String
        else { return }
        let fmt = ISO8601DateFormatter()
        weeklyResetDate = fmt.date(from: iso)
    }
}
