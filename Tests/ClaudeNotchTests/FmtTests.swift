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

    @Test(arguments: [
        ("claude-opus-4-8", "Opus 4.8"),
        ("claude-sonnet-5-5-20261001", "Sonnet 5.5"),
        ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
        ("claude-fable-5-1", "Fable 5.1"),
    ])
    func claudeModelIdsReadAsSpoken(id: String, name: String) {
        #expect(Fmt.claudeModel(id) == name)
    }

    @Test func pastDatesClampToZero() {
        #expect(Fmt.until(Date().addingTimeInterval(-500)) == "0m")
    }
}
