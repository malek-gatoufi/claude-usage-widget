# Installation

## Requirements

- macOS 26 (Tahoe) or later
- Xcode command line tools (`xcode-select --install`)
- Claude Code CLI installed and logged in (`claude login`)

No paid Apple Developer account needed.

---

## Quick install (one command)

```bash
git clone git@github.com:malek-gatoufi/claude-usage-widget.git
cd claude-usage-widget/claudeusage/ClaudeUsage
bash install.sh
```

The script:
1. Builds the app with `xcodebuild`
2. Installs to `/Applications/ClaudeUsage.app`
3. Signs ad-hoc (no developer account needed)
4. Installs `widget-server.py` as a LaunchAgent (auto-starts at login)
5. Launches the app

---

## What happens after install

1. **Menu bar icon** — shows your current session % color-coded:
   - 🟢 Green: < 50%
   - 🟠 Orange: 50–80%
   - 🔴 Red: ≥ 80%

   If you're not logged in, it shows `⚙`.

2. **Desktop widget** — right-click your desktop → **Edit Widgets** → search **Claude Usage** → pick Small / Medium / Large.

3. **Clicking the widget** opens the menu bar app directly.

---

## Keychain permission

On first launch macOS may prompt:

> *"ClaudeUsage wants to use the 'Claude Code-credentials' keychain item."*

Click **Always Allow**. This lets the app read the OAuth token stored by Claude Code CLI.

---

## Troubleshooting

**Widget shows DEMO data**

Kill the widget extension — WidgetKit will reload it with live data:
```bash
killall ClaudeUsageWidgetExtension
```

**Menu bar shows `⚙` (gear icon)**

No auth found. Either:
- Run `claude login` to authenticate via Claude Code CLI
- Or open Settings → enter an Anthropic API key as fallback

**Data is stale / not updating**

Check the server is running:
```bash
curl http://127.0.0.1:27182/
```

If it returns `Connection refused`, restart the server:
```bash
launchctl unload ~/Library/LaunchAgents/lekmax.ClaudeUsage.WidgetData.plist
launchctl load -w ~/Library/LaunchAgents/lekmax.ClaudeUsage.WidgetData.plist
```

Check server logs:
```bash
tail -20 /tmp/ClaudeUsageWidget.log
```

---

## Install via Xcode (for development)

```bash
open ClaudeUsage.xcodeproj
```

1. Select the **ClaudeUsage** project → **Signing & Capabilities**
2. Set your Apple Developer Team for both targets
3. Press **Cmd+R**

A free Apple ID is sufficient.

---

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/lekmax.ClaudeUsage.WidgetData.plist
rm ~/Library/LaunchAgents/lekmax.ClaudeUsage.WidgetData.plist
rm -rf /Applications/ClaudeUsage.app
rm -rf ~/.claude-widget
```
