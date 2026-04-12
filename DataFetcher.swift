import Foundation
import Security

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

    /// Chemin vers les credentials OAuth de Claude CLI
    private static let credentialsPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-widget/usage-cache.json")

    // ─── Auth detection (nonisolated = sync) ─────────────────────────

    nonisolated var hasAuth: Bool   { loadOAuthToken() != nil || loadAPIKey() != nil }

    /// Backward-compat alias used by UsageModel
    nonisolated var hasAPIKey: Bool { hasAuth }

    // ─── OAuth (lecture + refresh de ~/.claude/.credentials.json) ──────

    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURL      = "https://platform.claude.com/v1/oauth/token"
    private static let oauthScopes   = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    /// Retourne le token valide (et le rafraîchit si expiré).
    func validOAuthToken() async -> String? {
        guard let data = try? Data(contentsOf: DataFetcher.credentialsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any]
        else { return nil }

        let expiresAt = oauth["expiresAt"] as? Double ?? 0
        let isExpired = expiresAt < Date().timeIntervalSince1970 * 1000

        if !isExpired, let token = oauth["accessToken"] as? String, !token.isEmpty {
            return token
        }

        // Token expiré → refresh
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

        // Mettre à jour ~/.claude/.credentials.json avec le nouveau token
        let expiresIn   = respJSON["expires_in"] as? Double ?? 3600
        let newExpiry   = (Date().timeIntervalSince1970 + expiresIn) * 1000
        let newRefresh  = respJSON["refresh_token"] as? String ?? refreshToken

        var updatedOAuth = existingJSON["claudeAiOauth"] as? [String: Any] ?? [:]
        updatedOAuth["accessToken"]  = newToken
        updatedOAuth["refreshToken"] = newRefresh
        updatedOAuth["expiresAt"]    = newExpiry

        var updatedJSON = existingJSON
        updatedJSON["claudeAiOauth"] = updatedOAuth

        if let newData = try? JSONSerialization.data(withJSONObject: updatedJSON, options: .prettyPrinted) {
            try? newData.write(to: DataFetcher.credentialsPath, options: .atomic)
        }

        return newToken
    }

    /// Sync check (pour hasAuth) — ne regarde que si le fichier existe, pas l'expiry
    nonisolated func loadOAuthToken() -> String? {
        guard let data = try? Data(contentsOf: DataFetcher.credentialsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        // 1. Try OAuth (Claude Pro/Max/Team — same source as /usage command)
        if let token = await validOAuthToken() {
            do {
                let entry = try await callOAuthAPI(token: token)
                writeCache(entry)
                return entry
            } catch {
                // Fall through to API key or cache
            }
        }

        // 2. Try API key fallback
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
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
