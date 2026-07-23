# Provider Architecture

Claude Notch supports Claude and Codex through a shared `ProviderUsageSnapshot` model. The UI only
renders normalized limits, statistics, recent activity, plan metadata, and status information;
each provider owns its data acquisition and mapping logic.

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

## Refresh and Switching

Click the left icon to switch between Claude and Codex, or select a provider from the context menu.
The selection is persisted. Only the active provider is polled, and switching triggers an immediate
refresh.

## Security and Privacy Boundaries

- Provider reads are read-only. Claude Notch does not persist login tokens, browser cookies,
  prompts, or account responses in application storage.
- Codex responses are capped at 8 MiB, and raw app-server stderr or RPC error details are not shown
  in the notch.
- Raw Codex prompt previews and account email addresses are neither decoded for display nor retained
  by the provider model. Recent activity falls back to the local project folder name.
- Claude browser-cookie queries match only `claude.ai` and `.claude.ai`; temporary SQLite copies use
  owner-only permissions and are deleted after each read.
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
