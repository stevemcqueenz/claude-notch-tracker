import Foundation

struct Block: Equatable, Sendable {
    static let duration: TimeInterval = 5 * 3600

    let start: Date
    var end: Date { start.addingTimeInterval(Block.duration) }
    var events: [UsageEvent]

    var totalTokens: Int { events.reduce(0) { $0 + $1.totalTokens } }
    var lastActivity: Date { events.map(\.timestamp).max() ?? start }

    func remaining(at now: Date) -> TimeInterval { max(0, end.timeIntervalSince(now)) }
    func fractionElapsed(at now: Date) -> Double {
        min(1, max(0, now.timeIntervalSince(start) / Block.duration))
    }
    func contains(_ now: Date) -> Bool { now >= start && now < end }
}
