import Foundation

/// Scans *every* Claude Code log (not just the recent window the live store holds) to total
/// lifetime tokens and cost. Runs off the main actor; one file at a time so memory stays bounded.
actor LifetimeScanner {
    struct DayTotal: Sendable, Equatable {
        var tokens: Int = 0
        var cost: Double = 0
    }

    struct Totals: Sendable, Equatable {
        var tokens: Int = 0
        var cost: Double = 0
        var fableTokens: Int = 0     // Fable is a separate model line, tracked on its own
        var fableCost: Double = 0
        var projects: [ProjectUsage] = []   // biggest-spending projects of all time, cost-desc
        /// Per-day totals for the last ~7 days, keyed by local "yyyy-MM-dd" — feeds the week chart.
        var recentDays: [String: DayTotal] = [:]
    }

    func scan() -> Totals {
        var totals = Totals()
        var byProject: [String: (tokens: Int, cost: Double, last: Date)] = [:]
        let recentCutoff = Date().addingTimeInterval(-8 * 86_400)
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        for url in ClaudePaths.allLogFiles() {
            guard let events = try? LogParser.parse(fileURL: url) else { continue }
            var seen = Set<String>()                 // dedup streaming duplicates within a session
            for e in events where seen.insert(e.dedupeKey).inserted {
                let cost = PricingTable.cost(for: e)
                totals.tokens += e.totalTokens
                totals.cost += cost
                if e.model.contains("fable") {
                    totals.fableTokens += e.totalTokens
                    totals.fableCost += cost
                }
                if e.timestamp > recentCutoff {
                    let key = dayFormatter.string(from: e.timestamp)
                    var day = totals.recentDays[key] ?? DayTotal()
                    day.tokens += e.totalTokens
                    day.cost += cost
                    totals.recentDays[key] = day
                }
                let name = e.cwd.isEmpty ? "unknown" : (e.cwd as NSString).lastPathComponent
                var p = byProject[name] ?? (0, 0, .distantPast)
                p.tokens += e.totalTokens
                p.cost += cost
                if e.timestamp > p.last { p.last = e.timestamp }
                byProject[name] = p
            }
        }
        totals.projects = byProject
            .map { ProjectUsage(id: $0.key, name: $0.key, cost: $0.value.cost, tokens: $0.value.tokens, last: $0.value.last) }
            .sorted { $0.cost > $1.cost }
        return totals
    }
}
