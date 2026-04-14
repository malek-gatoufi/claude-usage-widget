# Architecture

## Overview

```
widget-server.py          LaunchAgent — seul appelant API, tourne en permanence
      │  écrit ~/.claude-widget/usage-cache.json
      │  expose HTTP 127.0.0.1:27182
      │
      ├──► ClaudeUsage.app (menu bar, sandboxé)
      │         lit proxy HTTP :27182
      │         NotificationManager, HistoryStore
      │         WidgetCenter.reloadAllTimelines()
      │
      └──► ClaudeUsageWidgetExtension.appex (WidgetKit, sandboxé)
               lit ~/.claude-widget/usage-cache.json via getpwuid bypass
               fallback : appel OAuth direct si cache > 6 min
```

**Règle fondamentale : un seul appelant API.**
`widget-server.py` est le seul process qui contacte `api.anthropic.com`.
La menu bar et le widget lisent ses données — jamais l'API directement,
sauf si le serveur est indisponible.

---

## Composants

### 1. widget-server.py (LaunchAgent)

- Tourne en permanence via `~/Library/LaunchAgents/lekmax.ClaudeUsage.WidgetData.plist`
- Rafraîchit toutes les **5 min** (lire intervalle dans `~/.claude-widget/config.json`)
- Après chaque fetch réussi → écrit `~/.claude-widget/usage-cache.json`
- Gestion 429 : backoff 30 min (données fraîches) ou 5 min (après reset de session)
  - Lit l'en-tête `Retry-After` (minimum 60 s)
- Démarrage : ne charge le cache que si `resetAt` est dans le futur

### 2. ClaudeUsage.app (menu bar)

`DataFetcher.fetch()` — priorité :
1. Proxy HTTP `127.0.0.1:27182` (timeout 2 s)
2. Appel OAuth direct (si proxy indisponible)
3. Clé API fallback
4. Cache local

Autres composants :
- `NotificationManager` : alertes macOS à 80 % / 90 % (configurable)
- `HistoryStore` : snapshot horaire sur 7 jours (`~/.claude-widget/history.json`)
- `HistoryView` : graphe ligne (Swift Charts) dans une fenêtre dédiée
- `SettingsView` : intervalle, seuil notifications, clé API, launch at login

### 3. ClaudeUsageWidgetExtension.appex (WidgetKit)

`fetchLiveEntry()` — priorité :
1. `~/.claude-widget/usage-cache.json` via `getpwuid` (si âge < 6 min)
2. Appel OAuth direct (si cache stale)
3. Cache sandbox container
4. Données DEMO

---

## Authentification

### OAuth (défaut — Claude Code CLI)

```
Keychain service : "Claude Code-credentials"
Value            : { claudeAiOauth: { accessToken, refreshToken, expiresAt } }
```

`DataFetcher.loadOAuthJSON()` — priorité des sources :
1. Group Container `token-cache.json` **(si token non expiré)**
2. `~/.claude/.credentials.json` **(si token non expiré)**
3. Keychain macOS **(toujours essayé en dernier — contient le token le plus frais)**

Si expiré → `refreshOAuthToken()` via `POST https://platform.claude.com/v1/oauth/token`.
Token rafraîchi persisté dans Group Container + `~/.claude/.credentials.json`.

### Clé API (fallback)

Stockée dans le Keychain sous `com.claudeusage.apikey`.
Utilisée uniquement si aucun token OAuth n'est trouvé.
Mode : `POST /v1/messages` avec 1 token Haiku, lit les headers `anthropic-ratelimit-unified-*`.

---

## Contournement du sandbox (ad-hoc signing)

Avec signing ad-hoc (`-`), les entitlements `App Group` et `temporary-exception` ne sont pas honorés.

**Solution** : `getpwuid(getuid())` retourne le vrai répertoire home (non redirigé).
- Permet au widget de lire `~/.claude-widget/usage-cache.json`
- Permet aux deux apps de lire `~/Library/Group Containers/.../token-cache.json`
- Le serveur Python (non-sandboxé) écrit librement dans ces chemins

---

## Structure des fichiers

```
ClaudeUsage/
├── ClaudeUsageApp.swift        # @main, menu bar, UsageModel, couleur dynamique
├── DataFetcher.swift           # OAuth, refresh token, proxy, cache
├── NotificationManager.swift   # Alertes seuil (80 % / 90 %)
├── HistoryStore.swift          # Snapshots horaires 7 jours
├── HistoryView.swift           # Graphe Swift Charts
├── SettingsView.swift          # Réglages (intervalle, notifications, auth)
├── widget-server.py            # Serveur HTTP local (LaunchAgent)
├── install.sh                  # Installation one-command
├── ClaudeUsage.entitlements
└── ClaudeUsageWidget/
    ├── ClaudeUsageWidget.swift          # Widget UI + fetch
    ├── ClaudeUsageWidget.entitlements
    └── ClaudeUsageWidgetBundle.swift
```

---

## Flux de données

```
[claude login]
      ↓
Keychain "Claude Code-credentials"
      ↓
widget-server.py (toutes les 5 min)
      ↓ GET /api/oauth/usage (Bearer token)
api.anthropic.com
      ↓ { five_hour, seven_day, seven_day_sonnet, extra_usage }
~/.claude-widget/usage-cache.json   ──► Widget (lecture directe)
      ↓
HTTP 127.0.0.1:27182                ──► Menu bar app
      ↓
WidgetCenter.reloadAllTimelines()
      ↓
Desktop widget mis à jour
```
