Claude Notch — a Dynamic Island usage tracker for your Mac's notch
==================================================================

Shows your Claude 5-hour, 7-day and credit usage right in the notch,
with Clawd the crab. Same numbers you see in Claude Desktop.

REQUIREMENTS
------------
• macOS 14 or newer (Apple Silicon or Intel), notch or not (it draws
  its own on non-notch Macs).
• Claude Desktop installed AND signed in to your Claude account.
  The tracker reads YOUR local Claude Desktop session to show YOUR own
  usage — nothing of the sender's, nothing leaves your machine.

INSTALL
-------
1. Unzip this file.
2. Drag "Claude Notch.app" into your Applications folder.
3. FIRST launch only — macOS will say the developer "cannot be verified"
   (the app isn't notarized). To open it anyway:
      • Right-click the app → Open → Open
      (or: System Settings → Privacy & Security → "Open Anyway")
   You only have to do this once.
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
• Right-click the island for the menu: icon, pause, launch at login, quit.

PRIVACY
-------
Talks only to https://claude.ai (the same server Claude Desktop uses) to
fetch your usage, using your own local session. No analytics, no third-
party servers, nothing sent to anyone else.

CREDITS
-------
Clawd crab animation © Mick Cesanek (claude-status-bar, MIT). "Claude" and
the spark are trademarks of Anthropic, used nominatively. Made with Claude.
