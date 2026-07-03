import Foundation
import SwiftUI

@MainActor @Observable
final class AppModel {
    private(set) var snapshot: UsageSnapshot = .empty
    var isExpanded = false
    var isPaused = false
    var claudeRunning = false

    private let store = UsageStore()
    private let loader = LogLoader()
    private var watcher: LogWatcher?
    private var ticker: Timer?

    func start() {
        watcher = LogWatcher { [weak self] urls in
            guard let self, !self.isPaused else { return }
            Task { await self.ingest(urls) }
        }
        watcher?.start()
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
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

    func refresh() { snapshot = store.snapshot(now: Date()) }
}
