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

    private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-widget/usage-cache.json")

    // ─── Keychain (nonisolated = sync, pas besoin d'await) ───────────

    nonisolated var hasAPIKey: Bool { loadAPIKey() != nil }

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
        guard let key = loadAPIKey() else { return readCache() }
        do {
            let entry = try await callAPI(key: key)
            writeCache(entry)
            return entry
        } catch {
            return readCache()
        }
    }

    // ─── Appel API ────────────────────────────────────────────────────

    private func callAPI(key: String) async throws -> CacheEntry {
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

        // Headers en lowercase pour comparaison fiable
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

        // Sonnet 4.5 (header modèle-spécifique, peut être absent)
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
