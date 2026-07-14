import Foundation

enum RingState { case ok, warn, critical }

/// One conversation's recent spend, for the sessions list.
struct ProjectUsage: Equatable, Sendable, Identifiable {
    let id: String          // sessionId
    let name: String        // sidebar conversation title, else project folder
    let cost: Double
    let tokens: Int
    let last: Date          // most recent activity in the window
}

struct UsageSnapshot: Equatable, Sendable {
    var blockRemaining: TimeInterval?
    var blockFractionElapsed: Double
    var blockEnd: Date?
    var tokensToday: Int
    var costToday: Double
    /// The current (most-recently-active) session's running totals, across its whole life.
    var activeSessionTokens: Int
    var activeSessionCost: Double = 0
    var weeklyTokens: Int = 0
    /// Projects worked in today with their spend, most-recently-active first (for the sessions list).
    var projectsToday: [ProjectUsage] = []
    var topModel: String?
    /// Rough fallback usage (0…1): active-block tokens ÷ largest block ever seen.
    /// Used only until the authoritative statusline rate-limit % is available.
    var blockUsageEstimate: Double = 0

    var isEmpty: Bool { tokensToday == 0 && blockRemaining == nil }

    var ringState: RingState {
        switch blockFractionElapsed {
        case ..<0.66: return .ok
        case ..<0.85: return .warn
        default:      return .critical
        }
    }

    static let empty = UsageSnapshot(blockRemaining: nil, blockFractionElapsed: 0,
        blockEnd: nil, tokensToday: 0, costToday: 0, activeSessionTokens: 0,
        topModel: nil)
}
