# Changelog

All notable changes to Claude Usage Widget are documented here.

## [1.1.0] — 2026-04-14

### Added
- **Threshold notifications** — macOS alert when session, weekly, Sonnet 4.5, or extra usage crosses 80% or 90% (configurable in Settings, can be disabled)
- **Dynamic menu bar color** — icon turns green < 50%, orange 50-80%, red ≥ 80% for at-a-glance status
- **Usage history** — hourly snapshots stored for 7 days, viewable as a line chart (menu bar → Historique)
- **Configurable refresh interval** — 1 / 2 / 5 / 10 minutes, saved to `~/.claude-widget/config.json` and shared with the server
- **Widget tap-to-open** — clicking the desktop widget activates the menu bar app
- **Homebrew CI/CD** — GitHub Actions builds and zips the app on tag push, auto-updates Homebrew tap

### Fixed
- Server now uses smart backoff on 429 (30 min if data is fresh, 5 min if stale after a session reset)
- Server reads `Retry-After` header when present (minimum 60s enforced)
- Reduced default interval from 60s back to 5 min to avoid rate-limiting the `/api/oauth/usage` endpoint

## [1.0.0] — 2026-04-14

### Added
- Menu bar icon showing current session % at a glance
- Desktop widget in Small / Medium / Large sizes with Liquid Glass background
- **Session** (rolling 5-hour), **Weekly** (rolling 7-day), **Sonnet 4.5 weekly** metrics
- **Extra usage** — pay-as-you-go credits display (when enabled on your account)
- Dark mode and light mode support
- OAuth authentication via Claude CLI Keychain (no API key required)
- Local proxy server (`widget-server.py`) as LaunchAgent — handles token refresh, rate limiting, and cross-sandbox data sharing
- One-command install: `bash install.sh` (no Apple Developer account needed)
- Auto-refresh every 60 seconds
