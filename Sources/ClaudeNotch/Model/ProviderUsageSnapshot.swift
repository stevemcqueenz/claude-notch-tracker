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
        case .codex: "chevron.left.forwardslash.chevron.right"
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

struct ProviderUsageSnapshot: Equatable, Sendable {
    let provider: UsageProviderID
    var limits: [UsageLimitMetric] = []
    var stats: [UsageStatMetric] = []
    var todayCost: Double?
    var todayTokens: Int?
    var lifetimeCost: Double?
    var lifetimeTokens: Int?
    var sessionsTitle = "active sessions"
    var sessions: [UsageSessionMetric] = []
    var alternateSessionsTitle: String?
    var alternateSessions: [UsageSessionMetric] = []
    var planName: String?
    var source: String?
    var fetchedAt: Date?
    var statusMessage: String?

    var primaryUsage: Double? {
        limits.compactMap(\.usedFraction).first
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
