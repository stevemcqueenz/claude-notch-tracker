import Foundation

/// Aggregates parsed events from every log file into a render-ready snapshot.
final class UsageStore {
    private var eventsByFile: [URL: [UsageEvent]] = [:]

    func ingest(fileURL: URL) throws {
        eventsByFile[fileURL] = try LogParser.parse(fileURL: fileURL)
    }

    /// Store already-parsed events for a file (used when parsing happened off-main), replacing
    /// whatever was there — for full/fresh reads.
    func ingest(fileURL: URL, events: [UsageEvent]) {
        eventsByFile[fileURL] = events
    }

    /// Append newly-tailed events to a file's existing set (for incremental reads).
    func append(fileURL: URL, events: [UsageEvent]) {
        guard !events.isEmpty else { return }
        eventsByFile[fileURL, default: []].append(contentsOf: events)
    }

    func remove(fileURL: URL) { eventsByFile[fileURL] = nil }

    private func allEvents() -> [UsageEvent] {
        var seen = Set<String>()
        var out: [UsageEvent] = []
        for e in eventsByFile.values.flatMap({ $0 })
            .sorted(by: { $0.timestamp < $1.timestamp }) {
            if seen.insert(e.dedupeKey).inserted { out.append(e) }
        }
        return out
    }

    func snapshot(now: Date, titles: [String: String] = [:]) -> UsageSnapshot {
        let events = allEvents()
        guard !events.isEmpty else { return .empty }

        let cal = Calendar.current
        let today = events.filter { cal.isDate($0.timestamp, inSameDayAs: now) }

        let tokensToday = today.reduce(0) { $0 + $1.totalTokens }
        let costToday = today.reduce(0) { $0 + PricingTable.cost(for: $1) }

        // The active-sessions list: per-conversation spend TODAY (same calendar-day scope as the
        // "today" tile, so a session never exceeds the day's total). Grouped by sessionId (so
        // subagents fold into their parent and a mid-session `cd` doesn't split a conversation),
        // named by the sidebar title, else the project folder.
        var bySession: [String: (cost: Double, tokens: Int, last: Date, cwd: String)] = [:]
        for e in today {
            var u = bySession[e.sessionId] ?? (0, 0, .distantPast, e.cwd)
            u.cost += PricingTable.cost(for: e)
            u.tokens += e.totalTokens
            if e.timestamp > u.last { u.last = e.timestamp; u.cwd = e.cwd }
            bySession[e.sessionId] = u
        }
        // From all events, not just today's: a cache written before midnight is still live after it.
        let caches = PromptCacheEstimator.statuses(from: events)
        let projectsToday = bySession.map { sid, v -> ProjectUsage in
            let name = titles[sid] ?? (v.cwd.isEmpty ? "session" : (v.cwd as NSString).lastPathComponent)
            return ProjectUsage(id: sid, name: name, cost: v.cost, tokens: v.tokens, last: v.last,
                                cache: caches[sid])
        }.sorted { $0.last > $1.last }

        var byModel: [String: Int] = [:]
        for e in today { byModel[e.model, default: 0] += e.totalTokens }
        let topModel = byModel.max { $0.value < $1.value }?.key

        // The current session's *whole-life* running total (not today-scoped), so a long chat's
        // accumulating spend is visible as it grows.
        let activeSession = events.last?.sessionId
        let activeEvents = events.filter { $0.sessionId == activeSession }
        let activeSessionTokens = activeEvents.reduce(0) { $0 + $1.totalTokens }
        let activeSessionCost = activeEvents.reduce(0) { $0 + PricingTable.cost(for: $1) }

        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let weeklyTokens = events
            .filter { $0.timestamp >= weekAgo }
            .reduce(0) { $0 + $1.totalTokens }

        let blocks = BlockCalculator.blocks(from: events)
        let active = blocks.last.flatMap { $0.contains(now) ? $0 : nil }
        // Compare the active block against the biggest COMPLETED one. Including the active
        // block in that maximum makes it divide by itself whenever it is the largest, which on a
        // two-day log window is most of the time and on a single block is always: a fabricated
        // 100% that reads as "out of budget" when nothing was measured at all. With no completed
        // block to compare against there is no honest answer, so say so with nil.
        let baseline = blocks.filter { !$0.contains(now) }.map(\.totalTokens).max() ?? 0
        let estimate: Double? = active.flatMap { block in
            baseline > 0 ? min(1, Double(block.totalTokens) / Double(baseline)) : nil
        }

        return UsageSnapshot(
            blockRemaining: active?.remaining(at: now),
            blockFractionElapsed: active?.fractionElapsed(at: now) ?? 0,
            blockEnd: active?.end,
            tokensToday: tokensToday,
            costToday: costToday,
            activeSessionTokens: activeSessionTokens,
            activeSessionCost: activeSessionCost,
            weeklyTokens: weeklyTokens,
            projectsToday: projectsToday,
            topModel: topModel,
            blockUsageEstimate: estimate)
    }
}
