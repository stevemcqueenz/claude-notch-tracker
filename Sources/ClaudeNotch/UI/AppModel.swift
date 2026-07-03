import Foundation
import SwiftUI

@MainActor @Observable
final class AppModel {
    private(set) var snapshot: UsageSnapshot = .empty
    var isExpanded = false
    var isPaused = false
    var claudeRunning = false

    /// 5-hour session usage, 0…1 consumed. Authoritative value comes from Claude Code's
    /// statusline feed (~/.claude/notch-usage.json); falls back to a token-based estimate.
    private(set) var sessionUsage: Double?
    /// Context window remaining, 0…1, from the statusline feed (nil if unknown).
    private(set) var contextRemaining: Double?

    private let store = UsageStore()
    private let loader = LogLoader()
    private var watcher: LogWatcher?
    private var ticker: Timer?

    private var usageFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/notch-usage.json")
    }

    func start() {
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
}
