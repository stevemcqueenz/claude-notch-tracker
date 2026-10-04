import Foundation

/// DeepSeek's API reports a balance and nothing about spend, so spend is what the balance is seen
/// to lose between readings. A rise is a top-up (or a grant) and is recorded on its own, never
/// netted against spend. Everything here is observed rather than estimated, and labelled so: a
/// top-up and a spend that fall between the same two readings partly cancel.
///
/// The balance is only polled while DeepSeek is on screen, so two readings can be days apart. A
/// drop whose previous reading was on an earlier calendar day is booked on that earlier day, never
/// on the day it was noticed: "spent today" must not swallow a whole weekend.
struct DeepSeekSpendLedger: Codable, Equatable, Sendable {
    struct TopUp: Codable, Equatable, Sendable {
        let date: Date
        let amount: Double
    }

    private(set) var currency: String?
    private(set) var lastBalance: Double?
    /// When readings started, so "today" can say it only covers part of the day.
    private(set) var trackingSince: Date?
    /// Local calendar day "yyyy-MM-dd" → amount spent that day.
    private(set) var spentByDay: [String: Double] = [:]
    private(set) var topUps: [TopUp] = []
    /// The last reading that found the balance lower — what makes the whale spout. Optional, so
    /// a ledger saved before it existed still decodes.
    private(set) var lastSpendAt: Date?
    /// When `lastBalance` was read. Optional so an older saved ledger still decodes (and, lacking
    /// it, books a drop on the day it is seen, as before).
    private(set) var lastReadingAt: Date?

    static let keptDays = 35
    static let keptTopUps = 10
    /// Balances are quoted to the cent; anything smaller between two readings is rounding.
    private static let epsilon = 0.000_5

    mutating func record(balance: Double, currency: String, at date: Date,
                         calendar: Calendar = .current) {
        // A different wallet is a different balance, not a spend or a top-up of this one.
        if currency != self.currency {
            self.currency = currency
            lastBalance = balance
            trackingSince = date
            spentByDay = [:]
            topUps = []
            lastSpendAt = nil
            lastReadingAt = date
            return
        }
        if trackingSince == nil { trackingSince = date }
        if let last = lastBalance {
            let delta = last - balance
            if delta > Self.epsilon {
                // After a gap the drop happened sometime since the previous reading; the earlier
                // day is the honest place for it, and it is not a "just now" spend either.
                if let previous = lastReadingAt, !calendar.isDate(previous, inSameDayAs: date) {
                    spentByDay[Self.dayKey(previous, calendar), default: 0] += delta
                } else {
                    spentByDay[Self.dayKey(date, calendar), default: 0] += delta
                    lastSpendAt = date
                }
            } else if delta < -Self.epsilon {
                topUps.append(TopUp(date: date, amount: -delta))
                topUps = Array(topUps.suffix(Self.keptTopUps))
            }
        }
        lastBalance = balance
        lastReadingAt = date
        prune(before: date, calendar: calendar)
    }

    func spent(on date: Date, calendar: Calendar = .current) -> Double {
        spentByDay[Self.dayKey(date, calendar)] ?? 0
    }

    /// Oldest first, today last.
    func lastDays(_ count: Int, endingAt date: Date,
                  calendar: Calendar = .current) -> [(date: Date, spent: Double)] {
        let today = calendar.startOfDay(for: date)
        return (0..<count).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (day, spent(on: day, calendar: calendar))
        }
    }

    var totalSpent: Double { spentByDay.values.reduce(0, +) }

    static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private mutating func prune(before date: Date, calendar: Calendar) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.keptDays,
                                         to: calendar.startOfDay(for: date)) else { return }
        let oldest = Self.dayKey(cutoff, calendar)
        spentByDay = spentByDay.filter { $0.key >= oldest }
    }
}
