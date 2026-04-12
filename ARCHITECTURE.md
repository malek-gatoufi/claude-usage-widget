# Architecture

## Overview

The project has two executable targets that run independently:

```
ClaudeUsage.app  (menu bar process)
└── ClaudeUsageWidgetExtension.appex  (embedded WidgetKit extension)
```

Both are sandboxed macOS apps. They share no files — each calls the Anthropic API independently using the same OAuth token from the macOS Keychain.

---

## Authentication

### Primary path — Claude CLI OAuth

Claude Code CLI stores its OAuth credentials in the macOS Keychain under:

```
Service:  "Claude Code-credentials"
Account:  <your macOS login name>
Value:    JSON blob
```

The JSON structure:
```json
{
  "claudeAiOauth": {
    "accessToken":  "sk-ant-oat01-...",
    "refreshToken": "sk-ant-ort01-...",
    "expiresAt":    1775984095359,
    "scopes":       ["user:inference", "user:sessions:claude_code", ...],
    "subscriptionType": "max"
  }
}
```

`DataFetcher` reads this item with `SecItemCopyMatching`, checks `expiresAt` (milliseconds since epoch), and calls the token refresh endpoint if needed:

```
POST https://platform.claude.com/v1/oauth/token
  grant_type:    refresh_token
  refresh_token: <current refresh token>
  client_id:     9d1c250a-e61b-44d9-88ed-5944d1962f5e
  scope:         user:profile user:inference ...
```

The refreshed token is written back to the same Keychain item so both targets see the update.

### Fallback — Anthropic API key

If no Claude CLI token is found, `DataFetcher` falls back to an API key stored in a separate Keychain item (`com.claudeusage.apikey`). In this mode it sends a minimal `POST /v1/messages` request (1-token Haiku call) and reads the usage percentages from the `anthropic-ratelimit-unified-*` response headers.

---

## Data flow

### Menu bar app

```
Timer (every 5 min)
  └── DataFetcher.fetch()
        ├── validOAuthToken()  →  read/refresh Keychain "Claude Code-credentials"
        ├── GET https://api.anthropic.com/api/oauth/usage
        │     Authorization: Bearer <token>
        │     anthropic-beta: oauth-2025-04-20
        │
        │   Response: {
        │     "five_hour":      { "utilization": 0-100, "resets_at": "ISO8601" },
        │     "seven_day":      { "utilization": 0-100, "resets_at": "ISO8601" },
        │     "seven_day_sonnet": { ... }   ← present for Max/Team plans
        │   }
        │
        └── CacheEntry  →  UsageModel @Published  →  MenuBarContent (SwiftUI)
```

### Widget extension

```
WidgetKit timeline request (every 5 min)
  └── fetchLiveEntry()
        ├── readOAuthToken()  →  same Keychain item "Claude Code-credentials"
        └── GET https://api.anthropic.com/api/oauth/usage  (same request as above)
              └── UsageEntry  →  ClaudeUsageEntryView (SwiftUI)
```

The widget calls the API directly rather than reading a shared file. This sidesteps macOS sandbox restrictions that prevent two sandboxed apps from sharing files in the user's home directory without App Groups.

---

## Sandbox entitlements

| Entitlement | Main app | Widget ext |
|---|---|---|
| `app-sandbox` | ✓ | ✓ |
| `network.client` | ✓ | ✓ |
| `home-relative-path.read-only (.claude/)` | ✓ | — |
| `home-relative-path.read-write (.claude-widget/)` | ✓ | — |

The `.claude/` read entitlement on the main app is a historical artifact — it was originally used to read `~/.claude/.credentials.json`. The live token is now read from the Keychain directly.

---

## Key files

### `DataFetcher.swift`

A Swift `actor` (thread-safe by construction). Public surface:

| Method | Type | Description |
|--------|------|-------------|
| `hasAuth` | `nonisolated var` | Sync check: keychain has an OAuth token or API key |
| `fetch()` | `async -> CacheEntry?` | Full fetch: OAuth → API key → cached file |
| `loadOAuthToken()` | `nonisolated func` | Sync read of the Claude CLI keychain item |
| `loadAPIKey()` | `nonisolated func` | Sync read of the fallback API key from keychain |
| `saveAPIKey(_:)` | `nonisolated func throws` | Save a new API key to keychain |

### `ClaudeUsageApp.swift`

- `@main` entry point, `MenuBarExtra` scene (SwiftUI)
- `UsageModel`: `@MainActor ObservableObject` that owns the refresh timer and publishes `CacheEntry?`
- Calls `WidgetCenter.shared.reloadAllTimelines()` after every fetch so the widget stays in sync

### `ClaudeUsageWidget.swift`

- `TimelineProvider` with `getTimeline` calling `fetchLiveEntry()` inside a `Task`
- Three widget families: `systemSmall` (ring), `systemMedium` (three rings), `systemLarge` (bars)
- Falls back to a demo entry if the API call fails (no auth or network error)

---

## Why the widget calls the API directly

The standard WidgetKit data-sharing pattern uses **App Groups** — a shared container both the main app and extension can read/write. App Groups require:
- A registered App Group ID in the Apple Developer portal
- Matching `com.apple.security.application-groups` entitlement on both targets
- A paid Apple Developer Program membership for proper provisioning

To remain buildable with a free Apple ID, this app avoids App Groups. The `temporary-exception.files.home-relative-path` entitlements that were originally used for a shared `~/.claude-widget/usage-cache.json` proved unreliable at runtime in the macOS sandbox. Having the widget call the API directly is simpler, always up-to-date, and requires no coordination between processes.

The only downside is two API calls per refresh cycle instead of one. The `/api/oauth/usage` endpoint is a lightweight read with no cost impact.
