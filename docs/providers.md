# Provider Architecture

Claude Notch supports Claude, Codex and Antigravity through a shared `ProviderUsageSnapshot`
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

## Antigravity

The Antigravity provider draws on two independent sources, so one failing does not blank the panel.

**Quota** comes from the CLI's own read-only slash command:

```
agy -p "/usage" --output-format json --print-timeout 30s
```

The CLI answers this itself rather than routing it to a model — the official changelog describes
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

## Refresh and Switching

Click the left icon to cycle between Claude, Codex and Antigravity, or select a provider from the
context menu. The selection is persisted. Only the active provider is polled, and switching
triggers an immediate refresh.

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
