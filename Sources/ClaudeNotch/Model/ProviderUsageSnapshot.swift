import Foundation

enum UsageProviderID: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case antigravity
    case deepseek
    case opencodeGo
    case ollamaCloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .deepseek: "DeepSeek"
        case .opencodeGo: "opencode-go"
        case .ollamaCloud: "Ollama Cloud"
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
        case .ollamaCloud: "Add an Ollama API key from the right-click menu"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "terminal.fill"
        case .antigravity: "mountain.2.fill"
        case .deepseek: "fish.fill"
        case .opencodeGo: "chevron.left.forwardslash.chevron.right"
        case .ollamaCloud: "cloud.fill"
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
    /// Length of the window (5 h, 7 d, a month) when known. With `resetsAt` it places the pace
    /// marker: how much of the window has already gone by.
    let window: TimeInterval?
    /// True for a limit that caps one model or model group rather than the whole account
    /// (Claude's Fable weekly, Antigravity's inactive groups, Codex's per-model buckets). Scoped
    /// limits still get a meter, but never lead the pill or set the icon's urgency.
    let scoped: Bool

    init(id: String, label: String, usedFraction: Double?, resetsAt: Date?,
         subtitle: String? = nil, window: TimeInterval? = nil, scoped: Bool = false) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction.map { min(1, max(0, $0)) }
        self.resetsAt = resetsAt
        self.subtitle = subtitle
        self.window = window
        self.scoped = scoped
    }

    /// "5-hour window" / "7-day window": all a limit with no reset time (Ollama) can say about
    /// when it frees up.
    var windowLabel: String? {
        guard let window else { return nil }
        let hours = Int((window / 3600).rounded())
        guard hours > 0 else { return nil }
        return hours % 24 == 0 ? "\(hours / 24)-day window" : "\(hours)-hour window"
    }

    /// How much of the window has elapsed, 0…1. An even pace would have used exactly this much,
    /// so usage above it means the limit runs out before it resets. nil without both a window
    /// length and a reset time.
    func elapsedFraction(now: Date = Date()) -> Double? {
        guard let window, window > 0, let resetsAt else { return nil }
        return min(1, max(0, 1 - resetsAt.timeIntervalSince(now) / window))
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

    /// What the closed pill shows: the first limit (the 5-hour session), unless an account-wide
    /// limit is used up — then that one, because it's what is blocking you. Scoped limits (one
    /// model's cap) never take over: other models still work.
    var bindingLimit: UsageLimitMetric? {
        limits.first { !$0.scoped && ($0.usedFraction ?? 0) >= 0.999 } ?? limits.first
    }

    /// The headline fraction for the collapsed pill: the binding limit's value.
    var primaryUsage: Double? {
        bindingLimit?.usedFraction
    }

    /// A fetch that failed, or came back without limits, must not blank a card that had good
    /// numbers a minute ago. This keeps the previous limits (and their `fetchedAt`, so the card
    /// ages into the dimmed "reconnecting…" state) while taking whatever fresh data did arrive and
    /// the new status message.
    func keepingLastGoodReading(from previous: ProviderUsageSnapshot) -> ProviderUsageSnapshot {
        guard previous.provider == provider,
              limits.isEmpty, pill == nil,
              !previous.limits.isEmpty || previous.pill != nil else { return self }
        let nothingNew = stats.isEmpty && dailySeries.isEmpty && sessions.isEmpty
        var kept = nothingNew ? previous : self
        kept.limits = previous.limits
        kept.pill = previous.pill
        kept.fetchedAt = previous.fetchedAt
        kept.statusMessage = statusMessage ?? previous.statusMessage
        return kept
    }

    /// Total tokens across the daily series (the chart's week), nil without a daily feed.
    var weekTokens: Int? {
        dailySeries.isEmpty ? nil : dailySeries.reduce(0) { $0 + $1.tokens }
    }

    var maximumUsage: Double {
        limits.compactMap(\.usedFraction).max() ?? 0
    }

    /// The fullest account-wide limit: how hard the icon works. Per-model caps are left out, so a
    /// used-up Fable weekly doesn't freeze Clawd while the account still has headroom.
    var accountUsage: Double {
        limits.filter { !$0.scoped }.compactMap(\.usedFraction).max() ?? 0
    }

    func isStale(now: Date = Date(), after interval: TimeInterval = 150) -> Bool {
        guard let fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) > interval
    }

    static func unavailable(_ provider: UsageProviderID, message: String? = nil) -> Self {
        ProviderUsageSnapshot(provider: provider, statusMessage: message)
    }
}
