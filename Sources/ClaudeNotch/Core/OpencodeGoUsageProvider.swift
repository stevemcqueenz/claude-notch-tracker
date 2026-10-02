import Foundation

/// opencode-go usage, local-first.
///
/// The reader blocks on SQLite, so it is confined to a utility queue rather than run on the
/// cooperative pool. Any failure (not signed in, no database, unreadable history) becomes the
/// normal `.unavailable` snapshot, whose status message the UI shows as a setup hint.
actor OpencodeGoUsageProvider {
    private static let queue = DispatchQueue(label: "opencode-go-usage", qos: .utility)

    func fetch(now: Date = Date()) async -> ProviderUsageSnapshot {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProviderUsageSnapshot, Never>) in
            Self.queue.async {
                do {
                    continuation.resume(returning: try OpencodeGoLocalUsage.fetch(now: now))
                } catch {
                    continuation.resume(returning: ProviderUsageSnapshot.unavailable(
                        .opencodeGo,
                        message: (error as? LocalizedError)?.errorDescription
                            ?? "opencode-go usage unavailable"
                    ))
                }
            }
        }
    }
}
