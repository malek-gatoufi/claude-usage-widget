# Installation

## Requirements

- macOS 26.3 (Tahoe) or later
- Xcode 26 or later (free from the Mac App Store)
- Claude Code CLI installed — **or** an Anthropic API key

---

## Option A — Command line (one shot)

No need to open Xcode. Run from the repo root:

```bash
cd claudeusage/ClaudeUsage

xcodebuild -scheme ClaudeUsage -configuration Release \
  -derivedDataPath /tmp/ClaudeUsageBuild \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM=""

cp -R /tmp/ClaudeUsageBuild/Build/Products/Release/ClaudeUsage.app /Applications/
xattr -cr /Applications/ClaudeUsage.app
open /Applications/ClaudeUsage.app
```

> Uses ad-hoc signing (no Apple Developer account needed). The app runs locally only.

---

## Option B — Xcode (recommended for development)

### Step 1 — Clone the repo

```bash
git clone <repo-url>
cd claudeusage/ClaudeUsage
```

---

### Step 2 — Open in Xcode

```bash
open ClaudeUsage.xcodeproj
```

---

### Step 3 — Set your signing team

In Xcode, select the **ClaudeUsage** project in the navigator, then open **Signing & Capabilities**.

Set your Apple Developer Team for **both** targets:
- `ClaudeUsage`
- `ClaudeUsageWidgetExtension`

> A free Apple ID is enough for local development builds — no paid membership required.

If Xcode shows a bundle ID conflict, change the bundle identifier to something unique, e.g. `com.yourname.ClaudeUsage`.

---

### Step 4 — Build and run

Press **Cmd+R** (or Product → Run).

The app will appear in your menu bar. On the very first run, macOS will show two permission dialogs:

1. **Keychain access** — "ClaudeUsage wants to use the 'Claude Code-credentials' keychain item." → click **Always Allow**
2. **Widget Keychain access** — same prompt for the widget extension → click **Always Allow**

---

## Step 5 — Check the menu bar

If you have Claude Code installed and are logged in, the menu bar icon will immediately switch from `⚙` to your current session percentage (e.g. `6%`).

If no Claude CLI token is found, the icon stays `⚙`. Open Settings:

```
Menu bar icon → Réglages… → paste your Anthropic API key → Save & Test
```

Get an API key at [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys).

---

## Step 6 — Add the desktop widget

1. Right-click your macOS desktop → **Edit Widgets**
2. Search for **Claude Usage**
3. Choose Small, Medium, or Large and click **+**

The widget calls the API directly — no extra configuration needed.

If the widget shows **DEMO** after the first install, kill the stale process and let WidgetKit respawn it:

```bash
killall ClaudeUsageWidgetExtension 2>/dev/null; true
```

---

## Optional — Launch at login

Open the app → menu bar icon → **Réglages…** → toggle **Lancer au démarrage**.

---

## Distributing to teammates (without Xcode)

1. In Xcode → **Product → Archive**
2. **Distribute App → Direct Distribution** (requires a Developer ID certificate)
3. Share the `.app` bundle

On the recipient's machine, if Gatekeeper blocks the app:
```bash
xattr -cr /Applications/ClaudeUsage.app
```
Then right-click → Open.
