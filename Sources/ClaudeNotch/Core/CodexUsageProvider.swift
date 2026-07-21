import Foundation

actor CodexUsageProvider {
    private let transport = CodexAppServerTransport()
    /// The transport blocks on pipe reads behind NSCondition waits (worst case ~20s of timeouts),
    /// so it runs on its own utility queue. It must never run on the cooperative pool — actors
    /// execute there, and blocking a cooperative thread starves every other task in the app.
    private static let transportQueue = DispatchQueue(label: "codex-app-server", qos: .utility)

    func fetch() async -> ProviderUsageSnapshot {
        let transport = transport
        return await withCheckedContinuation { continuation in
            Self.transportQueue.async {
                continuation.resume(returning: Self.snapshot(using: transport))
            }
        }
    }

    private static func snapshot(using transport: CodexAppServerTransport) -> ProviderUsageSnapshot {
        do {
            let exchange = try transport.fetch()
            let account = exchange.decode(CodexAccountResponse.self, id: 2)
            let rateLimits = exchange.decode(CodexRateLimitsResponse.self, id: 3)
            let usage = exchange.decode(CodexAccountUsageResponse.self, id: 4)
            let threads = exchange.decode(CodexThreadListResponse.self, id: 5)
            // A result that arrived but no longer decodes means the app-server's schema moved.
            // Surface that instead of silently dropping tiles, so a future Codex update shows a
            // status line rather than a mysteriously empty island.
            var errors = exchange.errors
            let decodes: [(Int, Any?, String)] = [
                (2, account, "account"), (3, rateLimits, "rate limits"),
                (4, usage, "usage"), (5, threads, "tasks"),
            ]
            for (id, decoded, name) in decodes where exchange.hasResult(id) && decoded == nil {
                errors[id] = "Codex \(name) response not recognized"
            }
            return CodexSnapshotMapper.make(
                account: account,
                rateLimits: rateLimits,
                usage: usage,
                threads: threads,
                errors: errors,
                now: Date()
            )
        } catch {
            return .unavailable(.codex, message: error.localizedDescription)
        }
    }
}

struct CodexAccountResponse: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let type: String
        let planType: String?
    }

    let account: Account?
    let requiresOpenaiAuth: Bool
}

struct CodexRateLimitsResponse: Decodable, Sendable {
    struct Credits: Decodable, Sendable {
        let balance: String?
        let hasCredits: Bool
        let unlimited: Bool
    }

    struct Window: Decodable, Sendable {
        let usedPercent: Int
        let windowDurationMins: Int?
        let resetsAt: Int?
    }

    struct Snapshot: Decodable, Sendable {
        let credits: Credits?
        let limitId: String?
        let limitName: String?
        let planType: String?
        let primary: Window?
        let secondary: Window?
    }

    let rateLimits: Snapshot
    let rateLimitsByLimitId: [String: Snapshot]?
}

struct CodexAccountUsageResponse: Decodable, Sendable {
    struct Summary: Decodable, Sendable {
        let lifetimeTokens: Int?
    }

    struct DailyBucket: Decodable, Sendable {
        let startDate: String
        let tokens: Int
    }

    let summary: Summary
    let dailyUsageBuckets: [DailyBucket]?
}

struct CodexThreadListResponse: Decodable, Sendable {
    struct Thread: Decodable, Sendable {
        let id: String
        let cwd: String
        let name: String?
        let updatedAt: Int
    }

    let data: [Thread]
}

enum CodexSnapshotMapper {
    static func make(
        account: CodexAccountResponse?,
        rateLimits: CodexRateLimitsResponse?,
        usage: CodexAccountUsageResponse?,
        threads: CodexThreadListResponse?,
        errors: [Int: String] = [:],
        now: Date
    ) -> ProviderUsageSnapshot {
        let limits = rateLimits.map(makeLimits) ?? []
        let todayTokens = usage.flatMap { usage in
            usage.dailyUsageBuckets?.first(where: { $0.startDate == dayString(now) })?.tokens
        }
        let lifetimeTokens = usage?.summary.lifetimeTokens
        let accountPlan = account?.account?.planType
        let ratePlan = rateLimits?.rateLimits.planType
        let planName = (accountPlan ?? ratePlan).map(planLabel)
        let credits = rateLimits.flatMap(creditsLabel)

        var stats: [UsageStatMetric] = []
        if let todayTokens {
            stats.append(.init(id: "tokens-today", label: "tokens today · account",
                               value: Fmt.tokens(todayTokens), subtitle: nil))
        }
        if let lifetimeTokens {
            stats.append(.init(id: "tokens-lifetime", label: "tokens · all-time",
                               value: Fmt.tokens(lifetimeTokens), subtitle: nil))
        }
        if let credits {
            stats.append(.init(id: "credits", label: "credits", value: credits, subtitle: nil))
        }
        if let planName {
            stats.append(.init(id: "plan", label: "plan", value: planName, subtitle: nil))
        }

        let sessions = threads?.data.prefix(3).map { thread in
            UsageSessionMetric(
                id: thread.id,
                name: threadName(thread),
                cost: nil,
                tokens: nil,
                last: Date(timeIntervalSince1970: TimeInterval(thread.updatedAt))
            )
        } ?? []

        var message: String?
        if account?.account?.type == "apiKey", usage == nil {
            message = "Account usage requires ChatGPT sign-in"
        } else if !errors.isEmpty, limits.isEmpty || usage == nil {
            // Surface the first problem whenever a whole section is missing — including partial
            // failures, where limits render but usage silently didn't (or vice versa).
            message = errors.sorted { $0.key < $1.key }.first?.value
        }

        return ProviderUsageSnapshot(
            provider: .codex,
            limits: limits,
            stats: stats,
            todayTokens: todayTokens,
            lifetimeTokens: lifetimeTokens,
            sessionsTitle: "recent tasks",
            sessions: sessions,
            planName: planName,
            source: "Codex app-server",
            fetchedAt: now,
            statusMessage: message
        )
    }

    private static func makeLimits(_ response: CodexRateLimitsResponse) -> [UsageLimitMetric] {
        let buckets: [(String, CodexRateLimitsResponse.Snapshot)]
        if let byID = response.rateLimitsByLimitId, !byID.isEmpty {
            buckets = byID.sorted { $0.key < $1.key }
        } else {
            buckets = [(response.rateLimits.limitId ?? "codex", response.rateLimits)]
        }

        let usesBucketPrefix = buckets.count > 1
        return buckets.flatMap { key, snapshot in
            let bucketName = snapshot.limitName ?? snapshot.limitId ?? key
            return [
                makeLimit(prefix: key, kind: "primary", window: snapshot.primary,
                          bucketName: bucketName, usesBucketPrefix: usesBucketPrefix),
                makeLimit(prefix: key, kind: "secondary", window: snapshot.secondary,
                          bucketName: bucketName, usesBucketPrefix: usesBucketPrefix),
            ].compactMap { $0 }
        }
    }

    private static func makeLimit(
        prefix: String,
        kind: String,
        window: CodexRateLimitsResponse.Window?,
        bucketName: String,
        usesBucketPrefix: Bool
    ) -> UsageLimitMetric? {
        guard let window else { return nil }
        let duration = durationLabel(window.windowDurationMins)
        let label = usesBucketPrefix ? "\(bucketName) · \(duration)" : duration
        return UsageLimitMetric(
            id: "\(prefix)-\(kind)",
            label: label,
            usedFraction: Double(window.usedPercent) / 100,
            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private static func durationLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "Limit" }
        return switch minutes {
        case 300: "5-Hour"
        case 10_080: "7-Day"
        case let value where value % 1_440 == 0: "\(value / 1_440)-Day"
        case let value where value % 60 == 0: "\(value / 60)-Hour"
        default: "\(minutes)-Min"
        }
    }

    private static func creditsLabel(_ response: CodexRateLimitsResponse) -> String? {
        let snapshots = [response.rateLimits] + (response.rateLimitsByLimitId?.values.map { $0 } ?? [])
        guard let credits = snapshots.compactMap(\.credits).first else { return nil }
        if credits.unlimited { return "unlimited" }
        if let balance = credits.balance, !balance.isEmpty { return balance }
        return credits.hasCredits ? "available" : "none"
    }

    private static func planLabel(_ raw: String) -> String {
        "Codex " + raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func threadName(_ thread: CodexThreadListResponse.Thread) -> String {
        if let name = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let folder = (thread.cwd as NSString).lastPathComponent
        return folder.isEmpty ? "Codex task" : folder
    }
}

private struct CodexRPCExchange: Sendable {
    let results: [Int: Data]
    let errors: [Int: String]

    func decode<T: Decodable>(_ type: T.Type, id: Int) -> T? {
        guard let data = results[id] else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func hasResult(_ id: Int) -> Bool { results[id] != nil }
}

private struct CodexAppServerTransport: Sendable {
    func fetch() throws -> CodexRPCExchange {
        let executable = try findExecutable()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let collector = CodexRPCCollector()

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        process.terminationHandler = { _ in collector.markProcessExited() }

        do {
            try process.run()
            try send([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "notch-usage-tracker",
                        "title": "Notch Usage Tracker",
                        "version": AppInfo.version,
                    ],
                    "capabilities": ["experimentalApi": true],
                ],
            ], to: input.fileHandleForWriting)
            try collector.wait(for: [1], timeout: 8)

            try send(["jsonrpc": "2.0", "method": "initialized", "params": [:]],
                     to: input.fileHandleForWriting)
            try sendRequest(id: 2, method: "account/read", params: ["refreshToken": false],
                            to: input.fileHandleForWriting)
            try sendRequest(id: 3, method: "account/rateLimits/read", params: [:],
                            to: input.fileHandleForWriting)
            try sendRequest(id: 4, method: "account/usage/read", params: [:],
                            to: input.fileHandleForWriting)
            try sendRequest(id: 5, method: "thread/list", params: [
                "limit": 10,
                "sortKey": "updated_at",
                "sortDirection": "desc",
            ], to: input.fileHandleForWriting)
            try collector.wait(for: [2, 3, 4, 5], timeout: 12)
        } catch {
            cleanup(process: process, input: input, output: output)
            if let providerError = error as? CodexProviderError { throw providerError }
            throw CodexProviderError.transport
        }

        cleanup(process: process, input: input, output: output)
        return collector.exchange
    }

    private func sendRequest(id: Int, method: String, params: [String: Any],
                             to handle: FileHandle) throws {
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params], to: handle)
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func cleanup(process: Process, input: Pipe, output: Pipe) {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        // Runs on the provider's dedicated queue, so a short bounded wait is fine: give SIGTERM
        // up to ~1.5s to land, then SIGKILL. A wedged app-server must never accumulate — this is
        // respawned on every poll.
        for _ in 0..<15 where process.isRunning { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func findExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["CODEX_NOTCH_BINARY"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates += [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CodexProviderError.executableNotFound
        }
        return URL(fileURLWithPath: path)
    }
}

private final class CodexRPCCollector: @unchecked Sendable {
    private static let maximumBufferedBytes = 8 * 1_024 * 1_024
    private let condition = NSCondition()
    private var buffer = Data()
    private var results: [Int: Data] = [:]
    private var errors: [Int: String] = [:]
    private var completedIDs = Set<Int>()
    private var processExited = false
    private var streamError: CodexProviderError?
    private var receivedBytes = 0

    func append(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !data.isEmpty else {
            processExited = true
            condition.broadcast()
            return
        }
        guard data.count <= Self.maximumBufferedBytes - receivedBytes else {
            streamError = .responseTooLarge
            buffer.removeAll(keepingCapacity: false)
            condition.broadcast()
            return
        }
        receivedBytes += data.count
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            consume(line)
        }
    }

    func markProcessExited() {
        condition.lock()
        processExited = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(for ids: Set<Int>, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !ids.isSubset(of: completedIDs), !processExited, streamError == nil {
            if !condition.wait(until: deadline) { break }
        }
        if let streamError { throw streamError }
        guard ids.isSubset(of: completedIDs) else {
            if processExited {
                throw CodexProviderError.transport
            }
            throw CodexProviderError.timeout
        }
    }

    var exchange: CodexRPCExchange {
        condition.lock()
        defer { condition.unlock() }
        return CodexRPCExchange(results: results, errors: errors)
    }

    private func consume(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              // Only RESPONSES complete our ids. Server-initiated requests carry both "id" and
              // "method" in their own id-space — one colliding with ours would otherwise record
              // an empty completion and silently blank that section.
              object["method"] == nil,
              let id = (object["id"] as? NSNumber)?.intValue else { return }
        if let result = object["result"], JSONSerialization.isValidJSONObject(result),
           let data = try? JSONSerialization.data(withJSONObject: result) {
            results[id] = data
        }
        if object["error"] is [String: Any] {
            errors[id] = "Codex request failed"
        }
        completedIDs.insert(id)
        condition.broadcast()
    }
}

private enum CodexProviderError: LocalizedError {
    case executableNotFound
    case timeout
    case responseTooLarge
    case transport

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex executable not found"
        case .timeout:
            "Codex app-server timed out"
        case .responseTooLarge:
            "Codex app-server response was too large"
        case .transport:
            "Codex app-server request failed"
        }
    }
}
