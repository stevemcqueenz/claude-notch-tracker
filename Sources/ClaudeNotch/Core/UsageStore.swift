import Foundation

/// Aggregates parsed events from every log file into a render-ready snapshot.
final class UsageStore {
    private var eventsByFile: [URL: [UsageEvent]] = [:]

    func ingest(fileURL: URL) throws {
        eventsByFile[fileURL] = try LogParser.parse(fileURL: fileURL)
    }

    /// Store already-parsed events for a file (used when parsing happened off-main).
    func ingest(fileURL: URL, events: [UsageEvent]) {
        eventsByFile[fileURL] = events
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

    func snapshot(now: Date) -> UsageSnapshot {
        let events = allEvents()
        guard !events.isEmpty else { return .empty }

        let cal = Calendar.current
        let today = events.filter { cal.isDate($0.timestamp, inSameDayAs: now) }

        let tokensToday = today.reduce(0) { $0 + $1.totalTokens }
        let costToday = today.reduce(0) { $0 + PricingTable.cost(for: $1) }

        var byModel: [String: Int] = [:]
        for e in today { byModel[e.model, default: 0] += e.totalTokens }
        let topModel = byModel.max { $0.value < $1.value }?.key

        let activeSession = events.last?.sessionId
        let activeSessionTokens = today
            .filter { $0.sessionId == activeSession }
            .reduce(0) { $0 + $1.totalTokens }

        let blocks = BlockCalculator.blocks(from: events)
        let active = blocks.last.flatMap { $0.contains(now) ? $0 : nil }
        let maxBlockTokens = blocks.map(\.totalTokens).max() ?? 0
        let estimate = maxBlockTokens > 0
            ? min(1, Double(active?.totalTokens ?? 0) / Double(maxBlockTokens)) : 0

        return UsageSnapshot(
            blockRemaining: active?.remaining(at: now),
            blockFractionElapsed: active?.fractionElapsed(at: now) ?? 0,
            blockEnd: active?.end,
            tokensToday: tokensToday,
            costToday: costToday,
            activeSessionTokens: activeSessionTokens,
            topModel: topModel,
            blockUsageEstimate: estimate)
    }
}
