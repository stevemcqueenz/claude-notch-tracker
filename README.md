<div align="center">

# 🦀 Claude Notch

**Your live Claude usage — 5‑hour, 7‑day, Fable, cost — right in your Mac's notch.**

<img src="docs/page-limits.png" width="380" alt="Claude Notch expanded — 5-Hour, 7-Day, Fable weekly, and today's cost tiles" />

[![Latest release](https://img.shields.io/github/v/release/stevemcqueenz/claude-notch-tracker?color=CC785C&label=download)](https://github.com/stevemcqueenz/claude-notch-tracker/releases/latest)
&nbsp;![macOS 14+](https://img.shields.io/badge/macOS-14+-111111?logo=apple&logoColor=white)
&nbsp;[![License MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

<br/>

<a href="https://www.producthunt.com/products/mac-claude-notch-usage-tracker?embed=true&utm_source=badge-featured&utm_medium=badge&utm_campaign=badge-mac-claude-notch-usage-companion" target="_blank" rel="noopener noreferrer"><img src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1194655&theme=light" alt="Claude Notch on Product Hunt" width="250" height="54" /></a>

</div>

Collapsed, it's just **Clawd** (the crab) and your session % beside the camera. Click it and the
island glides open into a two‑page card you can **swipe** through — your real limits up front,
your spend and sessions behind. Click away and it glides shut. No Dock icon, no menu‑bar clutter.

## Screenshots

<table align="center">
<tr>
<td align="center" width="50%">
  <img src="docs/page-sessions.png" width="330" alt="Page 2 — today vs all-time spend and active sessions by conversation name" /><br/>
  <sub><b>Active sessions</b> — today's spend, per conversation</sub>
</td>
<td align="center" width="50%">
  <img src="docs/page-alltime.png" width="330" alt="Page 2 toggled to all-time — your biggest-spending projects ever" /><br/>
  <sub><b>All‑time top projects</b> — tap the ⇄ chip to switch</sub>
</td>
</tr>
</table>

## Features

- **Real limit tiles** — your **5‑hour** session, **7‑day** weekly, *and* **Fable's own
  weekly limit** (Fable is metered separately — the same three bars the Claude desktop app
  shows), each with a reset countdown and colour‑coded urgency.
- **Two pages, one swipe** — limits up front; swipe (or tap the dots) to a local‑detail page:
  today vs all‑time spend, and your live sessions.
- **Named sessions** — your actual **conversation titles** from the sidebar, with today's
  spend per conversation. Tap the block to flip to your **all‑time biggest projects**.
- **Cost, live** — cost & tokens today, an **"~$X by tonight"** projection, and all‑time
  totals from a full‑history scan of your logs.
- **Any Claude login works** — **Claude Desktop**, a **browser** signed into claude.ai, or the
  **Claude Code CLI** (terminal‑only, no desktop app or browser needed).
- **Clawd, the walking crab** — he quickens as you approach a limit and freezes when you're
  out. Prefer a mono crab or the Claude Spark? Click to swap.
- **Local‑first & private** — talks only to Anthropic with *your* session; nothing leaves your
  Mac. Local cost/token figures are clearly labelled `local`.
- **Zero fuss** — draws its own notch on non‑notch Macs, auto‑updates itself, and lives entirely
  on a right‑click menu.

## How it works

Claude Notch reads *your own* local Claude session — from **Claude Desktop**, a **browser
signed into claude.ai** (Chrome, Brave, Edge, Arc, Firefox, Zen), or the **Claude Code CLI** —
and calls the same usage endpoint the official apps use. It shows the exact limit bars the
desktop app does, **including Fable's separate weekly limit**.

For Desktop and browsers, the session cookie is read from the local cookie store (Chromium's is
decrypted with the OS Keychain "Safe Storage" key, the same mechanism the browsers use). For the
terminal, it reuses the Claude Code CLI's own login token from the Keychain — **read‑only, never
refreshed, so your CLI session is left untouched**. macOS asks your permission via a Keychain
prompt on first run.

> **Limits vs. local.** The 5‑hour / 7‑day / Fable tiles come from Anthropic and cover **all** your
> usage (including cloud/remote sessions). The `cost today` and `tokens today` figures are computed
> from your **local** `~/.claude` logs, so they're labelled `local` — cloud work counts toward the
> limit bars but not the local dollar figure.

## Requirements

- macOS 14+ (Apple Silicon or Intel)
- A signed‑in Claude session — **Claude Desktop**, a supported **browser** on claude.ai, or the
  **Claude Code CLI**

## Install

**Download:** grab the latest `Claude Notch.zip` from [Releases](../../releases) → unzip → drag
`Claude Notch.app` to Applications → **double‑click** to open (it's signed + **notarized**, so no
security warning). On first run, **Always Allow** the Keychain prompt so it can read your local
Claude session. Right‑click the island → *Launch at Login* to keep it around.

**Build from source:**

```bash
git clone https://github.com/stevemcqueenz/claude-notch-tracker
cd claude-notch-tracker
swift run ClaudeNotch        # dev run
bash scripts/make-app.sh     # builds dist/Claude Notch.app + a shareable zip
```

Requires a full Xcode toolchain (the SwiftUI macros need it) —
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `swift` points at the
Command Line Tools.

## Usage

- **Click** the % / ring → expand; **click away** → collapse.
- **Swipe** left/right (or tap the dots) → switch between the limits page and the detail page.
- **Tap the sessions block** → flip between today's active sessions and all‑time top projects.
- **Click Clawd** → cycle icon (Clawd → mono → Spark).
- **Right‑click** the island → Icon, Pause, Animate icon, Launch at Login, Check for Updates, Quit.

## Credits

- Clawd crab + Spark animation frames © **Mick Cesanek**
  ([claude-status-bar](https://github.com/m1ckc3s/claude-status-bar), MIT).
- Notch‑shape and Dynamic‑Island approach inspired by
  [pookify](https://github.com/eyadhammouda/pookify) (MIT).
- "Claude" and the spark are trademarks of Anthropic, PBC, used nominatively.

## License

MIT — see [LICENSE](LICENSE). Built with [Claude Code](https://claude.com/claude-code).
