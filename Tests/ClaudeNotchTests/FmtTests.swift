import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct FmtTests {
    /// Regression: under an hour these used to render a dead "0h" prefix, e.g. "0h 40m".
    @Test func shortDurationsDropTheZeroHour() {
        #expect(Fmt.until(Date().addingTimeInterval(2430)) == "40m")     // 40.5 min
        #expect(Fmt.hm(2430) == "40m")
        #expect(Fmt.dur(2430) == "40m")
    }

    @Test func longerDurationsKeepHoursAndDays() {
        #expect(Fmt.until(Date().addingTimeInterval(4230)) == "1h 10m")  // 1h 10.5m
        #expect(Fmt.until(Date().addingTimeInterval(5 * 86_400 + 3 * 3600 + 1800)) == "5d 3h")
        #expect(Fmt.hm(4200) == "1h 10m")
    }

    @Test func pastDatesClampToZero() {
        #expect(Fmt.until(Date().addingTimeInterval(-500)) == "0m")
    }

    @Test func moneyHasThousandsSeparators() {
        #expect(Fmt.usd(11_592.36) == "$11,592.36")
        #expect(Fmt.usd(3) == "$3.00")
        #expect(Fmt.money(1_234.5, currency: "CNY") == "¥1,234.50")
        #expect(Fmt.money(1_234.5, currency: nil) == "$1,234.50")
    }

    @Test func compactMoneyStaysShort() {
        #expect(Fmt.compactMoney(12_400, currency: "USD") == "$12.4K")
        #expect(Fmt.compactMoney(250, currency: "CNY") == "¥250")
        #expect(Fmt.compactMoney(4.25, currency: nil) == "$4.2" || Fmt.compactMoney(4.25, currency: nil) == "$4.3")
    }

    @Test func tokensScaleToBillions() {
        #expect(Fmt.tokens(5_400_000_000) == "5.4B")
        #expect(Fmt.tokens(2_500_000) == "2.5M")
        #expect(Fmt.tokens(42_000) == "42K")
        #expect(Fmt.tokens(999) == "999")
    }
}
