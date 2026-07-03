# Claude Notch Usage Tracker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu-bar agent that shows a notch "Dynamic Island" with Clawd on the left and the live 5-hour Claude rate-limit block on the right, expanding on click to show tokens/cost/session/model — all from local `~/.claude` logs.

**Architecture:** Pure data core (parse JSONL → dedup → 5-hour blocks → cost) is unit-tested with fixtures. An FSEvents watcher feeds an `@Observable` `AppModel`. AppKit hosts a borderless non-activating `NSPanel` under the notch rendering SwiftUI; a menu-bar `NSStatusItem` owns lifecycle. The app runs as an accessory (`setActivationPolicy(.accessory)`), so a bare SwiftPM executable needs no Info.plist.

**Tech Stack:** Swift 6, SwiftPM executable, SwiftUI + AppKit, Swift Testing, FSEvents.

**Spec:** `docs/superpowers/specs/2026-07-03-claude-notch-usage-tracker-design.md`

> **Toolchain note (required for tests):** `swift test` needs the full Xcode
> toolchain, not CommandLineTools. Prefix every test command with
> `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
> `swift build` works under either toolchain.

---

## File Structure

```
Package.swift
Sources/ClaudeNotch/
  App.swift                     # @main, activation policy, AppDelegate, wiring
  Model/
    UsageEvent.swift            # one billable assistant message
    Block.swift                 # a 5-hour rate-limit block
    UsageSnapshot.swift         # everything the UI needs to render
  Core/
    LogParser.swift             # one JSONL file -> [UsageEvent]
    BlockCalculator.swift       # [UsageEvent] -> [Block] + active block
    PricingTable.swift          # UsageEvent -> USD estimate
    UsageStore.swift            # aggregate all files -> UsageSnapshot
    LogWatcher.swift            # FSEvents on ~/.claude/projects (debounced)
    ClaudePaths.swift           # resolve ~/.claude/projects
  System/
    AppMonitor.swift            # Claude.app running? + notch geometry
    IslandWindow.swift          # borderless NSPanel + positioning
    StatusItemController.swift  # menu-bar item + menu actions
  UI/
    AppModel.swift              # @Observable root state
    IslandView.swift            # switches collapsed <-> expanded
    CollapsedView.swift         # avatar + time + ring
    ExpandedView.swift          # ring + 2x2 metric grid + buttons
    Ring.swift                  # the fill ring (Shape)
    AvatarStyle.swift           # enum + selection persistence
    AvatarView.swift            # renders Clawd / spark / custom, animated
    SettingsView.swift          # avatar picker + prefs
Tests/ClaudeNotchTests/
  Fixtures/                     # tiny handwritten .jsonl files
  LogParserTests.swift
  BlockCalculatorTests.swift
  PricingTableTests.swift
  UsageStoreTests.swift
```

---

## Task 0: Package scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/ClaudeNotch/App.swift`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS("14.0")],
    targets: [
        .executableTarget(
            name: "ClaudeNotch",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClaudeNotchTests",
            dependencies: ["ClaudeNotch"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 2: Write a minimal `App.swift` so the target compiles**

```swift
import Foundation

@main
struct Main {
    static func main() {
        print("ClaudeNotch starting")
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources
git commit -m "chore: scaffold ClaudeNotch SwiftPM executable"
```

---

## Task 1: UsageEvent + LogParser (TDD)

**Files:**
- Create: `Sources/ClaudeNotch/Model/UsageEvent.swift`
- Create: `Sources/ClaudeNotch/Core/LogParser.swift`
- Create: `Tests/ClaudeNotchTests/Fixtures/basic.jsonl`
- Create: `Tests/ClaudeNotchTests/LogParserTests.swift`

- [ ] **Step 1: Write the fixture `basic.jsonl`** (3 lines: one assistant with usage, one synthetic to skip, one user line to skip)

```
{"type":"assistant","timestamp":"2026-07-03T19:31:34.147Z","sessionId":"s1","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":10,"cache_read_input_tokens":200}}}
{"type":"assistant","timestamp":"2026-07-03T19:31:35.000Z","sessionId":"s1","requestId":"r2","message":{"id":"m2","model":"<synthetic>","usage":{"input_tokens":5,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"type":"user","timestamp":"2026-07-03T19:31:36.000Z","sessionId":"s1","message":{"role":"user","content":"hi"}}
```

- [ ] **Step 2: Write the failing test**

```swift
import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct LogParserTests {
    func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
    }

    @Test func parsesOnlyBillableAssistantLines() throws {
        let events = try LogParser.parse(fileURL: fixtureURL("basic"))
        #expect(events.count == 1)                 // synthetic + user skipped
        let e = try #require(events.first)
        #expect(e.sessionId == "s1")
        #expect(e.requestId == "r1")
        #expect(e.messageId == "m1")
        #expect(e.model == "claude-opus-4-8")
        #expect(e.inputTokens == 100)
        #expect(e.outputTokens == 50)
        #expect(e.cacheCreationTokens == 10)
        #expect(e.cacheReadTokens == 200)
        #expect(e.totalTokens == 360)
    }

    @Test func parsesFractionalIso8601Timestamp() throws {
        let events = try LogParser.parse(fileURL: fixtureURL("basic"))
        let e = try #require(events.first)
        // 2026-07-03T19:31:34.147Z
        #expect(abs(e.timestamp.timeIntervalSince1970 - 1783107094.147) < 0.01)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter LogParserTests`
Expected: FAIL — `LogParser` / `UsageEvent` not defined.

- [ ] **Step 4: Write `UsageEvent.swift`**

```swift
import Foundation

struct UsageEvent: Equatable, Sendable {
    let timestamp: Date
    let sessionId: String
    let requestId: String?
    let messageId: String?
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    /// Stable identity for cross-file dedup of retried/duplicated messages.
    var dedupeKey: String {
        (messageId ?? "?") + ":" + (requestId ?? "?")
    }
}
```

- [ ] **Step 5: Write `LogParser.swift`**

```swift
import Foundation

enum LogParser {
    private struct Line: Decodable {
        let type: String?
        let timestamp: Date?
        let sessionId: String?
        let requestId: String?
        let message: Message?
    }
    private struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }
    private struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = fmt.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath,
                debugDescription: "bad date \(s)"))
        }
        return d
    }()

    /// Parse one JSONL file into billable events. Malformed lines are skipped.
    static func parse(fileURL: URL) throws -> [UsageEvent] {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        var out: [UsageEvent] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = raw.data(using: .utf8),
                  let line = try? decoder.decode(Line.self, from: data)
            else { continue }
            guard line.type == "assistant",
                  let msg = line.message,
                  let usage = msg.usage,
                  let model = msg.model, model != "<synthetic>",
                  let ts = line.timestamp,
                  let sid = line.sessionId
            else { continue }
            out.append(UsageEvent(
                timestamp: ts,
                sessionId: sid,
                requestId: line.requestId,
                messageId: msg.id,
                model: model,
                inputTokens: usage.input_tokens ?? 0,
                outputTokens: usage.output_tokens ?? 0,
                cacheCreationTokens: usage.cache_creation_input_tokens ?? 0,
                cacheReadTokens: usage.cache_read_input_tokens ?? 0))
        }
        return out
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter LogParserTests`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeNotch/Model/UsageEvent.swift Sources/ClaudeNotch/Core/LogParser.swift Tests
git commit -m "feat: parse ~/.claude JSONL into billable UsageEvents"
```

---

## Task 2: Block + BlockCalculator (TDD)

**Files:**
- Create: `Sources/ClaudeNotch/Model/Block.swift`
- Create: `Sources/ClaudeNotch/Core/BlockCalculator.swift`
- Create: `Tests/ClaudeNotchTests/BlockCalculatorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct BlockCalculatorTests {
    func event(_ iso: String, tokens: Int = 10, session: String = "s1") -> UsageEvent {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return UsageEvent(timestamp: f.date(from: iso)!, sessionId: session,
            requestId: nil, messageId: nil, model: "claude-opus-4-8",
            inputTokens: tokens, outputTokens: 0, cacheCreationTokens: 0,
            cacheReadTokens: 0)
    }

    @Test func splitsBlocksOnFiveHourGap() {
        let events = [
            event("2026-07-03T10:05:00Z"),
            event("2026-07-03T11:00:00Z"),   // same block
            event("2026-07-03T18:00:00Z"),   // >5h after last -> new block
        ]
        let blocks = BlockCalculator.blocks(from: events)
        #expect(blocks.count == 2)
        // first block floored to the hour of the first event
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        #expect(blocks[0].start == f.date(from: "2026-07-03T10:00:00Z"))
        #expect(blocks[0].end == f.date(from: "2026-07-03T15:00:00Z"))
        #expect(blocks[0].totalTokens == 20)
        #expect(blocks[1].start == f.date(from: "2026-07-03T18:00:00Z"))
    }

    @Test func activeBlockReportsRemainingAndFraction() {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let events = [event("2026-07-03T10:05:00Z")]           // block 10:00–15:00
        let now = f.date(from: "2026-07-03T12:00:00Z")!        // 2h elapsed of 5h
        let active = BlockCalculator.activeBlock(from: events, now: now)
        let block = try? #require(active)
        #expect(block != nil)
        #expect(abs(block!.remaining(at: now) - 3*3600) < 1)   // 3h left
        #expect(abs(block!.fractionElapsed(at: now) - 0.4) < 0.001)
    }

    @Test func noActiveBlockWhenIdlePastWindow() {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let events = [event("2026-07-03T10:05:00Z")]           // ends 15:00
        let now = f.date(from: "2026-07-03T16:00:00Z")!
        #expect(BlockCalculator.activeBlock(from: events, now: now) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BlockCalculatorTests`
Expected: FAIL — `Block` / `BlockCalculator` not defined.

- [ ] **Step 3: Write `Block.swift`**

```swift
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
```

- [ ] **Step 4: Write `BlockCalculator.swift`**

```swift
import Foundation

enum BlockCalculator {
    /// Group account-wide events into rolling 5-hour blocks (ccusage model).
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

    /// The block whose 5-hour window contains `now`, if any.
    static func activeBlock(from events: [UsageEvent], now: Date) -> Block? {
        blocks(from: events).last.flatMap { $0.contains(now) ? $0 : nil }
    }

    static func floorToHour(_ date: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        return cal.date(from: cal.dateComponents(
            [.year, .month, .day, .hour], from: date)) ?? date
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter BlockCalculatorTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeNotch/Model/Block.swift Sources/ClaudeNotch/Core/BlockCalculator.swift Tests/ClaudeNotchTests/BlockCalculatorTests.swift
git commit -m "feat: compute 5-hour rate-limit blocks and active block"
```

---

## Task 3: PricingTable (TDD)

**Files:**
- Create: `Sources/ClaudeNotch/Core/PricingTable.swift`
- Create: `Tests/ClaudeNotchTests/PricingTableTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct PricingTableTests {
    func event(model: String) -> UsageEvent {
        UsageEvent(timestamp: .init(), sessionId: "s", requestId: nil, messageId: nil,
            model: model, inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheCreationTokens: 0, cacheReadTokens: 0)
    }

    @Test func opusCostMatchesRates() {
        // 1M input @ $15 + 1M output @ $75 = $90
        let cost = PricingTable.cost(for: event(model: "claude-opus-4-8"))
        #expect(abs(cost - 90.0) < 0.0001)
    }

    @Test func unknownModelFallsBackNonZero() {
        #expect(PricingTable.cost(for: event(model: "mystery-model")) > 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PricingTableTests`
Expected: FAIL — `PricingTable` not defined.

- [ ] **Step 3: Write `PricingTable.swift`**

```swift
import Foundation

/// USD per 1M tokens. Estimates for display only; tune as needed.
enum PricingTable {
    struct Rate { let input, output, cacheWrite, cacheRead: Double }

    static let rates: [(match: String, rate: Rate)] = [
        ("opus",   Rate(input: 15,   output: 75, cacheWrite: 18.75, cacheRead: 1.5)),
        ("sonnet", Rate(input: 3,    output: 15, cacheWrite: 3.75,  cacheRead: 0.30)),
        ("haiku",  Rate(input: 0.80, output: 4,  cacheWrite: 1.0,   cacheRead: 0.08)),
    ]
    static let fallback = Rate(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30)

    static func rate(for model: String) -> Rate {
        let m = model.lowercased()
        return rates.first { m.contains($0.match) }?.rate ?? fallback
    }

    static func cost(for e: UsageEvent) -> Double {
        let r = rate(for: e.model)
        return (Double(e.inputTokens) * r.input
              + Double(e.outputTokens) * r.output
              + Double(e.cacheCreationTokens) * r.cacheWrite
              + Double(e.cacheReadTokens) * r.cacheRead) / 1_000_000
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PricingTableTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeNotch/Core/PricingTable.swift Tests/ClaudeNotchTests/PricingTableTests.swift
git commit -m "feat: per-model token cost estimates"
```

---

## Task 4: UsageSnapshot + UsageStore (TDD)

**Files:**
- Create: `Sources/ClaudeNotch/Model/UsageSnapshot.swift`
- Create: `Sources/ClaudeNotch/Core/UsageStore.swift`
- Create: `Tests/ClaudeNotchTests/Fixtures/dedup.jsonl`
- Create: `Tests/ClaudeNotchTests/UsageStoreTests.swift`

- [ ] **Step 1: Write fixture `dedup.jsonl`** (same message twice by dedupeKey; a second model)

```
{"type":"assistant","timestamp":"2026-07-03T10:00:00.000Z","sessionId":"s1","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"type":"assistant","timestamp":"2026-07-03T10:00:00.000Z","sessionId":"s1","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"type":"assistant","timestamp":"2026-07-03T10:01:00.000Z","sessionId":"s2","requestId":"r2","message":{"id":"m2","model":"claude-haiku-4-5","usage":{"input_tokens":500000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
```

- [ ] **Step 2: Write the failing test**

```swift
import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct UsageStoreTests {
    func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
    }

    @Test func dedupesAndAggregates() throws {
        let store = UsageStore()
        try store.ingest(fileURL: fixtureURL("dedup"))
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let now = f.date(from: "2026-07-03T10:30:00Z")!
        let snap = store.snapshot(now: now)
        // m1 counted once (1M) + m2 (0.5M) = 1.5M tokens
        #expect(snap.tokensToday == 1_500_000)
        // opus 1M input = $15 ; haiku 0.5M input @ $0.80 = $0.40 ; total ~ $15.40
        #expect(abs(snap.costToday - 15.40) < 0.0001)
        #expect(snap.topModel == "claude-opus-4-8")     // most tokens
        #expect(snap.blockRemaining != nil)             // block 10:00–15:00 active
        #expect(!snap.isEmpty)
    }

    @Test func emptyStoreIsEmptySnapshot() {
        let snap = UsageStore().snapshot(now: Date())
        #expect(snap.isEmpty)
        #expect(snap.tokensToday == 0)
        #expect(snap.blockRemaining == nil)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter UsageStoreTests`
Expected: FAIL — `UsageStore` / `UsageSnapshot` not defined.

- [ ] **Step 4: Write `UsageSnapshot.swift`**

```swift
import Foundation

enum RingState { case ok, warn, critical }

struct UsageSnapshot: Equatable, Sendable {
    var blockRemaining: TimeInterval?    // nil when no active block
    var blockFractionElapsed: Double     // 0...1
    var blockEnd: Date?
    var tokensToday: Int
    var costToday: Double
    var activeSessionTokens: Int
    var topModel: String?

    var isEmpty: Bool { tokensToday == 0 && blockRemaining == nil }

    var ringState: RingState {
        switch blockFractionElapsed {
        case ..<0.66: return .ok
        case ..<0.85: return .warn
        default:      return .critical
        }
    }

    static let empty = UsageSnapshot(blockRemaining: nil, blockFractionElapsed: 0,
        blockEnd: nil, tokensToday: 0, costToday: 0, activeSessionTokens: 0,
        topModel: nil)
}
```

- [ ] **Step 5: Write `UsageStore.swift`**

```swift
import Foundation

/// Aggregates parsed events from every log file into a render-ready snapshot.
final class UsageStore {
    private var eventsByFile: [URL: [UsageEvent]] = [:]

    func ingest(fileURL: URL) throws {
        eventsByFile[fileURL] = try LogParser.parse(fileURL: fileURL)
    }

    func remove(fileURL: URL) { eventsByFile[fileURL] = nil }

    /// All events, cross-file deduped, ascending by time.
    private func allEvents() -> [UsageEvent] {
        var seen = Set<String>()
        var out: [UsageEvent] = []
        for e in eventsByFile.values.flatMap({ $0 })
            .sorted(by: { $0.timestamp < $1.timestamp }) {
            if seen.insert(e.dedupeKey).inserted { out.append(e) }
        }
        return out
    }

    func snapshot(now: Date) -> UsageSnapshot {
        let events = allEvents()
        guard !events.isEmpty else { return .empty }

        let cal = Calendar.current
        let today = events.filter { cal.isDate($0.timestamp, inSameDayAs: now) }

        let tokensToday = today.reduce(0) { $0 + $1.totalTokens }
        let costToday = today.reduce(0) { $0 + PricingTable.cost(for: $1) }

        var byModel: [String: Int] = [:]
        for e in today { byModel[e.model, default: 0] += e.totalTokens }
        let topModel = byModel.max { $0.value < $1.value }?.key

        let activeSession = events.last?.sessionId
        let activeSessionTokens = today
            .filter { $0.sessionId == activeSession }
            .reduce(0) { $0 + $1.totalTokens }

        let active = BlockCalculator.activeBlock(from: events, now: now)

        return UsageSnapshot(
            blockRemaining: active?.remaining(at: now),
            blockFractionElapsed: active?.fractionElapsed(at: now) ?? 0,
            blockEnd: active?.end,
            tokensToday: tokensToday,
            costToday: costToday,
            activeSessionTokens: activeSessionTokens,
            topModel: topModel)
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter UsageStoreTests`
Expected: PASS (2 tests).

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS (all 9 tests across the 4 suites).

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeNotch/Model/UsageSnapshot.swift Sources/ClaudeNotch/Core/UsageStore.swift Tests
git commit -m "feat: aggregate events into a render-ready UsageSnapshot"
```

---

## Task 5: ClaudePaths + LogWatcher (manual verify)

**Files:**
- Create: `Sources/ClaudeNotch/Core/ClaudePaths.swift`
- Create: `Sources/ClaudeNotch/Core/LogWatcher.swift`

FSEvents can't be meaningfully unit-tested here; verify by touching a file and seeing a callback.

- [ ] **Step 1: Write `ClaudePaths.swift`**

```swift
import Foundation

enum ClaudePaths {
    static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static func allLogFiles() -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: projectsDir,
            includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }
}
```

- [ ] **Step 2: Write `LogWatcher.swift`** (FSEvents, debounced, main-actor callback)

```swift
import Foundation

/// Watches ~/.claude/projects recursively and reports changed .jsonl paths.
final class LogWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor ([URL]) -> Void
    private var pending = Set<URL>()
    private var debounce: DispatchWorkItem?

    init(onChange: @escaping @MainActor ([URL]) -> Void) { self.onChange = onChange }

    func start() {
        let path = ClaudePaths.projectsDir.path as CFString
        var ctx = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes)   // so eventPaths is a CFArray
        guard let s = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = unsafeBitCast(paths, to: NSArray.self) as! [String]
            watcher.handle(cPaths)
        }, &ctx, [path] as CFArray,
           FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    private func handle(_ paths: [String]) {
        let urls = paths.filter { $0.hasSuffix(".jsonl") }.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        pending.formUnion(urls)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = Array(self.pending); self.pending.removeAll()
            Task { @MainActor in self.onChange(batch) }
        }
        debounce?.cancel(); debounce = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
```

- [ ] **Step 3: Temporarily wire a smoke test into `App.swift`**

```swift
import Foundation

@main
struct Main {
    static func main() {
        let store = UsageStore()
        for f in ClaudePaths.allLogFiles() { try? store.ingest(fileURL: f) }
        print("initial:", store.snapshot(now: Date()))
        let watcher = LogWatcher { urls in
            for u in urls { try? store.ingest(fileURL: u) }
            print("update:", store.snapshot(now: Date()))
        }
        watcher.start()
        RunLoop.main.run()
    }
}
```

- [ ] **Step 4: Run and verify**

Run: `swift run ClaudeNotch` (in another Claude Code session, send a message to generate log activity)
Expected: prints an `initial:` snapshot with non-zero `tokensToday`, then `update:` lines as logs change. Ctrl-C to stop.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeNotch/Core/ClaudePaths.swift Sources/ClaudeNotch/Core/LogWatcher.swift Sources/ClaudeNotch/App.swift
git commit -m "feat: FSEvents log watcher feeding live snapshots"
```

---

## Task 6: AppModel (@Observable root state) — background parsing

**Files:**
- Create: `Sources/ClaudeNotch/Core/LogLoader.swift`
- Create: `Sources/ClaudeNotch/UI/AppModel.swift`
- Modify: `Sources/ClaudeNotch/Core/ClaudePaths.swift` (add `recentLogFiles(within:)`)
- Modify: `Sources/ClaudeNotch/Core/UsageStore.swift` (add `ingest(fileURL:events:)`)

**Why this shape:** parsing all of `~/.claude` is ~280 MB / ~12 s on a real machine —
doing it synchronously on `@MainActor` would freeze the island at launch. So: parse
off the main actor in a small `actor`, and only scan **recently-modified** files for
the live snapshot (the 5-hour block and "today" only need recent events; full history
is a future History view). `UsageEvent` is `Sendable`, so parsed results cross back
to the main actor safely.

- [ ] **Step 1: Add `recentLogFiles(within:)` to `ClaudePaths.swift`**

Append this method inside `enum ClaudePaths`:

```swift
    /// Log files modified within the last `days` days (cheap stat, no parse).
    /// Falls back to all files if none are recent.
    static func recentLogFiles(within days: Int) -> [URL] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let all = allLogFiles()
        let recent = all.filter { url in
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return (d ?? .distantPast) >= cutoff
        }
        return recent.isEmpty ? all : recent
    }
```

- [ ] **Step 2: Add a pre-parsed ingest to `UsageStore.swift`**

Add this method to `UsageStore` (keep the existing `ingest(fileURL:)` for tests):

```swift
    /// Store already-parsed events for a file (used when parsing happened off-main).
    func ingest(fileURL: URL, events: [UsageEvent]) {
        eventsByFile[fileURL] = events
    }
```

- [ ] **Step 3: Write `LogLoader.swift`** (background parse actor)

```swift
import Foundation

/// Parses log files off the main actor. UsageEvent is Sendable, so the
/// returned tuples cross back to the caller's actor safely.
actor LogLoader {
    func parse(_ files: [URL]) -> [(url: URL, events: [UsageEvent])] {
        files.compactMap { url in
            guard let events = try? LogParser.parse(fileURL: url) else { return nil }
            return (url, events)
        }
    }
}
```

- [ ] **Step 4: Write `AppModel.swift`**

```swift
import Foundation
import SwiftUI

@MainActor @Observable
final class AppModel {
    private(set) var snapshot: UsageSnapshot = .empty
    var isExpanded = false
    var isPaused = false
    var claudeRunning = false

    private let store = UsageStore()
    private let loader = LogLoader()
    private var watcher: LogWatcher?
    private var ticker: Timer?

    func start() {
        watcher = LogWatcher { [weak self] urls in
            guard let self, !self.isPaused else { return }
            Task { await self.ingest(urls) }
        }
        watcher?.start()
        // Re-tick each minute so "remaining" and ring stay current without new logs.
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Initial load: only recent files, parsed off-main so launch never blocks.
        Task { await ingest(ClaudePaths.recentLogFiles(within: 2)) }
    }

    func togglePause() { isPaused.toggle(); if !isPaused { refresh() } }

    private func ingest(_ files: [URL]) async {
        let parsed = await loader.parse(files)      // runs on LogLoader actor (off main)
        for item in parsed { store.ingest(fileURL: item.url, events: item.events) }
        refresh()
    }

    func refresh() { snapshot = store.snapshot(now: Date()) }
}
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!` (no concurrency errors — `UsageEvent`/tuples are Sendable).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeNotch/Core/LogLoader.swift Sources/ClaudeNotch/UI/AppModel.swift Sources/ClaudeNotch/Core/ClaudePaths.swift Sources/ClaudeNotch/Core/UsageStore.swift
git commit -m "feat: @Observable AppModel with off-main parsing and recent-file scan"
```

---

## Task 7: Ring + AvatarStyle + AvatarView

**Files:**
- Create: `Sources/ClaudeNotch/UI/Ring.swift`
- Create: `Sources/ClaudeNotch/UI/AvatarStyle.swift`
- Create: `Sources/ClaudeNotch/UI/AvatarView.swift`

- [ ] **Step 1: Write `Ring.swift`**

```swift
import SwiftUI

struct Ring: View {
    var fraction: Double            // 0...1 elapsed
    var state: RingState
    var lineWidth: CGFloat = 4

    private var color: Color {
        switch state {
        case .ok: return Color(red: 0.36, green: 0.79, blue: 0.65)   // teal
        case .warn: return Color(red: 0.94, green: 0.62, blue: 0.15)  // amber
        case .critical: return Color(red: 0.89, green: 0.29, blue: 0.29) // red
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(color, style: .init(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: fraction)
        }
    }
}
```

- [ ] **Step 2: Write `AvatarStyle.swift`** (choosable, persisted)

```swift
import SwiftUI

enum AvatarStyle: String, CaseIterable, Identifiable {
    case clawd, spark, custom
    var id: String { rawValue }
    var label: String {
        switch self { case .clawd: "Clawd"; case .spark: "Spark mark"; case .custom: "Custom image" }
    }

    private static let key = "avatarStyle"
    private static let customKey = "avatarCustomPath"

    static var selected: AvatarStyle {
        get { AvatarStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .clawd }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
    static var customImagePath: String? {
        get { UserDefaults.standard.string(forKey: customKey) }
        set { UserDefaults.standard.set(newValue, forKey: customKey) }
    }
}
```

- [ ] **Step 3: Write `AvatarView.swift`** (renders selection; animates when active)

Clawd art is a placeholder shape until the real asset is dropped into resources. `active` drives a subtle wiggle.

```swift
import SwiftUI

struct AvatarView: View {
    var style: AvatarStyle
    var active: Bool
    @State private var wiggle = false

    var body: some View {
        Group {
            switch style {
            case .clawd:  clawd
            case .spark:  spark
            case .custom: custom
            }
        }
        .frame(width: 24, height: 24)
        .rotationEffect(.degrees(active && wiggle ? 6 : -6))
        .animation(active ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                          : .default, value: wiggle)
        .onAppear { wiggle = active }
        .onChange(of: active) { _, now in wiggle = now }
    }

    // Placeholder Clawd: rounded clay body with two eyes. Swap for real asset.
    private var clawd: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.85, green: 0.47, blue: 0.34))
            HStack(spacing: 4) {
                Circle().fill(.white).frame(width: 4, height: 4)
                Circle().fill(.white).frame(width: 4, height: 4)
            }.offset(y: -1)
        }
    }

    private var spark: some View {
        Image(systemName: "sparkle")
            .resizable().scaledToFit()
            .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
    }

    private var custom: some View {
        Group {
            if let p = AvatarStyle.customImagePath, let img = NSImage(contentsOfFile: p) {
                Image(nsImage: img).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else { clawd }
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeNotch/UI/Ring.swift Sources/ClaudeNotch/UI/AvatarStyle.swift Sources/ClaudeNotch/UI/AvatarView.swift
git commit -m "feat: fill ring + choosable animated avatar (Clawd/spark/custom)"
```

---

## Task 8: CollapsedView + ExpandedView + IslandView

**Files:**
- Create: `Sources/ClaudeNotch/UI/CollapsedView.swift`
- Create: `Sources/ClaudeNotch/UI/ExpandedView.swift`
- Create: `Sources/ClaudeNotch/UI/IslandView.swift`

- [ ] **Step 1: Write a shared formatter in `CollapsedView.swift`**

```swift
import SwiftUI

enum Fmt {
    static func hm(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
}

struct CollapsedView: View {
    let model: AppModel   // passed-in @Observable — plain property, NOT @State

    var body: some View {
        HStack {
            AvatarView(style: AvatarStyle.selected, active: !model.isPaused)
                .onTapGesture { NotificationCenter.default.post(name: .clawdTapped, object: nil) }
            Spacer(minLength: 60)   // gap over the physical notch
            HStack(spacing: 8) {
                Text(model.snapshot.blockRemaining.map(Fmt.hm) ?? "—")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white)
                Ring(fraction: model.snapshot.blockFractionElapsed,
                     state: model.snapshot.ringState)
                    .frame(width: 20, height: 20)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.isExpanded = true }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

extension Notification.Name { static let clawdTapped = Notification.Name("clawdTapped") }
```

- [ ] **Step 2: Write `ExpandedView.swift`**

```swift
import SwiftUI

struct ExpandedView: View {
    let model: AppModel   // passed-in @Observable — plain property, NOT @State

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AvatarView(style: AvatarStyle.selected, active: !model.isPaused)
                Text("Usage").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                Spacer()
                if let end = model.snapshot.blockEnd {
                    Text("resets \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
            HStack(spacing: 14) {
                Ring(fraction: model.snapshot.blockFractionElapsed,
                     state: model.snapshot.ringState, lineWidth: 3.5)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.snapshot.blockRemaining.map { Fmt.hm($0) + " left" } ?? "No active block")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    Text("in current 5-hour block")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }
            .padding(12).background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            let s = model.snapshot
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                metric("tokens today", Fmt.tokens(s.tokensToday))
                metric("est. cost today", Fmt.usd(s.costToday))
                metric("active session", Fmt.tokens(s.activeSessionTokens))
                metric("top model", s.topModel ?? "—")
            }
            HStack(spacing: 8) {
                pill("History") { NotificationCenter.default.post(name: .openHistory, object: nil) }
                pill("Settings") { NotificationCenter.default.post(name: .openSettings, object: nil) }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Color(white: 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: 16, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

extension Notification.Name {
    static let openHistory = Notification.Name("openHistory")
    static let openSettings = Notification.Name("openSettings")
}
```

- [ ] **Step 3: Write `IslandView.swift`**

```swift
import SwiftUI

struct IslandView: View {
    let model: AppModel   // passed-in @Observable — plain property, NOT @State

    var body: some View {
        Group {
            if model.isExpanded {
                ExpandedView(model: model)
                    .onExitCommand { model.isExpanded = false }
            } else {
                CollapsedView(model: model)
                    .background(Color.black)
                    .clipShape(.rect(bottomLeadingRadius: 20, bottomTrailingRadius: 20))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.isExpanded)
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeNotch/UI/CollapsedView.swift Sources/ClaudeNotch/UI/ExpandedView.swift Sources/ClaudeNotch/UI/IslandView.swift
git commit -m "feat: collapsed + expanded island SwiftUI views"
```

---

## Task 9: AppMonitor (Claude.app + notch geometry)

**Files:**
- Create: `Sources/ClaudeNotch/System/AppMonitor.swift`

- [ ] **Step 1: Discover Claude.app's bundle id**

Run: `mdls -name kMDItemCFBundleIdentifier /Applications/Claude.app`
Expected: a value like `com.anthropic.claudefordesktop`. Record it for Step 2's `claudeBundleIDs` list; if it differs, add it.

- [ ] **Step 2: Write `AppMonitor.swift`**

```swift
import AppKit

@MainActor @Observable
final class AppMonitor {
    var claudeRunning = false
    /// Notch metrics for the main screen. width==0 => no notch (use pill fallback).
    private(set) var notchWidth: CGFloat = 0
    private(set) var notchHeight: CGFloat = 0

    private let claudeBundleIDs = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        updateNotch()
        updateClaude()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateClaude() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateNotch(); self?.onChange?() }
        }
    }

    private func updateClaude() {
        let running = NSWorkspace.shared.runningApplications.contains {
            guard let id = $0.bundleIdentifier?.lowercased() else { return false }
            return claudeBundleIDs.contains(id) || id.contains("claude")
        }
        if running != claudeRunning { claudeRunning = running; onChange?() }
    }

    private func updateNotch() {
        guard let screen = NSScreen.main else { return }
        notchHeight = screen.safeAreaInsets.top
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        } else {
            notchWidth = 0
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeNotch/System/AppMonitor.swift
git commit -m "feat: detect Claude.app running + notch geometry"
```

---

## Task 10: IslandWindow (borderless NSPanel + positioning)

**Files:**
- Create: `Sources/ClaudeNotch/System/IslandWindow.swift`

- [ ] **Step 1: Write `IslandWindow.swift`**

```swift
import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats at notch level.
final class IslandWindow {
    let panel: NSPanel
    private let hosting: NSHostingView<IslandView>

    init(model: AppModel) {
        hosting = NSHostingView(rootView: IslandView(model: model))
        panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 420, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        panel.ignoresMouseEvents = false
    }

    /// Size the panel to its SwiftUI content and pin it centered at the top.
    func reposition(notchWidth: CGFloat) {
        let fitting = hosting.fittingSize
        let width = max(fitting.width, notchWidth > 0 ? notchWidth + 200 : 320)
        let height = fitting.height
        panel.setContentSize(.init(width: width, height: height))
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height     // flush to the top edge
        panel.setFrameOrigin(.init(x: x, y: y))
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeNotch/System/IslandWindow.swift
git commit -m "feat: borderless non-activating island panel at notch level"
```

---

## Task 11: StatusItemController + SettingsView + App wiring (manual verify)

**Files:**
- Create: `Sources/ClaudeNotch/System/StatusItemController.swift`
- Create: `Sources/ClaudeNotch/UI/SettingsView.swift`
- Modify: `Sources/ClaudeNotch/App.swift` (replace the Task 5 smoke test)

- [ ] **Step 1: Write `SettingsView.swift`** (avatar picker)

```swift
import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var style = AvatarStyle.selected

    var body: some View {
        Form {
            Picker("Avatar", selection: $style) {
                ForEach(AvatarStyle.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: style) { _, new in
                AvatarStyle.selected = new
                if new == .custom { pickImage() }
                NotificationCenter.default.post(name: .avatarChanged, object: nil)
            }
            AvatarView(style: style, active: true).frame(width: 40, height: 40)
        }
        .padding(20).frame(width: 320, height: 160)
    }

    private func pickImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .image]
        if p.runModal() == .OK, let url = p.url {
            AvatarStyle.customImagePath = url.path
            NotificationCenter.default.post(name: .avatarChanged, object: nil)
        }
    }
}

extension Notification.Name { static let avatarChanged = Notification.Name("avatarChanged") }
```

- [ ] **Step 2: Write `StatusItemController.swift`**

```swift
import AppKit
import SwiftUI

@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let model: AppModel
    private var settingsWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.medium",
            accessibilityDescription: "Claude usage")
        rebuildMenu()
        NotificationCenter.default.addObserver(forName: .openSettings, object: nil,
            queue: .main) { [weak self] _ in Task { @MainActor in self?.openSettings() } }
        NotificationCenter.default.addObserver(forName: .clawdTapped, object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor in self?.item.button?.performClick(nil) } }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let pause = NSMenuItem(title: model.isPaused ? "Resume tracking" : "Pause tracking",
            action: #selector(togglePause), keyEquivalent: "")
        pause.target = self; menu.addItem(pause)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings),
            keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
    }

    @objc private func togglePause() { model.togglePause(); rebuildMenu() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 160),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Claude Notch"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center(); w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 3: Replace `App.swift` with the real entry point**

```swift
import AppKit
import SwiftUI

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let monitor = AppMonitor()
    var window: IslandWindow!
    var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ note: Notification) {
        model.start()
        window = IslandWindow(model: model)
        statusItem = StatusItemController(model: model)

        monitor.start { [weak self] in self?.sync() }

        // Re-position/re-show as the snapshot changes size (expand/collapse).
        withObservationTracking { _ = model.isExpanded } onChange: { [weak self] in
            Task { @MainActor in self?.window.reposition(notchWidth: self?.monitor.notchWidth ?? 0) }
        }
        NotificationCenter.default.addObserver(forName: .avatarChanged, object: nil,
            queue: .main) { [weak self] _ in Task { @MainActor in
                self?.window.reposition(notchWidth: self?.monitor.notchWidth ?? 0) } }

        sync()
    }

    private func sync() {
        model.claudeRunning = monitor.claudeRunning
        window.reposition(notchWidth: monitor.notchWidth)
        if monitor.claudeRunning { window.show() } else { window.hide() }
    }
}
```

> Note: `withObservationTracking` fires once; the reposition-on-expand is refreshed
> by `sync()` and the avatar/screen observers for v1. If expand/collapse resizing
> needs to be continuous, wrap the tracking in a re-arming helper in a later polish
> pass — not required for the milestone.

- [ ] **Step 4: Build and run**

Run: `swift build && swift run ClaudeNotch`
Expected: a gauge icon appears in the menu bar; with Claude.app running, the black island appears under the notch showing Clawd + time + ring. Clicking the ring expands the panel; clicking Clawd opens the status menu; Settings lets you switch avatar. Quit from the menu.

- [ ] **Step 5: Verify the no-notch path**

On a Mac/display without a notch (or via an external display as the main screen), confirm the island renders as a top-center pill and still shows/hides with Claude.app.

- [ ] **Step 6: Full regression**

Run: `swift test`
Expected: all core tests still PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeNotch/System/StatusItemController.swift Sources/ClaudeNotch/UI/SettingsView.swift Sources/ClaudeNotch/App.swift
git commit -m "feat: menu-bar agent, settings avatar picker, lifecycle wiring"
```

---

## Task 12: Polish pass

**Files:**
- Modify: `Sources/ClaudeNotch/UI/IslandView.swift`
- Modify: `Sources/ClaudeNotch/UI/CollapsedView.swift`

- [ ] **Step 1: Add hover-to-preview widening**

In `CollapsedView`, add the state and modifiers to the root `HStack`:

```swift
@State private var hovering = false
// ...on the root HStack, after .frame(height: 38):
.padding(.horizontal, hovering ? 22 : 14)
.onHover { hovering = $0 }
.animation(.easeOut(duration: 0.2), value: hovering)
```

(Remove the existing `.padding(.horizontal, 14)` so it isn't applied twice.)

- [ ] **Step 2: Dismiss expanded panel on outside click**

In `AppDelegate`, when `model.isExpanded` becomes true, install a local `NSEvent` monitor for `.leftMouseDown` outside `window.panel.frame` that sets `model.isExpanded = false`; remove it on collapse.

```swift
private var clickMonitor: Any?
private func watchOutsideClick() {
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
        Task { @MainActor in self?.model.isExpanded = false }
    }
}
```

- [ ] **Step 3: Empty state**

In `ExpandedView.body`, wrap the metric grid so an empty snapshot shows guidance instead:

```swift
if model.snapshot.isEmpty {
    Text("No usage yet — start a Claude session")
        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
} else {
    // ...existing LazyVGrid metric grid...
}
```

- [ ] **Step 4: Build, run, eyeball**

Run: `swift run ClaudeNotch`
Expected: hover widens the pill; clicking away closes the panel; a fresh account shows the empty state.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeNotch/UI
git commit -m "polish: hover preview, outside-click dismiss, empty state"
```

---

## Done criteria

- `swift test` passes (LogParser, BlockCalculator, PricingTable, UsageStore).
- `swift run ClaudeNotch` shows the notch island while Claude.app runs, with a live
  5-hour block (time + color ring), Clawd on the left (animated, choosable), and an
  expanded panel with tokens/cost/session/model.
- Menu-bar agent with Pause / Settings (avatar picker) / Quit.
- No-notch displays fall back to a top-center pill.
- claude.ai account fetch remains out of scope (v2, per the spec).
```
