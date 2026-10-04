# Provider Architecture

Claude Notch supports Claude, Codex, Antigravity, DeepSeek, opencode-go and Ollama Cloud through a shared `ProviderUsageSnapshot`
model. The UI only renders normalized limits, statistics, recent activity, plan metadata, and
status information; each provider owns its data acquisition and mapping logic.

## Claude

The Claude provider keeps the existing behavior:

- reads account limits from a signed-in Claude Desktop, supported browser, or Claude Code session;
- computes local token, cost, and session totals from Claude Code logs;
- shows 5-hour, 7-day, Fable, and projected cost metrics.

## Codex

The Codex provider uses the official local `codex app-server` JSON-RPC interface:

- `account/read` returns the login type and plan;
- `account/rateLimits/read` returns dynamic limit windows, reset times, and credits;
- `account/usage/read` returns account-level daily buckets (rendered as the 7-day chart) and
  lifetime token totals;
- `thread/list` returns recent task metadata.

The app does not parse private `~/.codex/sessions` JSONL files and does not estimate Codex dollar
costs. Account-level token totals require ChatGPT authentication; API-key-only sessions may still
return rate limits but the official interface does not provide account usage totals.

The executable is discovered in this order:

1. the explicit `CODEX_NOTCH_BINARY` path;
2. the binary bundled with the ChatGPT or Codex app;
3. common Homebrew locations;
4. the inherited `PATH`.

Only configure `CODEX_NOTCH_BINARY` with a trusted executable. The app launches the selected binary
with fixed `app-server --stdio` arguments and never invokes a shell.

## opencode-go

opencode-go reads the server's own meters first, with local history as the fallback:

- **Web (preferred).** The `opencode.ai` browser session cookie is read from the local cookie
  store (same mechanism as the Claude provider) and used for `GET /console/api/orgs` (workspace
  ID), then `GET /console/api/go/status` with `x-org-id` (5-hour / weekly / monthly meters plus
  `endsAt` renewals) and `GET /console/api/billing/status` (prepaid Zen balance). With
  `OPENCODE_API_KEY` set, `GET /zen/go/v1/usage` is used instead. The provider is offered once
  `~/.local/share/opencode/auth.json` carries a key or `opencode.db` history exists (file
  checks only, never the Keychain). A failed round trip keeps the last server reading for up to
  an hour (dimmed by its age); after that, or when no browser session or key works at all
  (offline-at-launch, 403, no subscription), the card re-reads local history on every poll. With
  `OPENCODE_API_KEY` set, a transient API error keeps the last API reading, and a 401 shows
  "opencode API key rejected".
- **Local.** `~/.local/share/opencode/opencode.db` (`session_message`, falling back to the older
  `message`/`part` tables) is read for per-turn costs, bucketed into rolling 5-hour, UTC-week
  and calendar-month windows. Plan limits are hardcoded, so these are estimates.

The snapshot's source label says where the numbers came from: `opencode.ai` (browser session),
`API` (`OPENCODE_API_KEY`) or `local estimate` (local history). The 7-day chart is always built
from local spend (the server payload has no daily buckets), so its title says `· local`.

## Antigravity

The Antigravity provider draws on two independent sources, so one failing does not blank the panel.

**Quota** comes from the CLI's own read-only slash command:

```
agy -p "/usage" --output-format json --print-timeout 30s
```

The CLI answers this itself rather than routing it to a model. The official changelog describes
the read-only print-mode commands as emitting "a structured payload under `--output-format json`
… without starting an agent turn, spending quota, or leaving a conversation behind." Polling it
therefore costs nothing. Each group (Gemini, and Claude/GPT) reports a 5-hour and a weekly bucket
as a `remaining_fraction` plus a reset time, which map directly onto `UsageLimitMetric`.

Two things the provider is strict about:

- It requires the structured `command.name == "usage"` envelope. An older CLI let `/usage` fall
  through as literal prompt text, so the *model* answered with plausible prose and invented
  numbers; requiring the envelope makes that read as unavailable instead.
- It keys off the payload's `status` field, never the exit code, which is `0` even on failure.
  The CLI's own error text embeds internal endpoint URLs and is never surfaced in the notch.

Output is capped at 8 MiB, and a CLI that outlives its own `--print-timeout` is terminated by a
45-second watchdog (SIGTERM, then SIGKILL). Every poll shares one queue, so a wedged `agy` would
otherwise stall the provider indefinitely rather than for a single tick.

**Consumption** is read from the local conversation stores under `~/.gemini/antigravity-cli/` and
`~/.gemini/antigravity/`, which is what fills the 7-day chart, the stat tiles and the sessions
list. Quota says what is left; only these say what was spent, on which model, and in which
project. They are also readable offline, so the panel keeps its detail when the quota call fails.

Each conversation is a SQLite store whose `gen_metadata` rows hold protobuf-encoded per-turn
token counts. Antigravity publishes no schema for them, so the field mapping in
`AntigravityLocalStore` was read off the wire format and validated against a full local history:
`output == thinking + text` held for all 2,638 turns checked, which is what pins those fields to
their meanings. Rows that fail to decode are skipped rather than guessed at, so a schema change
costs accuracy and never a crash. Stores are cached by modification date, so a poll re-parses
only what changed.

The executable is discovered in this order:

1. the explicit `ANTIGRAVITY_NOTCH_BINARY` path;
2. `~/.local/bin/agy`;
3. common Homebrew locations;
4. the inherited `PATH`.

As with `CODEX_NOTCH_BINARY`, only configure this with a trusted executable. The app launches it
with fixed arguments and never invokes a shell.

The collapsed pill leads with the 5-hour bucket of whichever group owns the currently selected
model (read from the CLI's `settings.json`), so working in a Claude model does not put a Gemini
number on the notch. Quota is pool-level: all Gemini models share one allowance and Claude/GPT
share another, which is why the tiles name the group rather than a model.

## Availability

A provider is offered only when this Mac has something to show for it: Codex when the `codex`
executable is found, Antigravity when the `agy` executable or a local conversation store exists.
Detection is file existence only, so it never prompts for the Keychain and never launches a CLI,
and it is cached briefly because the collapsed pill re-renders constantly.

Clicking the island's icon cycles only detected providers, so the click can never land on a tool
that isn't installed. Every provider stays listed in the right-click Provider submenu, with
undetected ones marked, so the feature remains discoverable and can still be selected by hand.
Claude is always offered: it falls back to the terminal feed and log estimates on its own.

## Refresh and Switching

Click the left icon to cycle between the available providers, or select a provider from the
context menu. The selection is persisted. The provider on screen is polled, plus every available
provider while Rotation is on (see below); switching triggers an immediate refresh.

## Security and Privacy Boundaries

- Provider reads are read-only. Claude Notch does not persist login tokens, browser cookies,
  prompts, or account responses in application storage.
- Codex responses are capped at 8 MiB, and raw app-server stderr or RPC error details are not shown
  in the notch.
- Raw Codex prompt previews and account email addresses are neither decoded for display nor retained
  by the provider model. Recent activity falls back to the local project folder name.
- Claude browser-cookie queries match only `claude.ai` and `.claude.ai`; temporary SQLite copies use
  owner-only permissions and are deleted after each read.
- Antigravity stores are opened read-only and never written. Prompts, transcripts and artifacts
  are not read: the provider touches only the `gen_metadata` token counts and the workspace path
  in `trajectory_metadata_blob`. Account emails are neither decoded nor retained, and recent
  activity falls back to the local project folder name.
- Sparkle updates remain pinned to the upstream HTTPS appcast and verified with the upstream EdDSA
  public key.
- The app is not sandboxed because its core features require read-only access to browser session
  stores, Claude Code logs, and the locally installed Codex executable.

## DeepSeek

DeepSeek's API has a balance endpoint and nothing else about usage, so that is all the provider
asks for:

```
GET https://api.deepseek.com/user/balance   (Authorization: Bearer <key>)
```

- **The key** comes from `DEEPSEEK_API_KEY` in the app's environment, or from the right-click
  menu's *DeepSeek API Key…*, which stores it as a generic password in the login Keychain. It is
  read once per launch and sent nowhere but api.deepseek.com. The provider is offered only once a
  key exists, which `ProviderAvailability` learns from a flag rather than a Keychain read.
- **The wallet** shown is the funded one: an account can hold a CNY and a USD wallet, usually
  with one empty, and the first listed is not always the one with money in it.
- **Spend** is observed, not reported: `DeepSeekSpendLedger` counts each fall in the balance
  between readings as spend on the day it was seen, and each rise as a top-up, never netted
  against spend. The balance is only polled while DeepSeek is on screen, so a drop whose
  previous reading was on an earlier calendar day is booked on that earlier day, never on the
  day it was noticed: "spent today" does not swallow a weekend. Changing the API key clears the
  last balance and the ledger, so a second account is not read as a top-up or a spend. After a
  401 the Keychain is not read again until the key is changed.
- **Peak and off-peak** follow DeepSeek's published rule: 09:00–12:00 and 14:00–18:00 Beijing
  time, Monday to Friday, excluding Chinese statutory holidays. The holiday dates ship for the
  current year (`holiday-cn-<year>.json`) and are refreshed on the 28th of each month (Beijing time, or at the next launch if missed) from
  [holiday-cn](https://github.com/NateScarlet/holiday-cn) over jsDelivr, so a new year's
  arrangement arrives without a release. While a needed year is missing (the current one, or
  next year in December) the check runs daily instead, so the notice lands before New Year's Day. A year with no data falls back to the weekday rule.

DeepSeek has no limit window, so instead of a percent ring the pill shows the balance and a dot
for the phase: green off-peak, amber at peak, red when the balance is too low for API calls.

## Ollama Cloud

Ollama Cloud reports its plan limits and recent spend from one endpoint:

```
GET https://ollama.com/api/usage   (Authorization: Bearer <key>)
```

- **The key** comes from `OLLAMA_API_KEY` in the app's environment, or from the right-click
  menu's *Ollama API Key…*, which stores it in the login Keychain under its own item. As with
  DeepSeek it is read once, sent nowhere but ollama.com, and availability is known from a flag
  rather than a Keychain read. After a 401 the Keychain is not read again until the key is changed.
- **Limits**: `limits.session.usage` and `limits.weekly.usage` are used fractions of a 5-hour and
  a 7-day window, shown as two meters. The API gives no reset times, so the meters say
  "5-hour window" / "7-day window" where other providers count down, and draw no pace marker.
- **Credit plans.** Plans started from 2026-08-31 bill against a monthly credit pool instead.
  Zero limits are not taken as a sign of one, because a 5-hour/weekly plan unused this week
  reads 0 too: whenever the response has `limits.session` or `limits.weekly` the meters show,
  even at 0 %. Only a response with neither is treated as a credit plan: no meters, and the pill
  shows the last 4 weeks' spend.
- **Spend** is `activity.cost` (e.g. "$12.34"), shown as the "last 4 weeks" tile as Ollama
  formats it; it is parsed to a number only for the credit-plan pill.
- **Models**: the weekly per-model request counts, most requests first. Ollama has sent
  `models` both as an array of `{name, request_count}` and as an object keyed by model name;
  both are read.

Not available from the API: a credit balance or remaining credits, reset times, tokens, and
daily history, so there is no week chart.

## Rotation

*Rotate providers* in the right-click menu switches the island to the next available provider
every 10 s, 30 s or minute. While it is on, every available provider is polled in the
background (normally only the one on screen is), so a switch never lands on a stale or empty
card. Rotation holds while the card is open, and a provider picked by hand gets a full interval.
Rotated-to providers are not saved as the choice; the saved one is still what the user picked.

## Validation

Run the full test suite:

```bash
swift test
```

Run the opt-in live Codex integration test on a machine with an authenticated Codex installation:

```bash
CODEX_NOTCH_RUN_INTEGRATION_TEST=1 swift test --filter liveAppServerExchangeWhenRequested
```

Run the opt-in Antigravity integration test against this machine's real conversation history. It
reads local stores only and never invokes the CLI:

```bash
ANTIGRAVITY_NOTCH_RUN_INTEGRATION_TEST=1 swift test --filter liveLocalStoreWhenRequested
```
