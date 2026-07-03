# Claude Usage Tracker — Notch "Dynamic Island" for macOS

**Date:** 2026-07-03
**Status:** Design approved (pending spec review)
**Target:** macOS 27, Xcode 26.6, Swift 6

## 1. Summary

A native macOS menu-bar agent that renders a "Dynamic Island"-style HUD anchored
under the MacBook notch. The **left** side shows **Clawd** (the Claude mascot) —
and the avatar is **user-selectable**; the **right** side shows the headline usage
metric — **time left in the current 5-hour rate-limit block** — with a
color-shifting fill ring. Clicking the
usage side expands a panel with tokens, cost, active session, and model split.
Clicking the Claude guy opens a quick menu (pause, history, settings, quit).

The island is **visible while Claude.app (Claude Desktop) is running** and hides
when it quits, but the underlying tracking agent runs continuously so no usage is
missed. All v1 data comes from **local `~/.claude` logs** — no login, no network,
never breaks. A future v2 adds an experimental, opt-in claude.ai account fetch.

Visual inspiration: boring.notch / pookify (notch-anchored, flat, dark HUD).

## 2. Goals / Non-goals

**Goals (v1)**
- Live 5-hour rate-limit block: time remaining, percent used, color state.
- At-a-glance collapsed island in the notch; rich expanded panel on click.
- Tokens today, estimated cost today, active-session usage, top model.
- Menu-bar agent lifecycle; show/hide island tied to Claude.app.
- Notch geometry detection with a floating-pill fallback for non-notch displays.
- Buildable and runnable from the terminal via `swift build` / `swift run`.

**Non-goals (v1)**
- claude.ai account/subscription usage fetch (deferred to v2, experimental).
- Historical charts beyond a simple recent-days list.
- Multi-machine sync, exports, notifications (candidate v2+).
- Distributable signed `.app` bundle (dev build first; packaging later).

## 3. Data source (confirmed)

Claude Code writes JSONL transcripts to `~/.claude/projects/<slug>/<sessionId>.jsonl`.
Verified on this machine: 86 files, real per-message usage.

Relevant fields per line:
- `timestamp` — ISO8601 UTC (e.g. `2026-07-03T19:31:34.147Z`)
- `message.usage` — `input_tokens`, `output_tokens`,
  `cache_creation_input_tokens`, `cache_read_input_tokens`, `server_tool_use`,
  `service_tier`
- `message.model` — e.g. `claude-opus-4-8`; also `<synthetic>` (exclude)
- `sessionId`, `requestId`, `cwd`, `gitBranch`, `type`, `version`

**Rules learned from the data:**
- Dedup by `requestId` (retries/streaming can repeat a message).
- Exclude `<synthetic>` model rows from cost (local synthetic messages).
- Timestamps are UTC → convert to local for "today" and reset-time display.

## 4. Rate-limit block model

Claude subscription usage is bucketed into rolling **5-hour blocks**. We replicate
ccusage's approach:
- A block **opens** at the first message timestamp after any ≥5-hour gap, floored
  to the hour.
- The block **spans 5 hours** from that open time; messages within it accumulate.
- **Active block** = the one whose 5-hour window contains "now".
- Headline = `remaining = blockEnd - now`; `percentUsed` = elapsed / 5h OR
  tokens-vs-typical-cap (v1 uses elapsed-time for the ring; token cap is a v2
  refinement once a reliable cap is known).

Ring color state by fraction elapsed: `< 0.66` teal, `0.66–0.85` amber, `> 0.85` red.

> Assumption: the 5-hour rolling window is the correct rate-limit unit for this
> account tier. If the real cap is token-based, the ring denominator becomes a
> config value in v2; the time-remaining display is correct regardless.

## 5. Architecture

Native SwiftUI + AppKit, single executable target (`ClaudeNotch`). Runs as an
accessory app (`NSApplication.setActivationPolicy(.accessory)` — LSUIElement
behavior without an Info.plist, so a bare SwiftPM executable works for dev).

### Components (each independently testable)

| Unit | Responsibility | Depends on |
|---|---|---|
| `LogParser` | Read one JSONL file → `[UsageEvent]`; dedup, skip synthetic | Foundation |
| `UsageStore` | Aggregate events across all files → today / session / blocks; incremental updates | `LogParser` |
| `BlockCalculator` | Group events into 5-hour blocks; compute active block + remaining/percent | pure |
| `PricingTable` | Per-model token→USD estimate (input/output/cache tiers) | static data |
| `LogWatcher` | FSEvents watch on `~/.claude/projects`; emit changed-file callbacks | Foundation |
| `AppMonitor` | Is Claude.app running? (NSWorkspace); notch geometry via `NSScreen.safeAreaInsets` | AppKit |
| `IslandWindow` | Borderless non-activating `NSPanel` pinned under notch (or top-center pill) | AppKit |
| `IslandView` | SwiftUI collapsed + expanded UI, animations, hover, click routing | SwiftUI |
| `AvatarView` | Renders selected `AvatarStyle` (Clawd / spark / custom) + idle/active states | SwiftUI |
| `Settings` | Avatar picker + prefs, persisted to UserDefaults | Foundation |
| `StatusItemController` | Menu-bar `NSStatusItem`; quit/pause/settings; owns lifecycle | AppKit |
| `AppModel` | `@Observable` root state; wires watcher → store → views | all above |

### Data flow

```
FSEvents (LogWatcher)
   -> changed file paths
   -> UsageStore.ingest(file)  [LogParser -> events -> merge]
   -> BlockCalculator + PricingTable recompute
   -> AppModel (@Observable) publishes snapshot
   -> IslandView re-renders (collapsed ring + expanded panel)

NSWorkspace (AppMonitor): Claude.app launched/terminated
   -> IslandWindow show/hide (agent keeps running regardless)
```

### Lifecycle
- Launch: build initial `UsageStore` by scanning all files once (bounded, async),
  start `LogWatcher`, install `StatusItemController`.
- Claude.app running → position + fade in `IslandWindow`. Not running → fade out.
- Pause tracking (menu) → stop watcher/UI updates; usage frozen until resumed.

## 6. UI behavior

**Collapsed island** (notch, ~38pt tall, black, bottom-rounded straddling notch):
- Left: **Clawd** in a rounded tile — the selected avatar (subtle pulse / small
  reaction while a session is live; e.g. a wiggle on new activity, calm when idle).
- Right: `2h 14m` (tabular) + fill ring (teal/amber/red).
- Hover: pill widens slightly to preview headline; no click needed.

**Avatar (choosable).** The left character is driven by an `AvatarStyle` chosen in
Settings and persisted (UserDefaults). v1 options:
- **Clawd** (default) — bundled mascot art, with idle/active animation states.
- **Spark mark** — the minimal Claude sunburst, for a quieter look.
- **Custom image** — user picks a PNG/SVG; scaled to the tile.

`AvatarStyle` is an enum + a small registry so more characters can be added later
without touching layout. Clawd art is bundled as an asset (user can supply the
exact asset; placeholder rendering used until then).

**Expanded panel** (click the usage side): dark rounded card above the notch with
the block ring + "Xh Ym left / in current 5-hour block", a 2×2 metric grid
(tokens today, est. cost today, active session, top model), and History / Settings
buttons. Dismiss on outside-click or Esc.

**Clawd click:** popover menu — Pause tracking, Open history, Settings
(incl. avatar picker), Quit.

**No-notch fallback:** if `safeAreaInsets.top == 0` (no notch / external display),
render the island as a floating rounded pill centered at the top of the active
screen. Same content, same interactions.

## 7. Error handling & edge cases

- Missing/empty `~/.claude/projects` → island shows "No usage yet" empty state.
- Malformed JSONL line → skip that line, continue (log at debug level).
- Very large files (32k+ lines seen) → parse line-streamed, off the main actor;
  incremental re-parse only the changed file, not the whole tree.
- Clock/timezone: store UTC, render local; recompute "today" at local midnight.
- Multiple displays / display reconfiguration → reposition on `NSScreen` change.
- FSEvents coalescing/bursts → debounce recompute (~250ms).

## 8. Testing strategy

- `LogParser`, `BlockCalculator`, `PricingTable`, `UsageStore` are pure/data units
  → Swift Testing unit tests with fixture JSONL (synthetic small files).
- Golden test: a fixture spanning a ≥5h gap yields exactly two blocks with the
  expected active block and remaining time (using injected "now").
- Dedup test: duplicate `requestId` counted once; `<synthetic>` excluded from cost.
- UI/positioning verified manually via `swift run` on the real notch (AppKit
  windowing isn't unit-tested); `AppMonitor` notch detection guarded behind a
  protocol so logic is testable with a fake screen.

## 9. Project layout (SwiftPM executable)

```
Package.swift                      # executable target ClaudeNotch, macOS 27, Swift 6
Sources/ClaudeNotch/
  App.swift                        # @main, activation policy, wiring
  Model/ UsageEvent.swift  UsageSnapshot.swift  Block.swift
  Core/  LogParser.swift  UsageStore.swift  BlockCalculator.swift
         PricingTable.swift  LogWatcher.swift
  System/ AppMonitor.swift  IslandWindow.swift  StatusItemController.swift
  UI/    IslandView.swift  CollapsedView.swift  ExpandedView.swift  Ring.swift
         AvatarView.swift  AvatarStyle.swift  SettingsView.swift
Tests/ClaudeNotchTests/            # Swift Testing + fixtures
docs/superpowers/specs/…           # this spec
```

Run: `swift run ClaudeNotch`. Build: `swift build`. Test: `swift test`.

## 10. Milestones (implementation order)

1. Package + models + `LogParser` + tests (parse fixtures, dedup, skip synthetic).
2. `BlockCalculator` + `UsageStore` + `PricingTable` + tests (blocks, today, cost).
3. `LogWatcher` (FSEvents) + `AppModel` wiring — headless: prints live snapshot.
4. `IslandWindow` + notch detection + collapsed `IslandView` (ring + time).
5. Expanded panel + click routing + hover; `AvatarView` + `AvatarStyle` (Clawd /
   spark / custom) + Settings avatar picker; `StatusItemController` + menu.
6. `AppMonitor` show/hide tied to Claude.app; no-notch fallback; polish/animation.

Each milestone builds and runs on its own; 1–3 are verifiable via `swift test`
and console output before any windowing exists.

## 11. Deferred to v2 (explicitly out of scope now)

- Experimental claude.ai account fetch: decrypt Claude Desktop's Chromium cookie
  (`~/Library/Application Support/Claude/Cookies`) using the "Claude Safe Storage"
  Keychain key, call the internal usage endpoint. Behind an opt-in toggle, clearly
  labeled experimental; gracefully no-ops if Cloudflare blocks it. App remains
  fully functional on local data if this fails.
- Token-based rate-limit cap for the ring denominator.
- Signed/notarized `.app` bundle + login-item install.
- Historical charts, notifications at thresholds.
