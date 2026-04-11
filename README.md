# Claude Usage Widget

A macOS menu bar app + desktop widget that shows your Anthropic API usage in real time.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-orange) ![Swift](https://img.shields.io/badge/Swift-5-orange) ![WidgetKit](https://img.shields.io/badge/WidgetKit-macOS-orange)

---

## What it does

- **Menu bar** — shows your current session usage (%) at a glance
- **Desktop widget** — Small / Medium / Large, with Liquid Glass background
  - Session (5h rolling window)
  - Weekly (7d rolling window)
  - Sonnet 4.5 weekly (when available)
- Refreshes every **5 minutes** automatically
- **No Node.js**, no launchd setup, no Claude Code required

---

## Requirements

| | |
|---|---|
| macOS | 26.3 (Tahoe) or later |
| Xcode | 26.4 or later |
| Anthropic API key | [console.anthropic.com](https://console.anthropic.com/settings/keys) |

> **Cost** — the app makes one minimal Haiku call every 5 min to read rate-limit headers.  
> ~$0.000005/call × 288 calls/day ≈ **$0.0015/day**.

---

## Installation

### 1. Clone

```bash
git clone https://github.com/malek-gatoufi/claude-usage-widget.git
cd claude-usage-widget/claudeusage/ClaudeUsage
```

### 2. Open in Xcode

```bash
open ClaudeUsage.xcodeproj
```

### 3. Set your Team

In Xcode → select the **ClaudeUsage** project → Signing & Capabilities → set your Apple Developer Team for both targets (`ClaudeUsage` and `ClaudeUsageWidgetExtension`).

> Free Apple ID works — no paid developer account needed for local builds.

### 4. Run

Press **Cmd+R**. The app will appear in your menu bar as `…`, then switch to a percentage once configured.

### 5. Enter your API key

Click the `⚙` icon in the menu bar → **Réglages…** → paste your Anthropic API key → **Save & Test**.

### 6. Add the widget

- Right-click your desktop → Edit Widgets
- Search for **Claude Usage**
- Add Small, Medium, or Large

---

## Project structure

```
ClaudeUsage/
├── ClaudeUsageApp.swift          # @main + AppDelegate (menu bar)
├── DataFetcher.swift             # URLSession → Anthropic API, keychain, cache
├── SettingsView.swift            # Settings panel (SwiftUI)
├── ClaudeUsage.entitlements      # Sandbox: network + home dir write
└── ClaudeUsageWidget/
    ├── ClaudeUsageWidget.swift   # Widget UI (Small / Medium / Large)
    ├── ClaudeUsageWidget.entitlements
    └── Info.plist
```

### Cache file

The app writes `~/.claude-widget/usage-cache.json` every 5 minutes.  
The widget extension reads it via a sandbox entitlement (`home-relative-path.read-only`).

```json
{
  "session":  { "pct": 25, "resetAt": "2026-04-11T21:00:00Z" },
  "weekly":   { "pct": 21, "resetAt": "2026-04-15T19:00:00Z" },
  "sonnet45": null
}
```

---

## Architecture

```
ClaudeUsage.app (menu bar)
  └── DataFetcher (actor)
        ├── Keychain  →  stores API key (com.claudeusage.apikey)
        ├── URLSession  →  POST /v1/messages (Haiku, 1 token)
        ├── Parse headers  →  anthropic-ratelimit-unified-*
        └── Write  →  ~/.claude-widget/usage-cache.json

ClaudeUsageWidget.appex (extension)
  └── loadEntry()  →  reads ~/.claude-widget/usage-cache.json
        └── displays session / weekly / sonnet 4.5
```

---

## Distributing to teammates

1. In Xcode → **Product → Archive**
2. **Distribute App → Direct Distribution** (Developer ID signing)
3. Share the `.app` — teammates drag it to `/Applications` and run it

> First launch on a new machine: macOS Gatekeeper may block the app.  
> Right-click → Open to bypass, or have them run:
> ```bash
> xattr -cr /Applications/ClaudeUsage.app
> ```

---

## FAQ

**Widget shows DEMO data**  
→ Make sure the app is running (check menu bar). After Cmd+R in Xcode the widget reloads within 30 seconds.

**Sonnet 4.5 bar is empty**  
→ Anthropic doesn't yet expose a model-specific rate-limit header for Sonnet 4.5 in Haiku responses. The bar will appear automatically once the header is available.

**Can I use my Claude Desktop OAuth token instead of an API key?**  
→ Not directly — Claude Desktop uses OAuth internally and doesn't expose it to third-party apps. Get a proper API key at [console.anthropic.com](https://console.anthropic.com/settings/keys).
