import Foundation

/// opencode-go usage, server meters first with local history as the fallback.
///
/// The local store cannot know the account quota, so it reconstructs windows from spend and
/// hardcodes the plan limits. The web/API path reads the real opencode.ai meters, which is what
/// makes the weekly/monthly windows line up with CodexBar. Either path blocks (Keychain, SQLite),
/// so the fallback runs on a utility queue rather than the cooperative pool.
actor OpencodeGoUsageProvider {
    private static let queue = DispatchQueue(label: "opencode-go-usage", qos: .utility)
    private let api = OpencodeGoAPI()
    /// The last snapshot that carried numbers. Returned (its old `fetchedAt` dims it via the UI's
    /// stale check) for a short while when the server round trip fails, so a blip never blanks
    /// it; past `serverGrace` the card goes back to re-reading local history on every poll.
    private var lastGood: ProviderUsageSnapshot?
    private static let serverGrace: TimeInterval = 3600

    func fetch(now: Date = Date()) async -> ProviderUsageSnapshot {
        switch await api.fetch(now: now) {
        case .usage(let fetched):
            // Server meters, but the 7-day bars come from local spend: the web payload has no daily
            // buckets. Best-effort — an empty/unreadable local store never blocks the web numbers.
            let snapshot = Self.attachingSeries(await localSeries(now: now), to: fetched)
            lastGood = snapshot
            return snapshot
        case .failed:
            // We had a credential but the round trip didn't parse or connect. Keep the last
            // server reading while it is fresh enough; otherwise local history, re-read each poll.
            if let lastGood, lastGood.source != Self.localSource,
               let fetchedAt = lastGood.fetchedAt, now.timeIntervalSince(fetchedAt) < Self.serverGrace {
                return lastGood
            }
            return await resolveLocal(now: now)
        case .keyRejected:
            var snapshot = await resolveLocal(now: now)
            snapshot.statusMessage = "opencode API key rejected"
            return snapshot
        case .unavailable:
            // Nothing web-signed-in to try: local history is the intended fallback.
            return await resolveLocal(now: now)
        }
    }

    private static let localSource = "local estimate"

    private enum Local: Sendable {
        case snapshot(ProviderUsageSnapshot)
        case unavailable(String)
    }

    private func resolveLocal(now: Date) async -> ProviderUsageSnapshot {
        switch await local(now: now) {
        case .snapshot(let snapshot):
            lastGood = snapshot
            return snapshot
        case .unavailable(let message):
            return lastGood ?? .unavailable(.opencodeGo, message: message)
        }
    }

    private func local(now: Date) async -> Local {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                do {
                    continuation.resume(returning: .snapshot(try OpencodeGoLocalUsage.fetch(now: now)))
                } catch {
                    continuation.resume(returning: .unavailable(
                        (error as? LocalizedError)?.errorDescription ?? "opencode-go usage unavailable"))
                }
            }
        }
    }

    /// The local daily cost bars for a web snapshot; an empty series leaves it exactly as fetched.
    static func attachingSeries(_ series: [DailyUsagePoint],
                                to snapshot: ProviderUsageSnapshot) -> ProviderUsageSnapshot {
        guard !series.isEmpty else { return snapshot }
        var snapshot = snapshot
        snapshot.dailySeries = series
        snapshot.chartTitle = "last 7 days · local"
        return snapshot
    }

    private func localSeries(now: Date) async -> [DailyUsagePoint] {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: OpencodeGoLocalUsage.fetchDailySeries(now: now))
            }
        }
    }
}
