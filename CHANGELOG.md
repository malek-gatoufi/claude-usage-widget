# Changelog

All notable changes to Claude Usage Widget are documented here.

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
