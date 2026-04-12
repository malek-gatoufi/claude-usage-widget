# Installation

## Requirements

- macOS 14 (Sonoma) or later
- Xcode (any recent version — free from the Mac App Store)
- Claude Code CLI installed and logged in (`claude login`)

No paid Apple Developer account needed.

---

## Quick install (one command)

From the repo root:

```bash
cd claudeusage/ClaudeUsage
bash install.sh
```

That's it. The script builds, signs (ad-hoc), installs to `/Applications`, registers the widget, and launches the app.

---

## What happens after launch

1. **Menu bar icon** — shows your current session % (e.g. `42%`). If you're not logged into Claude Code, it shows `⚙`.

2. **Desktop widget** — right-click your desktop → **Edit Widgets** → search **Claude Usage** → pick Small / Medium / Large.

3. **If the widget shows DEMO**, kill the extension and let WidgetKit reload it:
   ```bash
   killall ClaudeUsageWidgetExtension
   ```

---

## Keychain permission

On first launch macOS will prompt:

> *"ClaudeUsage wants to use the 'Claude Code-credentials' keychain item."*

Click **Always Allow**. This lets the app read the OAuth token stored by Claude Code CLI without you needing to enter an API key.

---

## Install via Xcode (for development)

```bash
open ClaudeUsage.xcodeproj
```

1. Select the **ClaudeUsage** project → **Signing & Capabilities**
2. Set your Apple Developer Team for both targets (`ClaudeUsage` and `ClaudeUsageWidgetExtension`)
3. Press **Cmd+R**

A free Apple ID is sufficient — no paid membership required.

---

## Uninstall

```bash
killall ClaudeUsage 2>/dev/null; rm -rf /Applications/ClaudeUsage.app
```
