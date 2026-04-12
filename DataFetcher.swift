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
    var sonnet:   CacheMetric?
    var sonnet45: CacheMetric?
}

// MARK: - DataFetcher

actor DataFetcher {
    static let shared = DataFetcher()

    private static let keychainService = "com.claudeusage.apikey"
    private static let keychainAccount = "anthropic-api-key"

    /// Service name used by Claude CLI to store OAuth credentials in the macOS Keychain
    private static let claudeKeychainService = "Claude Code-credentials"

    /// Shared App Group container — accessible to both the main app and the widget extension.
    private static let groupContainer: URL = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.lekmax.ClaudeUsage") {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    private let cacheURL = DataFetcher.groupContainer
        .appendingPathComponent("usage-cache.json")

    // Token cached in App Group — survives claude logout, no Keychain prompt needed
    private let tokenCacheURL = DataFetcher.groupContainer
        .appendingPathComponent("token-cache.json")

    // ─── Auth detection ───────────────────────────────────────────────

    nonisolated var hasAuth: Bool   { loadOAuthToken() != nil || loadAPIKey() != nil }
    nonisolated var hasAPIKey: Bool { hasAuth }

    // ─── OAuth ────────────────────────────────────────────────────────

    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURL      = "https://platform.claude.com/v1/oauth/token"
    private static let oauthScopes   = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    /// Priority: App Group token cache → ~/.claude/.credentials.json → Keychain
    /// The App Group cache is written on every successful read, so after the first
    /// run neither claude logout nor Keychain prompts interrupt the app.
    nonisolated private func loadOAuthJSON() -> [String: Any]? {
        // 1. App Group token cache (our own copy, always accessible, no prompts)
        if let data = try? Data(contentsOf: tokenCacheURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        // 2. Claude CLI credentials file (written by `claude login`, no prompt)
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = URL(fileURLWithPath: String(cString: dir))
                .appendingPathComponent(".claude/.credentials.json")
            if let data = try? Data(contentsOf: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                persistTokenCache(json)   // seed App Group cache for next time
                return json
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
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        persistTokenCache(json)           // seed App Group cache for next time
        return json
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

    // ─── Keychain (nonisolated = sync, pas besoin d'await) ───────────

    nonisolated func loadAPIKey() -> String? {
        let q: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: DataFetcher.keychainService as CFString,
            kSecAttrAccount: DataFetcher.keychainAccount as CFString,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    nonisolated func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let del: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: DataFetcher.keychainService as CFString,
        ]
        SecItemDelete(del as CFDictionary)

        let add: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: DataFetcher.keychainService as CFString,
            kSecAttrAccount: DataFetcher.keychainAccount as CFString,
            kSecValueData:   data,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    // ─── Fetch principal ──────────────────────────────────────────────

    func fetch() async -> CacheEntry? {
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

        // 2. API key fallback (only when no OAuth token at all)
        if let key = loadAPIKey() {
            do {
                let entry = try await callAPIKeyFallback(key: key)
                writeCache(entry)
                return entry
            } catch {
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

        // Response: { five_hour: {utilization: 0-100, resets_at: "ISO"}, seven_day: {...}, seven_day_sonnet: {...} }
        func metric(_ key: String) -> CacheMetric? {
            guard let obj = json[key] as? [String: Any],
                  let util = obj["utilization"] as? Double
            else { return nil }
            let resetAt = obj["resets_at"] as? String
            return CacheMetric(pct: round(util), resetAt: resetAt)
        }

        guard let session = metric("five_hour"),
              let weekly  = metric("seven_day")
        else { throw URLError(.cannotParseResponse) }

        return CacheEntry(
            session:  session,
            weekly:   weekly,
            sonnet45: metric("seven_day_sonnet")
        )
    }

    // ─── Fallback API key (POST /v1/messages, lit les headers) ───────

    private func callAPIKeyFallback(key: String) async throws -> CacheEntry {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key,            forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",   forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model":     "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages":  [["role": "user", "content": "x"]],
        ])
        req.timeoutInterval = 15

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        var h = [String: String]()
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String {
                h[ks.lowercased()] = vs
            }
        }

        func dbl(_ k: String) -> Double {
            Double(h["anthropic-ratelimit-unified-\(k)"] ?? "0") ?? 0
        }
        func tsi(_ k: String) -> TimeInterval {
            Double(h["anthropic-ratelimit-unified-\(k)"] ?? "0") ?? 0
        }

        let pct5h = dbl("5h-utilization") * 100
        let ts5h  = tsi("5h-reset")
        let pct7d = dbl("7d-utilization") * 100
        let ts7d  = tsi("7d-reset")

        let pctS45Raw = h["anthropic-ratelimit-claude-sonnet-4-5-7d-utilization"]
                     ?? h["anthropic-ratelimit-claude-sonnet-4-5-20251001-7d-utilization"]
        let pctS45 = pctS45Raw.flatMap(Double.init).map { $0 * 100 }
        let tsS45  = Double(h["anthropic-ratelimit-claude-sonnet-4-5-7d-reset"]
                          ?? h["anthropic-ratelimit-claude-sonnet-4-5-20251001-7d-reset"]
                          ?? "0") ?? 0

        let fmt = ISO8601DateFormatter()
        func iso(_ ts: TimeInterval, fallback: TimeInterval) -> String {
            fmt.string(from: ts > 0 ? Date(timeIntervalSince1970: ts)
                                    : Date().addingTimeInterval(fallback))
        }

        return CacheEntry(
            session: CacheMetric(pct: round(pct5h),
                                 resetAt: iso(ts5h,  fallback: 5 * 3600)),
            weekly:  CacheMetric(pct: round(pct7d),
                                 resetAt: iso(ts7d,  fallback: 7 * 86400)),
            sonnet45: pctS45.map {
                CacheMetric(pct: round($0), resetAt: iso(tsS45, fallback: 7 * 86400))
            }
        )
    }

    // ─── Cache ────────────────────────────────────────────────────────

    private func readCache() -> CacheEntry? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(CacheEntry.self, from: data)
    }

    private func writeCache(_ entry: CacheEntry) {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: cacheURL, options: [])
            // Mirror to ~/.claude-widget/ so the widget can read it via temporary-exception entitlement
            if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
                let dotWidget = URL(fileURLWithPath: String(cString: dir))
                    .appendingPathComponent(".claude-widget")
                try? FileManager.default.createDirectory(at: dotWidget, withIntermediateDirectories: true)
                try? data.write(to: dotWidget.appendingPathComponent("usage-cache.json"), options: [])
            }
        }
    }
}
