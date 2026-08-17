import Foundation

/// Antigravity usage, from two sources that fail independently.
///
/// Quota comes from the CLI's own `/usage` command. That command is answered by the CLI itself
/// rather than by the model — documented as emitting "a structured payload under
/// `--output-format json` … without starting an agent turn, spending quota, or leaving a
/// conversation behind" — so polling it is free. Consumption comes from the local conversation
/// stores. When the quota call fails (offline, signed out, no CLI) the local half still renders.
actor AntigravityUsageProvider {
    private let store = AntigravityLocalStore()
    /// A signed-out or erroring CLI would otherwise be relaunched every single poll. Local stores
    /// are still read while this is in effect, so the panel keeps its chart, tiles and sessions.
    private var cliBackoffUntil: Date?
    private let cliBackoff: TimeInterval = 600
    /// The CLI call blocks on a subprocess for seconds at a time and the store blocks on SQLite,
    /// so neither may run on the cooperative pool where actors live.
    private static let queue = DispatchQueue(label: "antigravity-usage", qos: .utility)

    /// `force` (Refresh now) clears the CLI backoff so a user who has just signed in doesn't
    /// have to wait it out.
    func fetch(force: Bool = false) async -> ProviderUsageSnapshot {
        if force { cliBackoffUntil = nil }
        let skipCLI = (cliBackoffUntil.map { $0 > Date() } ?? false)
        let store = store
        let snapshot: ProviderUsageSnapshot = await withCheckedContinuation { continuation in
            Self.queue.async {
                let quota = skipCLI ? nil : Result { try AntigravityCLI.usage() }
                let stats = store.scan()
                continuation.resume(returning: AntigravitySnapshotMapper.make(
                    quota: quota.flatMap { try? $0.get() },
                    quotaError: quota?.failureMessage,
                    stats: stats,
                    activeModel: AntigravityPaths.activeModel(),
                    now: Date()
                ))
            }
        }
        if !skipCLI {
            cliBackoffUntil = snapshot.limits.isEmpty ? Date().addingTimeInterval(cliBackoff) : nil
        }
        return snapshot
    }
}

private extension Result {
    var failureMessage: String? {
        guard case .failure(let error) = self else { return nil }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - CLI

enum AntigravityCLI {
    private static let maximumOutputBytes = 8 * 1_024 * 1_024
    /// Backstop for a CLI that outlives its own `--print-timeout`. The provider funnels every
    /// poll through one queue, so a single wedged `agy` would otherwise stall it for good.
    static let timeout: TimeInterval = 45

    /// Runs `agy -p /usage --output-format json` and returns the decoded quota payload.
    static func usage() throws -> AntigravityUsageResponse {
        guard let executable = AntigravityPaths.executable() else {
            throw AntigravityProviderError.executableNotFound
        }
        // Fixed arguments, launched directly — never via a shell.
        let data = try capture(
            executable: executable,
            arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "30s"],
            timeout: timeout
        )
        return try validate(data)
    }

    /// Runs a process to completion and returns its stdout, killing it if it outlives `timeout`
    /// or overruns the output cap. Always reaps, so a killed CLI leaves nothing behind.
    static func capture(executable: URL, arguments: [String],
                        timeout: TimeInterval) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AntigravityProviderError.launchFailed
        }

        let running = RunningProcess(process)
        let watchdog = DispatchWorkItem { running.timeOut() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                       execute: watchdog)
        defer { watchdog.cancel() }

        var data = Data()
        var overran = false
        while let chunk = try? output.fileHandleForReading.read(upToCount: 64 * 1_024),
              !chunk.isEmpty {
            data.append(chunk)
            if data.count > maximumOutputBytes {
                overran = true
                running.stop()
                break
            }
        }
        // Killing the process closes the pipe, so the loop above ends either way and this only
        // collects the exit status.
        process.waitUntilExit()

        if overran { throw AntigravityProviderError.responseTooLarge }
        if running.timedOut { throw AntigravityProviderError.timedOut }
        return data
    }

    /// Decodes a `/usage` payload, rejecting anything that isn't a real quota answer.
    ///
    /// The structured `command` envelope is the whole point of the check. Older CLIs did not
    /// answer `/usage` in print mode and let it fall through as literal prompt text, so the
    /// *model* replied with plausible-looking prose and no real numbers. Requiring the envelope
    /// makes that case read as unavailable rather than as invented quota.
    static func validate(_ data: Data) throws -> AntigravityUsageResponse {
        let response: AntigravityUsageResponse
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            response = try decoder.decode(AntigravityUsageResponse.self, from: data)
        } catch {
            throw AntigravityProviderError.unreadableResponse
        }

        guard response.command?.name == "usage",
              let groups = response.command?.data?.groups, !groups.isEmpty else {
            if response.status == "ERROR" { throw AntigravityProviderError.requestFailed }
            throw AntigravityProviderError.unsupportedCLI
        }
        guard response.status == "SUCCESS" else {
            throw AntigravityProviderError.requestFailed
        }
        return response
    }
}

/// A launched process, terminable from the watchdog thread.
///
/// `Process` is not Sendable, but raising a signal at one is safe from any thread and that is all
/// this does. The SIGTERM-then-SIGKILL escalation mirrors the Codex provider's cleanup.
private final class RunningProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var expired = false

    init(_ process: Process) { self.process = process }

    /// True when the watchdog, rather than the output cap, ended the run.
    var timedOut: Bool { lock.withLock { expired } }

    func timeOut() {
        lock.withLock { expired = true }
        stop()
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        // Give SIGTERM ~1.5s to land before insisting.
        for _ in 0..<15 where process.isRunning { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

enum AntigravityProviderError: LocalizedError {
    case executableNotFound
    case launchFailed
    case responseTooLarge
    case timedOut
    case unreadableResponse
    case unsupportedCLI
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "Antigravity CLI not found"
        case .launchFailed: "Antigravity CLI could not be launched"
        case .responseTooLarge: "Antigravity CLI response was too large"
        case .timedOut: "Antigravity CLI timed out"
        case .unreadableResponse: "Antigravity usage response not recognized"
        case .unsupportedCLI: "Antigravity CLI is too old for /usage"
        // Deliberately generic: the CLI's own error text embeds internal endpoint URLs.
        case .requestFailed: "Antigravity quota unavailable"
        }
    }
}

// MARK: - Wire model

struct AntigravityUsageResponse: Decodable, Sendable {
    struct Bucket: Decodable, Sendable {
        let id: String?
        let name: String?
        let window: String?
        /// 1 = untouched, 0 = exhausted.
        let remainingFraction: Double?
        let resetTime: String?
    }

    struct Group: Decodable, Sendable {
        let name: String?
        let description: String?
        let buckets: [Bucket]?
    }

    struct Command: Decodable, Sendable {
        struct Payload: Decodable, Sendable {
            let groups: [Group]?
        }
        let name: String?
        let data: Payload?
    }

    let status: String?
    let command: Command?
}

// MARK: - Mapping

enum AntigravitySnapshotMapper {
    static func make(
        quota: AntigravityUsageResponse?,
        quotaError: String?,
        stats: AntigravityLocalStats,
        activeModel: String?,
        now: Date
    ) -> ProviderUsageSnapshot {
        let groups = quota?.command?.data?.groups ?? []
        let ordered = order(groups, preferring: activeModel)
        let limits = makeLimits(ordered)
        let series = weekSeries(stats, now: now)
        let todayTokens = stats.isEmpty ? nil : stats.tokens(on: now)

        var stat: [UsageStatMetric] = []
        if let todayTokens {
            stat.append(.init(id: "tokens-today", label: "tokens today · local",
                              value: Fmt.tokens(todayTokens),
                              subtitle: turnsToday(stats, now: now).map { "\($0) turns" }))
        }
        if let activeModel {
            stat.append(.init(id: "model", label: "model", value: activeModel, subtitle: nil))
        }
        if !stats.isEmpty {
            stat.append(.init(id: "tokens-lifetime", label: "tokens · all-time",
                              value: Fmt.tokens(stats.totalTokens),
                              subtitle: "\(stats.totalTurns) turns"))
        }
        if let top = stats.topModel {
            stat.append(.init(id: "top-model", label: "most used",
                              value: shortModel(top),
                              subtitle: "\(stats.turnsByModel[top] ?? 0) turns"))
        }
        if stats.thinkingTokens > 0 {
            stat.append(.init(id: "thinking", label: "thinking · all-time",
                              value: Fmt.tokens(stats.thinkingTokens), subtitle: nil))
        }

        let sessions = stats.conversations
            .filter { $0.last > .distantPast }
            .prefix(3)
            .map {
                UsageSessionMetric(id: $0.id, name: $0.workspace ?? "Antigravity session",
                                   cost: nil, tokens: $0.tokens, last: $0.last)
            }

        var message: String?
        if limits.isEmpty {
            // Say why the rings are blank; without this the panel just looks broken.
            message = quotaError ?? "Antigravity quota unavailable"
        }

        return ProviderUsageSnapshot(
            provider: .antigravity,
            limits: limits,
            stats: stat,
            todayTokens: todayTokens,
            lifetimeTokens: stats.isEmpty ? nil : stats.totalTokens,
            dailySeries: series,
            chartTitle: "last 7 days · local",
            // Four quota rings already fill the limits page, so the chart lives on the detail
            // page as it does for Claude.
            chartOnDetailPage: true,
            sessionsTitle: "recent conversations",
            sessions: Array(sessions),
            alternateSessionsTitle: "all-time · top projects",
            alternateSessions: topProjects(stats),
            source: "agy CLI",
            fetchedAt: limits.isEmpty ? nil : now,
            statusMessage: message
        )
    }

    // MARK: limits

    /// Groups in display order, leading with the one that owns the model currently selected.
    ///
    /// The first limit becomes the collapsed pill's headline, and Antigravity meters Gemini and
    /// the third-party models separately — so someone working in Claude models should not see a
    /// Gemini number on the notch.
    private static func order(
        _ groups: [AntigravityUsageResponse.Group],
        preferring activeModel: String?
    ) -> [AntigravityUsageResponse.Group] {
        guard let family = activeModel?
            .split(separator: " ").first?
            .lowercased(), !family.isEmpty else { return groups }
        guard let index = groups.firstIndex(where: { group in
            let haystack = ((group.name ?? "") + " " + (group.description ?? "")).lowercased()
            return haystack.contains(family)
        }) else { return groups }
        var ordered = groups
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    private static func makeLimits(
        _ groups: [AntigravityUsageResponse.Group]
    ) -> [UsageLimitMetric] {
        let usesPrefix = groups.count > 1
        return groups.enumerated().flatMap { index, group -> [UsageLimitMetric] in
            let prefix = shortGroup(group.name)
            let buckets = (group.buckets ?? []).sorted {
                windowOrder($0.window) < windowOrder($1.window)
            }
            return buckets.enumerated().compactMap { position, bucket in
                guard let remaining = bucket.remainingFraction else { return nil }
                let window = windowLabel(bucket.window, fallback: bucket.name)
                return UsageLimitMetric(
                    id: bucket.id ?? "antigravity-\(index)-\(position)",
                    label: usesPrefix ? "\(prefix) · \(window)" : window,
                    usedFraction: 1 - remaining,
                    resetsAt: bucket.resetTime.flatMap(date(fromISO8601:))
                )
            }
        }
    }

    /// "Gemini Models" → "Gemini", "Claude and GPT models" → "Claude/GPT". Tile labels are
    /// narrow, and the word "models" is the same on every one of them.
    private static func shortGroup(_ name: String?) -> String {
        guard var name, !name.isEmpty else { return "Antigravity" }
        for suffix in [" models", " Models"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.replacingOccurrences(of: " and ", with: "/")
    }

    private static func windowOrder(_ window: String?) -> Int {
        switch window?.lowercased() {
        case "5h": 0
        case "daily": 1
        case "weekly": 2
        case "monthly": 3
        default: 4
        }
    }

    private static func windowLabel(_ window: String?, fallback: String?) -> String {
        switch window?.lowercased() {
        case "5h": "5-Hour"
        case "daily": "Daily"
        case "weekly": "Weekly"
        case "monthly": "Monthly"
        default: fallback?
            .replacingOccurrences(of: " Limit Remaining", with: "") ?? "Limit"
        }
    }

    private static func date(fromISO8601 raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    // MARK: local stats

    private static func turnsToday(_ stats: AntigravityLocalStats, now: Date) -> Int? {
        let start = Calendar.current.startOfDay(for: now)
        let turns = stats.conversations
            .filter { $0.last >= start }
            .reduce(0) { $0 + $1.turns }
        return turns > 0 ? turns : nil
    }

    /// The last seven calendar days, oldest first, zero-filled.
    private static func weekSeries(_ stats: AntigravityLocalStats, now: Date) -> [DailyUsagePoint] {
        guard !stats.isEmpty else { return [] }
        let calendar = Calendar.current
        return (0..<7).reversed().compactMap { back in
            guard let raw = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
            let day = calendar.startOfDay(for: raw)
            return DailyUsagePoint(date: day, tokens: stats.tokensByDay[day] ?? 0)
        }
    }

    /// Lifetime tokens per project folder, biggest first.
    private static func topProjects(_ stats: AntigravityLocalStats) -> [UsageSessionMetric] {
        var byWorkspace: [String: (tokens: Int, last: Date)] = [:]
        for conversation in stats.conversations {
            guard let workspace = conversation.workspace else { continue }
            let existing = byWorkspace[workspace] ?? (0, .distantPast)
            byWorkspace[workspace] = (existing.tokens + conversation.tokens,
                                      max(existing.last, conversation.last))
        }
        return byWorkspace
            .sorted { $0.value.tokens > $1.value.tokens }
            .prefix(3)
            .map { UsageSessionMetric(id: $0.key, name: $0.key, cost: nil,
                                      tokens: $0.value.tokens, last: $0.value.last) }
    }

    /// "gemini-3.7-flash" → "Gemini 3.7 Flash", so the tile matches how the CLI names models.
    private static func shortModel(_ raw: String) -> String {
        raw.split(separator: "-")
            .map { $0.first?.isNumber == true ? String($0) : $0.capitalized }
            .joined(separator: " ")
    }
}
