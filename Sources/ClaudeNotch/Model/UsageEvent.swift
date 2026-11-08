import Foundation

struct UsageEvent: Equatable, Sendable {
    let timestamp: Date
    let sessionId: String
    let requestId: String?
    let messageId: String?
    let model: String
    /// Working directory the session ran in (from the log), e.g. "/Users/me/claude/wowlab".
    let cwd: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    /// The share of `cacheCreationTokens` written to the 1-hour cache, which costs 2x input
    /// rather than 1.25x. Zero when the log predates the breakdown.
    var cacheCreation1hTokens: Int = 0
    /// True for a subagent's turn, which shares the parent's sessionId but not its prompt cache.
    var isSidechain: Bool = false

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    var dedupeKey: String {
        (messageId ?? "?") + ":" + (requestId ?? "?")
    }
}
