import Testing
import Foundation
@testable import ClaudeNotch

private func utc(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f.date(from: iso)!
}

/// Trimmed from holiday-cn's 2026.json: the Spring Festival, National Day, and a make-up working
/// day, which must not count as a day off.
private let holidays2026 = Data("""
{"year": 2026, "papers": [], "days": [
  {"name": "春节", "date": "2026-02-15", "isOffDay": true},
  {"name": "春节", "date": "2026-02-16", "isOffDay": true},
  {"name": "春节", "date": "2026-02-17", "isOffDay": true},
  {"name": "春节", "date": "2026-02-18", "isOffDay": true},
  {"name": "春节", "date": "2026-02-19", "isOffDay": true},
  {"name": "春节", "date": "2026-02-20", "isOffDay": true},
  {"name": "春节", "date": "2026-02-21", "isOffDay": true},
  {"name": "春节", "date": "2026-02-22", "isOffDay": true},
  {"name": "春节", "date": "2026-02-23", "isOffDay": true},
  {"name": "国庆节", "date": "2026-10-01", "isOffDay": true},
  {"name": "国庆节", "date": "2026-10-02", "isOffDay": true},
  {"name": "国庆节", "date": "2026-10-05", "isOffDay": true},
  {"name": "国庆节", "date": "2026-10-06", "isOffDay": true},
  {"name": "国庆节", "date": "2026-10-07", "isOffDay": true},
  {"name": "国庆节", "date": "2026-10-10", "isOffDay": false}
]}
""".utf8)

private let holidays = ChineseHolidayCalendar.empty.merging(holidayCNJSON: holidays2026)!

@Suite struct DeepSeekPricingTests {
    /// Monday 14 September 2026 in Beijing: 10:00 and 15:00 are peak, 12:30 and 19:00 are not.
    @Test(arguments: [
        ("2026-09-14T02:00:00Z", DeepSeekPricing.Phase.peak),
        ("2026-09-14T04:30:00Z", .offPeak),
        ("2026-09-14T07:00:00Z", .peak),
        ("2026-09-14T11:00:00Z", .offPeak),
        ("2026-09-13T02:00:00Z", .offPeak),   // a Sunday
    ])
    func weekdayWindowsInBeijingTime(_ iso: String, _ expected: DeepSeekPricing.Phase) {
        #expect(DeepSeekPricing.phase(at: utc(iso), holidays: .empty) == expected)
    }

    @Test func aWeekdayHolidayIsOffPeakAllDay() {
        // Friday 2 October 2026, 10:00 in Beijing — National Day.
        #expect(DeepSeekPricing.phase(at: utc("2026-10-02T02:00:00Z"), holidays: holidays) == .offPeak)
        #expect(DeepSeekPricing.phase(at: utc("2026-10-02T02:00:00Z"), holidays: .empty) == .peak)
        // Thursday 8 October is a working day again.
        #expect(DeepSeekPricing.phase(at: utc("2026-10-08T02:00:00Z"), holidays: holidays) == .peak)
    }

    @Test func nextPeakSkipsTheWholeHoliday() {
        let nationalDay = DeepSeekPricing.nextTransition(after: utc("2026-10-02T02:00:00Z"),
                                                         holidays: holidays)
        #expect(nationalDay == .init(phase: .peak, date: utc("2026-10-08T01:00:00Z")))
        // Friday evening before the Spring Festival: eleven days to the next peak.
        let springFestival = DeepSeekPricing.nextTransition(after: utc("2026-02-13T10:30:00Z"),
                                                            holidays: holidays)
        #expect(springFestival == .init(phase: .peak, date: utc("2026-02-24T01:00:00Z")))
    }

    @Test func nextChangeWithinADay() {
        let lunch = DeepSeekPricing.nextTransition(after: utc("2026-09-14T02:30:00Z"), holidays: .empty)
        #expect(lunch == .init(phase: .offPeak, date: utc("2026-09-14T04:00:00Z")))
    }
}

@Suite struct ChineseHolidayCalendarTests {
    @Test func makeUpDaysAndUnpublishedYearsAreIgnored() {
        #expect(holidays.years == [2026])
        #expect(holidays.offDays.contains("2026-10-01"))
        #expect(!holidays.offDays.contains("2026-10-10"))
        #expect(holidays.merging(holidayCNJSON: Data(#"{"year": 2027, "papers": [], "days": []}"#.utf8)) == nil)
        #expect(holidays.merging(holidayCNJSON: Data("not json".utf8)) == nil)
    }

    @Test func theBundledCalendarCoversTheYearItShipsWith() async {
        let source = ChineseHolidaySource(cacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        #expect(await source.calendar.years.contains(2026))
    }

    /// On the 28th (Beijing) once the needed years are in, or at the first refresh after it;
    /// daily while this year, or next year in December, is not.
    @Test func checksOnThe28thUnlessAYearIsMissing() {
        func due(_ last: String?, _ now: String, _ calendar: ChineseHolidayCalendar = holidays) -> Bool {
            ChineseHolidaySource.isCheckDue(lastChecked: last.map(utc), calendar: calendar, now: utc(now))
        }
        #expect(due(nil, "2026-10-03T04:00:00Z"))
        #expect(!due("2026-09-28T01:00:00Z", "2026-10-27T04:00:00Z"))   // before Oct 28
        #expect(due("2026-09-28T01:00:00Z", "2026-10-27T16:00:00Z"))    // Oct 28 00:00 Beijing
        #expect(due("2026-09-20T01:00:00Z", "2026-10-03T04:00:00Z"))    // missed Sept 28
        #expect(!due("2026-10-27T17:00:00Z", "2026-11-10T04:00:00Z"))   // checked on Oct 28
        #expect(!due("2025-12-28T01:00:00Z", "2026-01-10T04:00:00Z"))   // January looks back to December
        #expect(due("2026-01-20T01:00:00Z", "2026-02-28T04:00:00Z"))    // February has a 28th too
        // A missing year: daily.
        #expect(!due("2026-12-03T00:00:00Z", "2026-12-03T10:00:00Z"))
        #expect(due("2026-12-02T04:00:00Z", "2026-12-03T04:00:00Z"))
        #expect(due("2027-01-01T04:00:00Z", "2027-01-02T04:00:00Z"))
        #expect(due("2026-10-02T04:00:00Z", "2026-10-03T04:00:00Z", .empty))
    }
}

@Suite struct DeepSeekBalanceTests {
    @Test func readsTheDocumentedResponse() throws {
        let balance = try DeepSeekBalance.parse(Data("""
        {"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "110.00",
          "granted_balance": "10.00", "topped_up_balance": "100.00"}]}
        """.utf8))
        #expect(balance == .init(currency: "CNY", total: 110, granted: 10, toppedUp: 100, isAvailable: true))
    }

    /// An empty USD wallet listed first must not hide the funded CNY one.
    @Test func picksTheFundedWallet() throws {
        let balance = try DeepSeekBalance.parse(Data("""
        {"is_available": true, "balance_infos": [
          {"currency": "USD", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00"},
          {"currency": "CNY", "total_balance": "12.50", "granted_balance": "0.00", "topped_up_balance": "12.50"}]}
        """.utf8))
        #expect(balance.currency == "CNY")
        #expect(balance.total == 12.5)
    }

    @Test func malformedIsAnError() {
        #expect(throws: DeepSeekBalance.Failure.self) { try DeepSeekBalance.parse(Data("{}".utf8)) }
    }
}

@Suite struct DeepSeekSpendLedgerTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return c
    }

    @Test func dropsAreSpendAndRisesAreTopUps() {
        var ledger = DeepSeekSpendLedger()
        ledger.record(balance: 50, currency: "CNY", at: utc("2026-09-14T01:00:00Z"), calendar: calendar)
        ledger.record(balance: 48.5, currency: "CNY", at: utc("2026-09-14T02:00:00Z"), calendar: calendar)
        ledger.record(balance: 98.5, currency: "CNY", at: utc("2026-09-14T03:00:00Z"), calendar: calendar)
        ledger.record(balance: 97, currency: "CNY", at: utc("2026-09-14T04:00:00Z"), calendar: calendar)

        #expect(ledger.spent(on: utc("2026-09-14T05:00:00Z"), calendar: calendar) == 3)
        #expect(ledger.topUps.map(\.amount) == [50])
    }

    @Test func spendSeenOnTheSameDayLandsOnThatDay() {
        var ledger = DeepSeekSpendLedger()
        ledger.record(balance: 10, currency: "CNY", at: utc("2026-09-14T01:00:00Z"), calendar: calendar)
        ledger.record(balance: 9, currency: "CNY", at: utc("2026-09-14T02:00:00Z"), calendar: calendar)
        let week = ledger.lastDays(7, endingAt: utc("2026-09-14T02:00:00Z"), calendar: calendar)
        #expect(week.count == 7)
        #expect(week.last?.spent == 1)
        #expect(week.dropLast().allSatisfy { $0.spent == 0 })
        #expect(ledger.lastSpendAt == utc("2026-09-14T02:00:00Z"))
    }

    /// The balance is only polled while DeepSeek is on screen: a drop seen after a gap belongs to
    /// the day of the previous reading, not to the day it was noticed.
    @Test func aDropAfterAGapIsNotBookedAsSpentToday() {
        var ledger = DeepSeekSpendLedger()
        // 23:00 on the 13th local (+8), then 09:00 on the 14th local.
        ledger.record(balance: 10, currency: "CNY", at: utc("2026-09-13T15:00:00Z"), calendar: calendar)
        ledger.record(balance: 9, currency: "CNY", at: utc("2026-09-14T01:00:00Z"), calendar: calendar)
        let week = ledger.lastDays(7, endingAt: utc("2026-09-14T02:00:00Z"), calendar: calendar)
        #expect(week.last?.spent == 0)
        #expect(ledger.spent(on: utc("2026-09-13T15:00:00Z"), calendar: calendar) == 1)
        #expect(ledger.totalSpent == 1)
        // Further drops on the same day as the new reading count today again.
        ledger.record(balance: 8, currency: "CNY", at: utc("2026-09-14T02:00:00Z"), calendar: calendar)
        #expect(ledger.spent(on: utc("2026-09-14T02:00:00Z"), calendar: calendar) == 1)
    }

    @Test func aDifferentWalletStartsOver() {
        var ledger = DeepSeekSpendLedger()
        ledger.record(balance: 10, currency: "CNY", at: utc("2026-09-14T01:00:00Z"), calendar: calendar)
        ledger.record(balance: 9, currency: "CNY", at: utc("2026-09-14T02:00:00Z"), calendar: calendar)
        ledger.record(balance: 3, currency: "USD", at: utc("2026-09-14T03:00:00Z"), calendar: calendar)
        #expect(ledger.totalSpent == 0)
        #expect(ledger.topUps.isEmpty)
        #expect(ledger.currency == "USD")
    }

    /// What makes the whale spout: the last reading that found the balance lower — not a top-up,
    /// and not a reading on another wallet.
    @Test func remembersWhenMoneyLastLeft() {
        var ledger = DeepSeekSpendLedger()
        ledger.record(balance: 10, currency: "CNY", at: utc("2026-09-14T01:00:00Z"), calendar: calendar)
        #expect(ledger.lastSpendAt == nil)
        ledger.record(balance: 9, currency: "CNY", at: utc("2026-09-14T02:00:00Z"), calendar: calendar)
        ledger.record(balance: 20, currency: "CNY", at: utc("2026-09-14T03:00:00Z"), calendar: calendar)
        #expect(ledger.lastSpendAt == utc("2026-09-14T02:00:00Z"))
        ledger.record(balance: 5, currency: "USD", at: utc("2026-09-14T04:00:00Z"), calendar: calendar)
        #expect(ledger.lastSpendAt == nil)
    }

    @Test func aLedgerSavedBeforeTheSpoutStillDecodes() throws {
        let saved = #"{"currency":"CNY","lastBalance":3.27,"spentByDay":{},"topUps":[]}"#
        let ledger = try JSONDecoder().decode(DeepSeekSpendLedger.self, from: Data(saved.utf8))
        #expect(ledger.lastBalance == 3.27)
        #expect(ledger.lastSpendAt == nil)
    }

    @Test func survivesARelaunch() throws {
        var ledger = DeepSeekSpendLedger()
        ledger.record(balance: 10, currency: "CNY", at: utc("2026-09-14T01:00:00Z"), calendar: calendar)
        ledger.record(balance: 8, currency: "CNY", at: utc("2026-09-14T02:00:00Z"), calendar: calendar)
        let decoded = try JSONDecoder().decode(DeepSeekSpendLedger.self,
                                               from: JSONEncoder().encode(ledger))
        #expect(decoded == ledger)
    }
}

@Suite struct DeepSeekSnapshotTests {
    private let balance = DeepSeekBalance(currency: "CNY", total: 42.1, granted: 2.1,
                                          toppedUp: 40, isAvailable: true)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return c
    }

    @Test func peakShowsAmberAndTheBalance() {
        let snapshot = DeepSeekSnapshotMapper.make(balance: balance, ledger: .init(), holidays: .empty,
                                                   now: utc("2026-09-14T02:00:00Z"), calendar: calendar)
        #expect(snapshot.pill == UsagePill(text: "¥42.1", tint: .warn))
        let now = snapshot.stats.first { $0.id == "pricing-now" }
        #expect(now?.value == "Peak · 2×")
        #expect(now?.subtitle == "off-peak from 12:00")
        #expect(snapshot.stats.first { $0.id == "balance" }?.value == "¥42.10")
        #expect(snapshot.currency == "CNY")
        #expect(snapshot.limits.isEmpty)
    }

    @Test func offPeakOnAHolidayNamesTheNextWorkingDay() {
        let snapshot = DeepSeekSnapshotMapper.make(balance: balance, ledger: .init(), holidays: holidays,
                                                   now: utc("2026-10-02T02:00:00Z"), calendar: calendar)
        #expect(snapshot.pill?.tint == .ok)
        #expect(snapshot.stats.first { $0.id == "pricing-now" }?.subtitle == "peak from Thu 09:00")
    }

    @Test func anExhaustedBalanceIsCritical() {
        let empty = DeepSeekBalance(currency: "CNY", total: 0, granted: 0, toppedUp: 0, isAvailable: false)
        let snapshot = DeepSeekSnapshotMapper.make(balance: empty, ledger: .init(), holidays: .empty,
                                                   now: utc("2026-09-14T02:00:00Z"), calendar: calendar)
        #expect(snapshot.pill?.tint == .critical)
        #expect(snapshot.statusMessage != nil)
    }
}

@Suite struct MoneyFormatTests {
    @Test func currencies() {
        #expect(Fmt.money(3.5, currency: nil) == "$3.50")
        #expect(Fmt.money(3.5, currency: "CNY") == "¥3.50")
        #expect(Fmt.compactMoney(42.14, currency: "CNY") == "¥42.1")
        #expect(Fmt.compactMoney(1234.5, currency: "CNY") == "¥1.2K")
    }
}
