import Foundation

/// Which providers this Mac can actually show numbers for.
///
/// Clicking the island's icon cycles providers, and a cycle that walks through tools the user has
/// never installed is just a dead end they have to click past. Detection here is deliberately
/// cheap and side-effect free: file existence only, so it never prompts for the Keychain, never
/// launches a CLI, and costs nothing to ask.
///
/// Results are cached briefly because the closed pill re-renders constantly and this must never
/// become a filesystem stat per frame.
@MainActor
enum ProviderAvailability {
    private static var cache: (providers: Set<UsageProviderID>, at: Date)?
    private static let ttl: TimeInterval = 30

    /// Providers that look usable right now, in menu order.
    static func available() -> [UsageProviderID] {
        let usable = usableSet()
        return UsageProviderID.allCases.filter { usable.contains($0) }
    }

    static func isAvailable(_ provider: UsageProviderID) -> Bool {
        usableSet().contains(provider)
    }

    /// Forget the cached answer, e.g. after the user installs a CLI while the app is running.
    static func invalidate() { cache = nil }

    private static func usableSet() -> Set<UsageProviderID> {
        if let cache, Date().timeIntervalSince(cache.at) < ttl { return cache.providers }
        let providers = Set(UsageProviderID.allCases.filter(detect))
        cache = (providers, Date())
        return providers
    }

    private static func detect(_ provider: UsageProviderID) -> Bool {
        switch provider {
        // Claude is the app's reason for existing and degrades on its own (live limits, then the
        // terminal feed, then a log estimate), so it is always offered.
        case .claude: true
        case .codex: CodexPaths.executable() != nil
        // Either half is enough: the CLI alone gives quota rings, and local stores alone still
        // fill the chart and tiles when `agy` is missing.
        case .antigravity:
            AntigravityPaths.executable() != nil || !AntigravityPaths.dataDirectories.isEmpty
        }
    }
}
