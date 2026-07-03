import Foundation

enum RingState { case ok, warn, critical }

struct UsageSnapshot: Equatable, Sendable {
    var blockRemaining: TimeInterval?
    var blockFractionElapsed: Double
    var blockEnd: Date?
    var tokensToday: Int
    var costToday: Double
    var activeSessionTokens: Int
    var weeklyTokens: Int = 0
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
