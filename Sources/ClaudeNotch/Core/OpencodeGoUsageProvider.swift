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
    /// The last snapshot that actually carried numbers. Returned untouched (its old `fetchedAt`
    /// dims it via the UI's stale check) when a web round trip fails, so a blip never blanks it.
    private var lastGood: ProviderUsageSnapshot?

    func fetch(now: Date = Date()) async -> ProviderUsageSnapshot {
        switch await api.fetch(now: now) {
        case .usage(let fetched):
            // Server meters, but the 7-day bars come from local spend: the web payload has no daily
            // buckets. Best-effort — an empty/unreadable local store never blocks the web numbers.
            let snapshot = Self.attachingSeries(await localSeries(now: now), to: fetched)
            lastGood = snapshot
            return snapshot
        case .failed:
            // A web session existed but the round trip didn't parse or connect: keep the last good
            // numbers rather than replacing them with account-agnostic local estimates.
            if let lastGood { return lastGood }
            return await resolveLocal(now: now)
        case .unavailable:
            // Nothing web-signed-in to try: local history is the intended fallback, then last good.
            if let recent = Self.recentWeb(lastGood, now: now) { return recent }
            return await resolveLocal(now: now)
        }
    }

    /// How long server meters outrank local estimates once the web session stops answering.
    static let webGrace: TimeInterval = 3600

    /// The last server snapshot while it is under `webGrace` old, else nil. Local history only sees
    /// this Mac's spend against assumed plan limits and a calendar month, so swapping it in for a
    /// moment's cookie trouble would show a used-up plan as untouched; the old web numbers dim as
    /// stale instead.
    static func recentWeb(_ lastGood: ProviderUsageSnapshot?, now: Date) -> ProviderUsageSnapshot? {
        guard let lastGood, lastGood.source != "local", let at = lastGood.fetchedAt,
              now.timeIntervalSince(at) < webGrace else { return nil }
        return lastGood
    }

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
