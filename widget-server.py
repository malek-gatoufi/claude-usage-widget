#!/usr/bin/env python3
"""
Claude Usage Widget Data Server

Runs as a persistent LaunchAgent HTTP server on 127.0.0.1:27182.
Refreshes usage data every 5 minutes in the background.
The sandboxed widget extension reads data via HTTP without needing
App Group access or TCC Full Disk Access permissions.
"""
import json
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Optional

PORT = 27182
REFRESH_INTERVAL = 300  # 5 minutes

HOME = Path.home()
GROUP_CONTAINER = HOME / "Library/Group Containers/group.lekmax.ClaudeUsage"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
OAUTH_SCOPES = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

_cache: Optional[dict] = None
_cache_lock = threading.Lock()


# ── OAuth helpers ─────────────────────────────────────────────────────────────

def load_token_json() -> Optional[dict]:
    """Read OAuth JSON from the first available source."""
    # 1. Group Container cache (written by main app or previous refresh)
    for path in [
        GROUP_CONTAINER / "token-cache.json",
        HOME / ".claude/.credentials.json",
    ]:
        try:
            return json.loads(path.read_text())
        except Exception:
            pass

    # 2. macOS Keychain — used by newer Claude Code versions
    try:
        import subprocess
        result = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout.strip())
    except Exception:
        pass

    return None


def maybe_refresh(token_data: dict) -> dict:
    """Refresh the access token if expired, return updated token_data."""
    oauth = token_data.get("claudeAiOauth", {})
    expires_at = oauth.get("expiresAt", 0)
    if expires_at >= time.time() * 1000:
        return token_data  # still valid

    refresh_token = oauth.get("refreshToken", "")
    if not refresh_token:
        return token_data

    try:
        body = json.dumps({
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": CLIENT_ID,
            "scope": OAUTH_SCOPES,
        }).encode()
        req = urllib.request.Request(TOKEN_URL, data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            r = json.loads(resp.read())
        new_token = r.get("access_token", "")
        if not new_token:
            return token_data

        expires_in = r.get("expires_in", 3600)
        updated = dict(oauth)
        updated["accessToken"] = new_token
        updated["refreshToken"] = r.get("refresh_token", refresh_token)
        updated["expiresAt"] = (time.time() + expires_in) * 1000

        token_data = dict(token_data)
        token_data["claudeAiOauth"] = updated

        # Persist refreshed token
        for path in [
            GROUP_CONTAINER / "token-cache.json",
            HOME / ".claude/.credentials.json",
        ]:
            if path.exists():
                try:
                    path.write_text(json.dumps(token_data))
                except Exception:
                    pass

    except Exception:
        pass

    return token_data


# ── Usage fetch ───────────────────────────────────────────────────────────────

def refresh_cache() -> None:
    global _cache

    token_data = load_token_json()
    if not token_data:
        return

    token_data = maybe_refresh(token_data)
    oauth = token_data.get("claudeAiOauth", {})
    access_token = oauth.get("accessToken", "")
    if not access_token:
        return

    try:
        req = urllib.request.Request(
            "https://api.anthropic.com/api/oauth/usage",
            headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "ClaudeUsageWidget/1.0",
            },
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 429:
            pass  # rate-limited, keep old cache
        return
    except Exception:
        return

    def metric(key: str) -> Optional[dict]:
        obj = data.get(key, {})
        util = obj.get("utilization")
        if util is None:
            return None
        return {"pct": round(util), "resetAt": obj.get("resets_at")}

    session = metric("five_hour")
    weekly = metric("seven_day")
    if not session or not weekly:
        return

    new_cache = {"session": session, "weekly": weekly}
    sonnet45 = metric("seven_day_sonnet")
    if sonnet45:
        new_cache["sonnet45"] = sonnet45

    with _cache_lock:
        _cache = new_cache


def refresh_loop() -> None:
    while True:
        try:
            refresh_cache()
        except Exception as e:
            print(f"refresh error: {e}", file=sys.stderr, flush=True)
        time.sleep(REFRESH_INTERVAL)


# ── HTTP server ───────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        with _cache_lock:
            data = _cache
        if data:
            body = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(503)
            self.end_headers()

    def log_message(self, *args) -> None:
        pass  # silence per-request logs


if __name__ == "__main__":
    # Pre-load cached data so the server can serve immediately even if rate-limited
    for cache_path in [
        GROUP_CONTAINER / "usage-cache.json",
        HOME / ".claude-widget" / "usage-cache.json",
    ]:
        if cache_path.exists():
            try:
                data = json.loads(cache_path.read_text())
                if data.get("session") and data.get("weekly"):
                    with _cache_lock:
                        _cache = data
                    break
            except Exception:
                pass

    # Initial live fetch (may be rate-limited; if so, cached data stays)
    refresh_cache()

    # Background refresh thread
    threading.Thread(target=refresh_loop, daemon=True).start()

    # HTTP server (blocks forever)
    try:
        httpd = HTTPServer(("127.0.0.1", PORT), Handler)
        httpd.serve_forever()
    except OSError as e:
        print(f"Server error: {e}", file=sys.stderr, flush=True)
        sys.exit(1)
