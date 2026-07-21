Claude Notch — a Dynamic Island usage tracker for your Mac's notch
==================================================================

Shows your Claude 5-hour, 7-day and credit usage right in the notch,
with Clawd the crab — plus optional Codex tracking. Same numbers you
see in Claude Desktop.

REQUIREMENTS
------------
• macOS 14 or newer (Apple Silicon or Intel), notch or not (it draws
  its own on non-notch Macs).
• A signed-in Claude session, an authenticated Codex installation, or
  both. Claude supports Desktop, browser and Claude Code sessions.

INSTALL
-------
1. Unzip this file.
2. Drag "Claude Notch.app" into your Applications folder.
3. Double-click it to open — the app is signed and notarized, so there's no
   "unverified developer" warning.
4. A Keychain prompt will appear:
   "… wants to use information stored in 'Claude Safe Storage'."
   Click "Always Allow". (This lets it read your local Claude session.)

USING IT
--------
• The island drops down from the notch: Clawd on the left, your live
  5-hour session % + ring on the right.
• Click the % / ring to expand: 5-Hour, 7-Day, credits, cost today,
  tokens today, and your plan — each in a tile. Click away to collapse.
• Click Clawd to switch icon (Clawd → mono → Spark).
• Right-click the island for the menu: provider (Claude or Codex), icon,
  animation, pause, launch at login, updates and quit.

PRIVACY
-------
Claude data is read from your local session and Anthropic's first-party
usage endpoint. Codex data comes from the installed official codex
app-server. No analytics or third-party servers are used. Raw Codex prompt
previews and account email addresses are not displayed or retained.

CREDITS
-------
Clawd crab animation © Mick Cesanek (claude-status-bar, MIT). "Claude" and
the spark are trademarks of Anthropic. "Codex" and its logo are trademarks
of OpenAI. All marks are used nominatively.
