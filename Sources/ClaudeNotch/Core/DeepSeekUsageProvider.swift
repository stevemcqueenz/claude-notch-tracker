import Foundation

/// DeepSeek through its official balance endpoint: the balance itself, the peak/off-peak phase
/// it is being billed at, and spend observed from the balance going down (see
/// `DeepSeekSpendLedger`). DeepSeek has no usage-limit window, so the pill shows the balance and
/// a phase dot instead of a percent ring.
actor DeepSeekUsageProvider {
    static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private static let ledgerKey = "deepseekSpendLedger"

    private let holidays = ChineseHolidaySource()
    private var ledger: DeepSeekSpendLedger
    private var lastBalance: DeepSeekBalance?
    private var lastFetchedAt: Date?
    /// Read once: a Keychain read per poll would be a prompt per poll on an ad-hoc build.
    private var cachedKey: String?
    /// Set by a 401: the Keychain is not re-read (a prompt per poll) until the key is changed.
    private var keyRejected = false

    init() {
        ledger = UserDefaults.standard.data(forKey: Self.ledgerKey)
            .flatMap { try? JSONDecoder().decode(DeepSeekSpendLedger.self, from: $0) }
            ?? DeepSeekSpendLedger()
    }

    /// The user set or removed the key. A different key may be a different account, so its
    /// balance must not be read as a top-up or a spend of the old one: forget the last balance
    /// and the ledger along with the key.
    func resetCredentials() {
        cachedKey = nil
        keyRejected = false
        lastBalance = nil
        lastFetchedAt = nil
        ledger = DeepSeekSpendLedger()
        UserDefaults.standard.removeObject(forKey: Self.ledgerKey)
    }

    func fetch(now: Date = Date()) async -> ProviderUsageSnapshot {
        if cachedKey == nil, !keyRejected { cachedKey = APIKeyCredentials.deepseek.read() }
        guard cachedKey != nil || keyRejected else {
            return .unavailable(.deepseek, message: UsageProviderID.deepseek.setupHint)
        }
        // Holiday dates only matter with a key: without one this would ping jsDelivr on
        // every poll of an unconfigured provider.
        await holidays.refreshIfDue(now: now)
        let calendar = await holidays.calendar

        var message: String?
        do {
            guard let key = cachedKey else { throw DeepSeekBalance.Failure.unauthorized }
            let balance = try await Self.requestBalance(key: key)
            lastBalance = balance
            lastFetchedAt = now
            ledger.record(balance: balance.total, currency: balance.currency, at: now)
            if let data = try? JSONEncoder().encode(ledger) {
                UserDefaults.standard.set(data, forKey: Self.ledgerKey)
            }
        } catch DeepSeekBalance.Failure.unauthorized {
            cachedKey = nil
            keyRejected = true
            message = "DeepSeek rejected the API key"
        } catch {
            // Static text on purpose: surfacing raw network errors would pipe any future
            // payload-bearing error into the pill (the Antigravity provider follows the
            // same rule for endpoint URLs).
            message = "DeepSeek unreachable"
        }

        guard let balance = lastBalance else {
            return .unavailable(.deepseek, message: message ?? "Waiting for the first reading")
        }
        var snapshot = DeepSeekSnapshotMapper.make(balance: balance, ledger: ledger,
                                                   holidays: calendar, now: now)
        // A failed poll keeps the last good reading, dimmed by its age, plus the reason.
        snapshot.fetchedAt = lastFetchedAt
        if let message { snapshot.statusMessage = message }
        return snapshot
    }

    private static func requestBalance(key: String) async throws -> DeepSeekBalance {
        var request = URLRequest(url: balanceURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw DeepSeekBalance.Failure.unauthorized }
        guard status == 200 else { throw DeepSeekBalance.Failure.http(status) }
        return try DeepSeekBalance.parse(data)
    }
}

/// One wallet from `GET /user/balance`.
struct DeepSeekBalance: Equatable, Sendable {
    let currency: String
    let total: Double
    let granted: Double
    let toppedUp: Double
    /// DeepSeek's own "balance is sufficient for API calls".
    let isAvailable: Bool

    enum Failure: Error, LocalizedError {
        case unauthorized, http(Int), malformed
        var errorDescription: String? {
            switch self {
            case .unauthorized: "API key rejected"
            case .http(let code): "HTTP \(code)"
            case .malformed: "unrecognised balance response"
            }
        }
    }

    /// An account can hold both a CNY and a USD wallet, usually with one of them empty; reading
    /// the first would show ¥0.00 to someone whose money is in the other. The funded one wins,
    /// and CNY breaks a tie because that is where DeepSeek bills by default.
    static func parse(_ data: Data) throws -> DeepSeekBalance {
        struct Wire: Decodable {
            struct Info: Decodable {
                let currency: String
                let total_balance: String
                let granted_balance: String
                let topped_up_balance: String
            }
            let is_available: Bool
            let balance_infos: [Info]
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { throw Failure.malformed }
        let wallets = wire.balance_infos.compactMap { info -> DeepSeekBalance? in
            guard let total = Double(info.total_balance) else { return nil }
            return DeepSeekBalance(currency: info.currency, total: total,
                                   granted: Double(info.granted_balance) ?? 0,
                                   toppedUp: Double(info.topped_up_balance) ?? 0,
                                   isAvailable: wire.is_available)
        }
        guard let best = wallets.max(by: { a, b in
            a.total != b.total ? a.total < b.total : (a.currency != "CNY" && b.currency == "CNY")
        }) else { throw Failure.malformed }
        return best
    }
}

/// Pure snapshot assembly, so the tiles can be tested without a network or a Keychain.
enum DeepSeekSnapshotMapper {
    static func make(balance: DeepSeekBalance, ledger: DeepSeekSpendLedger,
                     holidays: ChineseHolidayCalendar, now: Date,
                     calendar: Calendar = .current) -> ProviderUsageSnapshot {
        let currency = balance.currency
        let money = { (v: Double) in Fmt.money(v, currency: currency) }
        let phase = DeepSeekPricing.phase(at: now, holidays: holidays)
        let next = DeepSeekPricing.nextTransition(after: now, holidays: holidays)

        let phaseTile = UsageStatMetric(
            id: "pricing-now", label: "pricing now",
            value: phase == .peak ? "Peak · 2×" : "Off-peak",
            subtitle: next.map { transition in
                let when = clock(transition.date, now: now, calendar: calendar)
                return transition.phase == .peak ? "peak from \(when)" : "off-peak from \(when)"
            },
            tint: phase == .peak ? .warn : .ok
        )

        let week = ledger.lastDays(7, endingAt: now, calendar: calendar)
        let spentToday = ledger.spent(on: now, calendar: calendar)
        let weekTotal = week.reduce(0) { $0 + $1.spent }
        let partialToday = ledger.trackingSince.map {
            $0 > calendar.startOfDay(for: now).addingTimeInterval(10 * 60)
        } ?? false

        let stats = [
            UsageStatMetric(
                id: "balance", label: "balance",
                value: money(balance.total),
                subtitle: balance.granted > 0
                    ? "\(money(balance.toppedUp)) paid · \(money(balance.granted)) granted"
                    : nil,
                tint: balance.isAvailable ? nil : .critical
            ),
            phaseTile,
            UsageStatMetric(
                id: "spent-today", label: "spent today · observed",
                value: money(spentToday),
                subtitle: partialToday
                    ? ledger.trackingSince.map { "since \(clock($0, now: now, calendar: calendar))" }
                    : "from balance changes"
            ),
            UsageStatMetric(id: "spent-week", label: "last 7 days · observed",
                            value: money(weekTotal), subtitle: nil),
        ]

        let pillTint: UsageTint = !balance.isAvailable ? .critical : (phase == .peak ? .warn : .ok)
        return ProviderUsageSnapshot(
            provider: .deepseek,
            stats: stats,
            todayCost: spentToday,
            lifetimeCost: ledger.totalSpent,
            dailySeries: week.map { DailyUsagePoint(date: $0.date, tokens: 0, cost: $0.spent) },
            chartTitle: "spent · observed",
            chartOnDetailPage: true,
            sessionsTitle: "top-ups · observed",
            sessions: ledger.topUps.reversed().prefix(3).map { topUp in
                UsageSessionMetric(id: "topup-\(topUp.date.timeIntervalSince1970)",
                                   name: "top-up · \(day(topUp.date, calendar: calendar))",
                                   cost: topUp.amount, tokens: nil, last: topUp.date)
            },
            source: "api.deepseek.com",
            fetchedAt: now,
            statusMessage: balance.isAvailable ? nil : "Balance too low for API calls",
            pill: UsagePill(text: Fmt.compactMoney(balance.total, currency: currency), tint: pillTint),
            currency: currency,
            spendObservedAt: ledger.lastSpendAt
        )
    }

    /// "14:00" today, "Mon 09:00" on another day — in the Mac's own time zone.
    static func clock(_ date: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }

    private static func day(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
