import Foundation

/// When a conversation's prompt cache is expected to lapse, and what lapsing would cost.
///
/// This is an estimate: nothing reports a cache's real expiry, so it is derived from the logs. A
/// model switch or `/compact` can invalidate the cache sooner than this says.
struct PromptCacheStatus: Equatable, Sendable {
    let expiresAt: Date
    /// Extra USD, at list price, for rewriting the cached context rather than reading it.
    let rebuildCost: Double

    /// How close to expiry the closed pill starts warning.
    static let warningWindow: TimeInterval = 5 * 60

    func isExpired(at now: Date) -> Bool { now >= expiresAt }

    func isExpiringSoon(at now: Date) -> Bool {
        !isExpired(at: now) && expiresAt.timeIntervalSince(now) <= Self.warningWindow
    }
}

enum PromptCacheEstimator {
    static let oneHour: TimeInterval = 3600
    static let fiveMinutes: TimeInterval = 300
    /// Log timestamps land when the response finishes, after the request that refreshed the cache,
    /// so the raw expiry runs late. Reporting it early keeps "1m left" from being a cold turn.
    static let safetyMargin: TimeInterval = 60

    /// Per-session cache status from events in ascending time order.
    ///
    /// Every cache hit restarts the TTL, so expiry follows the session's latest main-chain request.
    /// Read-only turns don't reveal a TTL, so the most recent write's TTL carries forward.
    static func statuses(from events: [UsageEvent]) -> [String: PromptCacheStatus] {
        var latest: [String: (event: UsageEvent, ttl: TimeInterval)] = [:]
        for e in events where !e.isSidechain {       // subagents keep their own separate caches
            guard e.model.hasPrefix("claude-") else {  // other backends have different cache rules
                latest[e.sessionId] = nil
                continue
            }
            let ttl = e.cacheCreationTokens > 0
                ? (e.cacheCreation1hTokens > 0 ? oneHour : fiveMinutes)
                : (latest[e.sessionId]?.ttl ?? oneHour)
            latest[e.sessionId] = (e, ttl)
        }

        var out: [String: PromptCacheStatus] = [:]
        for (session, entry) in latest {
            let cached = entry.event.cacheReadTokens + entry.event.cacheCreationTokens
            guard cached > 0 else { continue }
            let rate = PricingTable.rate(for: entry.event.model)
            let write = entry.ttl == oneHour ? rate.cacheWrite1h : rate.cacheWrite5m
            out[session] = PromptCacheStatus(
                expiresAt: entry.event.timestamp.addingTimeInterval(entry.ttl - safetyMargin),
                rebuildCost: Double(cached) * (write - rate.cacheRead) / 1_000_000)
        }
        return out
    }
}
