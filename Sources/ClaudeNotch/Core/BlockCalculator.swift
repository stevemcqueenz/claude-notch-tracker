import Foundation

enum BlockCalculator {
    static func blocks(from events: [UsageEvent]) -> [Block] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var blocks: [Block] = []
        var currentStart: Date?
        var currentLast: Date?
        var bucket: [UsageEvent] = []

        func flush() {
            if let s = currentStart { blocks.append(Block(start: s, events: bucket)) }
            bucket = []
        }

        for e in sorted {
            if let start = currentStart, let last = currentLast {
                let sinceStart = e.timestamp.timeIntervalSince(start)
                let sinceLast = e.timestamp.timeIntervalSince(last)
                if sinceStart >= Block.duration || sinceLast >= Block.duration {
                    flush()
                    currentStart = floorToHour(e.timestamp)
                }
            } else {
                currentStart = floorToHour(e.timestamp)
            }
            bucket.append(e)
            currentLast = e.timestamp
        }
        flush()
        return blocks
    }

    static func activeBlock(from events: [UsageEvent], now: Date) -> Block? {
        blocks(from: events).last.flatMap { $0.contains(now) ? $0 : nil }
    }

    static func floorToHour(_ date: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        return cal.date(from: cal.dateComponents(
            [.year, .month, .day, .hour], from: date)) ?? date
    }
}
