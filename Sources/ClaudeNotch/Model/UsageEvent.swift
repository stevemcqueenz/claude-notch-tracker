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

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    var dedupeKey: String {
        (messageId ?? "?") + ":" + (requestId ?? "?")
    }
}
