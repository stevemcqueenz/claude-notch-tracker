import Foundation

enum UsageProviderID: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case antigravity
    case deepseek
    case opencodeGo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .deepseek: "DeepSeek"
        case .opencodeGo: "opencode-go"
        }
    }

    /// Shown when the user selects a provider this Mac has no install of.
    var setupHint: String {
        switch self {
        case .claude: "Sign in to Claude to see usage here"
        case .codex: "Install the Codex CLI to track usage here"
        case .antigravity: "Install the Antigravity CLI to track usage here"
        case .deepseek: "Add a DeepSeek API key from the right-click menu"
        case .opencodeGo: "Use opencode locally or sign in to opencode.ai in your browser"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "terminal.fill"
        case .antigravity: "mountain.2.fill"
        case .deepseek: "fish.fill"
        case .opencodeGo: "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct UsageLimitMetric: Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let usedFraction: Double?
    let resetsAt: Date?
    /// Absolute spend for this window, e.g. "$3.00 of $12.00" (opencode-go's micro-cent meters).
    /// nil whenever only a bare percent is known, so every other provider renders unchanged.
    let subtitle: String?

    init(id: String, label: String, usedFraction: Double?, resetsAt: Date?,
         subtitle: String? = nil) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction.map { min(1, max(0, $0)) }
        self.resetsAt = resetsAt
        self.subtitle = subtitle
    }
}

/// Colour for a value that carries a state of its own rather than a usage fraction, e.g.
/// DeepSeek's peak/off-peak phase. Matches the ring's ok/warn/critical palette.
enum UsageTint: Equatable, Sendable {
    case ok, warn, critical
}

struct UsageStatMetric: Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let value: String
    let subtitle: String?
    var tint: UsageTint? = nil
}

/// What the closed pill shows for a provider with no usage fraction to ring: a short value (a
/// balance) and a status dot in place of the ring.
struct UsagePill: Equatable, Sendable {
    let text: String
    let tint: UsageTint
}

struct UsageSessionMetric: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let cost: Double?
    let tokens: Int?
    let last: Date
    /// Nil hides the countdown, so a provider opts in by estimating this for its own sessions.
    var cache: PromptCacheStatus? = nil
}

/// One day of activity for the week chart. `cost` set (Claude's local logs) makes the chart
/// render dollars; otherwise it renders `tokens` (Codex's account feed).
struct DailyUsagePoint: Equatable, Sendable, Identifiable {
    let date: Date
    let tokens: Int
    var cost: Double? = nil
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
    /// the pages fall back to plain tile layouts.
    var dailySeries: [DailyUsagePoint] = []
    var chartTitle = "last 7 days"
    /// True = the chart belongs on the detail page (Claude: the limits page is full of limit
    /// tiles); false = it may take over the limits page (Codex: one or two windows).
    var chartOnDetailPage = false
    var sessionsTitle = "active sessions"
    var sessions: [UsageSessionMetric] = []
    var alternateSessionsTitle: String?
    var alternateSessions: [UsageSessionMetric] = []
    var planName: String?
    /// When the current billing period ends, when the server reports it (opencode-go's
    /// `access.endsAt`). Not every provider has one.
    var renewsAt: Date?
    var source: String?
    var fetchedAt: Date?
    var statusMessage: String?
    /// Replaces the closed pill's percent + ring (DeepSeek's balance + pricing phase).
    var pill: UsagePill?
    /// ISO code for every money figure in this snapshot; nil = USD (Claude's local logs).
    var currency: String?
    /// When money was last seen leaving the account (DeepSeek's balance dropping); the icon
    /// reacts to a recent one.
    var spendObservedAt: Date?

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
