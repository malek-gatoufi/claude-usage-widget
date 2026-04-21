import Foundation
import Security
import Darwin

// MARK: - Models (partagés avec le widget via fichier JSON)

struct CacheMetric: Codable, Sendable {
    var pct: Double
    var resetAt: String?

    var resetAtDate: Date? {
        guard let s = resetAt else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

struct CacheEntry: Codable, Sendable {
    var session:  CacheMetric
    var weekly:   CacheMetric
    var sonnet45: CacheMetric?
    var extra:    CacheMetric?   // pay-as-you-go extra usage (only when enabled)
}

// MARK: - DataFetcher

actor DataFetcher {
    static let shared = DataFetcher()

    /// Service name used by Claude CLI to store OAuth credentials in the macOS Keychain
    private static let claudeKeychainService = "Claude Code-credentials"

    /// Shared App Group container — accessible to both the main app and the widget extension.
    private static let groupContainer: URL = {
        // 1. Proper App Group (works with provisioned signing)
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.lekmax.ClaudeUsage") {
            return url
        }
        // 2. Direct path via getpwuid — works with ad-hoc signing where
        //    containerURL returns nil or sandbox-redirected home
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
                .appendingPathComponent("Library/Group Containers/group.lekmax.ClaudeUsage")
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    private let cacheURL = DataFetcher.groupContainer
        .appendingPathComponent("usage-cache.json")

    // Token cached in App Group — survives claude logout, no Keychain prompt needed
    private let tokenCacheURL = DataFetcher.groupContainer
        .appendingPathComponent("token-cache.json")

    // ─── Auth detection ───────────────────────────────────────────────

    nonisolated var hasAuth: Bool { loadOAuthToken() != nil }

    // ─── OAuth ────────────────────────────────────────────────────────

    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURL      = "https://platform.claude.com/v1/oauth/token"
    private static let oauthScopes   = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    /// Priority: App Group token cache → ~/.claude/.credentials.json → Keychain
    /// If the cached token is expired we skip ahead to fresher sources before
    /// falling back to the stale JSON (whose refresh token may still be valid).
    nonisolated private func loadOAuthJSON() -> [String: Any]? {
        var staleJSON: [String: Any]? = nil

        // Helper: is this JSON's access token still valid?
        func isFresh(_ json: [String: Any]) -> Bool {
            guard let oauth = json["claudeAiOauth"] as? [String: Any],
                  let exp = oauth["expiresAt"] as? Double
            else { return false }
            return exp >= Date().timeIntervalSince1970 * 1000
        }

        // 1. App Group token cache
        if let data = try? Data(contentsOf: tokenCacheURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if isFresh(json) { return json }
            staleJSON = json   // expired — keep as last-resort fallback
        }

        // 2. Claude CLI credentials file (written by `claude login`, no prompt)
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = URL(fileURLWithPath: String(cString: dir))
                .appendingPathComponent(".claude/.credentials.json")
            if let data = try? Data(contentsOf: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if isFresh(json) {
                    persistTokenCache(json)   // seed App Group cache for next time
                    return json
                }
                if staleJSON == nil { staleJSON = json }
            }
        }

        // 3. Keychain — may prompt once on ad-hoc builds, then persists
        let q: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: DataFetcher.claudeKeychainService as CFString,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            persistTokenCache(json)           // update App Group cache with fresh token
            return json
        }

        // All fresh sources exhausted — return stale token so refresh can be attempted
        return staleJSON
    }

    /// Writes OAuth JSON into the App Group container so future reads never need
    /// ~/.claude/.credentials.json or the Keychain.
    nonisolated private func persistTokenCache(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        let dir = tokenCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: tokenCacheURL, options: .atomic)
    }

    /// Returns a valid (non-expired) token, refreshing it if needed.
    func validOAuthToken() async -> String? {
        guard let json = loadOAuthJSON(),
              let oauth = json["claudeAiOauth"] as? [String: Any]
        else { return nil }

        let expiresAt = oauth["expiresAt"] as? Double ?? 0
        let isExpired = expiresAt < Date().timeIntervalSince1970 * 1000

        if !isExpired, let token = oauth["accessToken"] as? String, !token.isEmpty {
            persistTokenToDefaults(json)   // keep UserDefaults in sync
            return token
        }

        guard let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty
        else { return nil }

        return await refreshOAuthToken(refreshToken: refreshToken, existingJSON: json)
    }

    private func refreshOAuthToken(refreshToken: String, existingJSON: [String: Any]) async -> String? {
        guard let url = URL(string: DataFetcher.tokenURL) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let body: [String: Any] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     DataFetcher.oauthClientID,
            "scope":         DataFetcher.oauthScopes,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = bodyData

        guard let (respData, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let respJSON = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let newToken = respJSON["access_token"] as? String
        else { return nil }

        let expiresIn  = respJSON["expires_in"] as? Double ?? 3600
        let newExpiry  = (Date().timeIntervalSince1970 + expiresIn) * 1000
        let newRefresh = respJSON["refresh_token"] as? String ?? refreshToken

        var updatedOAuth = existingJSON["claudeAiOauth"] as? [String: Any] ?? [:]
        updatedOAuth["accessToken"]  = newToken
        updatedOAuth["refreshToken"] = newRefresh
        updatedOAuth["expiresAt"]    = newExpiry
        var updatedJSON = existingJSON
        updatedJSON["claudeAiOauth"] = updatedOAuth

        // Persist everywhere
        persistTokenCache(updatedJSON)
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = URL(fileURLWithPath: String(cString: dir))
                .appendingPathComponent(".claude/.credentials.json")
            if let data = try? JSONSerialization.data(withJSONObject: updatedJSON) {
                try? data.write(to: path, options: .atomic)
            }
        }
        return newToken
    }

    nonisolated func loadOAuthToken() -> String? {
        guard let json = loadOAuthJSON(),
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    // ─── Local proxy (widget-server.py at 127.0.0.1:27182) ──────────
    // Single API caller: both menu bar and widget read from the same source,
    // so we never make duplicate API calls that could trigger rate limiting.

    private func fetchFromLocalProxy() async -> CacheEntry? {
        guard let url = URL(string: "http://127.0.0.1:27182/") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data)
        else { return nil }
        return entry
    }

    // ─── Fetch principal ──────────────────────────────────────────────

    func fetch() async -> CacheEntry? {
        // 0. Proxy — server is the single API source, handles rate limits & token refresh.
        //    Fall through only if server isn't running.
        if let entry = await fetchFromLocalProxy() {
            writeCache(entry)
            return entry
        }

        // 1. OAuth path (Claude Pro/Max/Team — same source as /usage command)
        //    If an OAuth token exists, never fall back to API key — the API key
        //    returns its own rate-limit headers which are unrelated to subscription usage.
        if let token = await validOAuthToken() {
            do {
                let entry = try await callOAuthAPI(token: token)
                writeCache(entry)
                return entry
            } catch {
                // OAuth token present but API call failed (e.g. 429 rate limit).
                // Return last cached value so we don't show stale API key data.
                return readCache()
            }
        }

        return readCache()
    }

    // ─── Méthode OAuth (GET /api/oauth/usage) ────────────────────────

    private func callOAuthAPI(token: String) async throws -> CacheEntry {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("ClaudeUsageWidget/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw URLError(.cannotParseResponse) }

        let fallbackResets: [String: TimeInterval] = [
            "five_hour":        5 * 3600,
            "seven_day":        7 * 86400,
            "seven_day_sonnet": 7 * 86400,
        ]
        func metric(_ key: String) -> CacheMetric? {
            guard let obj = json[key] as? [String: Any],
                  let util = obj["utilization"] as? Double
            else { return nil }
            // Use API-provided reset time; fall back to now+window when API omits it
            let resetAt: String? = (obj["resets_at"] as? String) ??
                fallbackResets[key].map { ISO8601DateFormatter().string(from: Date().addingTimeInterval($0)) }
            return CacheMetric(pct: min(round(util), 100), resetAt: resetAt)
        }

        // extra_usage resets on the 1st of each month (not included in resets_at)
        func extraMetric() -> CacheMetric? {
            guard let obj = json["extra_usage"] as? [String: Any],
                  let enabled = obj["is_enabled"] as? Bool, enabled,
                  let util = obj["utilization"] as? Double
            else { return nil }
            var comps = Calendar.current.dateComponents([.year, .month], from: Date())
            comps.day = 1
            let startOfMonth  = Calendar.current.date(from: comps) ?? Date()
            let startOfNextMonth = Calendar.current.date(byAdding: .month, value: 1, to: startOfMonth)
                               ?? Date().addingTimeInterval(30 * 86400)
            let resetAt = ISO8601DateFormatter().string(from: startOfNextMonth)
            return CacheMetric(pct: min(round(util), 100), resetAt: resetAt)
        }

        guard let session = metric("five_hour"),
              let weekly  = metric("seven_day")
        else { throw URLError(.cannotParseResponse) }

        return CacheEntry(
            session:  session,
            weekly:   weekly,
            sonnet45: metric("seven_day_sonnet"),
            extra:    extraMetric()
        )
    }

    // ─── Cache ────────────────────────────────────────────────────────

    private static let groupDefaults = UserDefaults(suiteName: "group.lekmax.ClaudeUsage")

    private func readCache() -> CacheEntry? {
        // Try UserDefaults first (works across sandbox boundaries via cfprefsd)
        if let data = DataFetcher.groupDefaults?.data(forKey: "usage-cache") {
            if let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) { return entry }
        }
        // File fallback
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(CacheEntry.self, from: data)
    }

    private func writeCache(_ entry: CacheEntry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        // UserDefaults — readable by widget via App Group suite (provisioned signing)
        DataFetcher.groupDefaults?.set(data, forKey: "usage-cache")
        // Group Container file (provisioned signing)
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [])
        // ~/.claude-widget/usage-cache.json — readable by the widget extension via
        // temporary-exception.files.home-relative-path.read-only + getpwuid bypass.
        // Also written by widget-server.py; we write here too so the widget works
        // even when the server isn't running.
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let base = URL(fileURLWithPath: String(cString: dir))
                .appendingPathComponent(".claude-widget")
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try? data.write(to: base.appendingPathComponent("usage-cache.json"), options: .atomic)
        }
    }

    /// Also persist OAuth token to UserDefaults so widget can read it without file I/O.
    func persistTokenToDefaults(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        DataFetcher.groupDefaults?.set(data, forKey: "oauth-token")
    }
}
