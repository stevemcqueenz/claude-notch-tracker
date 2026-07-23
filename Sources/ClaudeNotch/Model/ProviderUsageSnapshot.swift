import Foundation

enum UsageProviderID: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "terminal.fill"
        }
    }
}

struct UsageLimitMetric: Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let usedFraction: Double?
    let resetsAt: Date?

    init(id: String, label: String, usedFraction: Double?, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction.map { min(1, max(0, $0)) }
        self.resetsAt = resetsAt
    }
}

struct UsageStatMetric: Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let value: String
    let subtitle: String?
}

struct UsageSessionMetric: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let cost: Double?
    let tokens: Int?
    let last: Date
}

/// One day of account-level token usage, for the limits-page activity chart.
struct DailyUsagePoint: Equatable, Sendable, Identifiable {
    let date: Date
    let tokens: Int
    var id: Date { date }
}

struct ProviderUsageSnapshot: Equatable, Sendable {
    let provider: UsageProviderID
    var limits: [UsageLimitMetric] = []
    var stats: [UsageStatMetric] = []
    var todayCost: Double?
    var todayTokens: Int?
    var lifetimeCost: Double?
    var lifetimeTokens: Int?
    /// Oldest-first, one point per calendar day (7 for a week view); empty = no daily feed, and
    /// the limits page falls back to a plain tile grid.
    var dailySeries: [DailyUsagePoint] = []
    var sessionsTitle = "active sessions"
    var sessions: [UsageSessionMetric] = []
    var alternateSessionsTitle: String?
    var alternateSessions: [UsageSessionMetric] = []
    var planName: String?
    var source: String?
    var fetchedAt: Date?
    var statusMessage: String?

    /// The headline fraction for the collapsed pill: the FIRST limit's value, nil when that limit
    /// has no value yet. Deliberately not "first non-nil" — falling through to a later limit would
    /// silently show, say, a weekly number where the session number belongs, unlabeled.
    var primaryUsage: Double? {
        limits.first?.usedFraction
    }

    /// Total tokens across the daily series (the chart's week), nil without a daily feed.
    var weekTokens: Int? {
        dailySeries.isEmpty ? nil : dailySeries.reduce(0) { $0 + $1.tokens }
    }

    var maximumUsage: Double {
        limits.compactMap(\.usedFraction).max() ?? 0
    }

    func isStale(now: Date = Date(), after interval: TimeInterval = 150) -> Bool {
        guard let fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) > interval
    }

    static func unavailable(_ provider: UsageProviderID, message: String? = nil) -> Self {
        ProviderUsageSnapshot(provider: provider, statusMessage: message)
    }
}
