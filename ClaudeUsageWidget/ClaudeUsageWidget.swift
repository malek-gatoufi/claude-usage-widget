import WidgetKit
import SwiftUI
import Security
import Darwin

// MARK: - Models

struct UsageMetric {
    var pct: Double
    var resetAt: Date?
}

struct UsageEntry: TimelineEntry {
    var date: Date
    var session: UsageMetric
    var weekly: UsageMetric
    var sonnet: UsageMetric?
    var sonnet45: UsageMetric?
    var isDemo: Bool
}

// MARK: - Live fetch (OAuth, same source as main app)

private let demoEntry = UsageEntry(
    date: Date(),
    session:  UsageMetric(pct: 11, resetAt: Date().addingTimeInterval(3 * 3600)),
    weekly:   UsageMetric(pct: 18, resetAt: Date().addingTimeInterval(4 * 86400)),
    sonnet45: UsageMetric(pct: 12, resetAt: Date().addingTimeInterval(5 * 86400)),
    isDemo:   true
)

private func oauthJSON() -> [String: Any]? {
    let home = realHome()
    let candidates: [URL] = [
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.lekmax.ClaudeUsage"
        )?.appendingPathComponent("token-cache.json"),
        home.appendingPathComponent("Library/Group Containers/group.lekmax.ClaudeUsage/token-cache.json"),
        home.appendingPathComponent(".claude/.credentials.json"),
    ].compactMap { $0 }

    for url in candidates {
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
    }
    return nil
}

private func readOAuthToken() -> String? {
    guard let json = oauthJSON(),
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty
    else { return nil }
    // Check expiry
    let expiresAt = oauth["expiresAt"] as? Double ?? 0
    guard expiresAt > Date().timeIntervalSince1970 * 1000 else { return nil }
    return token
}

// MARK: - Cache fallback (App Group shared container)

private struct RawMetric: Codable { var pct: Double; var resetAt: String? }
private struct RawCache: Codable {
    var session: RawMetric?; var weekly: RawMetric?
    var sonnet: RawMetric?;  var sonnet45: RawMetric?
}

private func realHome() -> URL {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir))
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

/// Try every possible cache location, return first that decodes successfully.
private func readCachedEntry() -> UsageEntry? {
    let home = realHome()
    let candidates: [URL] = [
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.lekmax.ClaudeUsage"
        )?.appendingPathComponent("usage-cache.json"),
        home.appendingPathComponent("Library/Group Containers/group.lekmax.ClaudeUsage/usage-cache.json"),
        home.appendingPathComponent(".claude-widget/usage-cache.json"),
    ].compactMap { $0 }

    var raw: RawCache?
    for url in candidates {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(RawCache.self, from: data) {
            raw = decoded; break
        }
    }
    guard let raw else { return nil }

    func toDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
    func toMetric(_ m: RawMetric?) -> UsageMetric? {
        guard let m else { return nil }
        return UsageMetric(pct: m.pct, resetAt: toDate(m.resetAt))
    }
    guard let session = toMetric(raw.session),
          let weekly  = toMetric(raw.weekly)
    else { return nil }

    return UsageEntry(date: Date(), session: session, weekly: weekly,
                      sonnet45: toMetric(raw.sonnet45), isDemo: false)
}

// MARK: - Live fetch

private func fetchLiveEntry() async -> UsageEntry? {
    guard let token = readOAuthToken() else { return readCachedEntry() }

    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.httpMethod = "GET"
    req.setValue("Bearer \(token)",   forHTTPHeaderField: "Authorization")
    req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
    req.setValue("oauth-2025-04-20",  forHTTPHeaderField: "anthropic-beta")
    req.timeoutInterval = 10

    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse, http.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return readCachedEntry() }   // rate-limited or network error → use cache

    func isoDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
    func metric(_ key: String) -> UsageMetric? {
        guard let obj = json[key] as? [String: Any],
              let util = obj["utilization"] as? Double
        else { return nil }
        return UsageMetric(pct: round(util), resetAt: isoDate(obj["resets_at"] as? String))
    }

    guard let session = metric("five_hour"),
          let weekly  = metric("seven_day")
    else { return readCachedEntry() }

    return UsageEntry(date: Date(), session: session, weekly: weekly,
                      sonnet45: metric("seven_day_sonnet"), isDemo: false)
}

// MARK: - Provider

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { demoEntry }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        Task { completion(await fetchLiveEntry() ?? readCachedEntry() ?? demoEntry) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            let entry = await fetchLiveEntry() ?? readCachedEntry() ?? demoEntry
            let next = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// MARK: - Colors / helpers

private let cOrange = Color(red: 0.81, green: 0.48, blue: 0.34)

private func arcColor(_ pct: Double) -> Color {
    pct >= 90 ? .red : pct >= 70 ? Color(red: 0.93, green: 0.73, blue: 0.25) : cOrange
}

private func countdown(_ date: Date?) -> String {
    guard let d = date else { return "--" }
    let s = d.timeIntervalSinceNow
    guard s > 60 else { return "now" }
    let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
    return h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
}

// MARK: - Claude Logo Mark

struct ClaudeLogoMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26)
                .fill(cOrange)
                .frame(width: size, height: size)
                .shadow(color: cOrange.opacity(0.45), radius: size * 0.18)
            Canvas { ctx, sz in
                let cx = sz.width / 2
                let cy = sz.height / 2
                let r  = sz.width * 0.29
                let lw = sz.width * 0.13
                // 6 radiating spokes — simplified Claude asterisk mark
                let angles: [Double] = [90, 30, -30, -90, -150, 150]
                for deg in angles {
                    let rad = deg * .pi / 180
                    var path = Path()
                    path.move(to: CGPoint(x: cx + r * 0.22 * cos(rad),
                                          y: cy - r * 0.22 * sin(rad)))
                    path.addLine(to: CGPoint(x: cx + r * cos(rad),
                                             y: cy - r * sin(rad)))
                    ctx.stroke(path, with: .color(.white.opacity(0.95)),
                               style: StrokeStyle(lineWidth: lw, lineCap: .round))
                }
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Ring

struct RingView: View {
    var pct: Double
    var size: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        let c = arcColor(pct)
        let trimTo = CGFloat(min(max(pct / 100, 0), 1))
        ZStack {
            Circle()
                .stroke(c.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: trimTo)
                .stroke(c, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(pct))%")
                .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                .foregroundStyle(c)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Ring Section

struct RingSection: View {
    var label: String
    var pct: Double
    var resetAt: Date?
    var size: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        VStack(spacing: 3) {
            RingView(pct: pct, size: size, lineWidth: lineWidth)
            Text(label)
                .font(.system(size: max(size * 0.13, 9), weight: .semibold))
                .foregroundStyle(.primary)
            Text("↺ \(countdown(resetAt))")
                .font(.system(size: max(size * 0.11, 8)))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Bar View

struct BarView: View {
    var label: String
    var pct: Double
    var resetAt: Date?

    private var barColor: Color { arcColor(pct) }
    private var fill: CGFloat  { CGFloat(min(max(pct / 100, 0), 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(Int(pct))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(barColor)
                    .padding(.leading, 4)
                Text("↺ \(countdown(resetAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(barColor.opacity(0.18))
                        .frame(height: 7)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * fill, height: 7)
                }
            }
            .frame(height: 7)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Header

struct WidgetHeader: View {
    var isDemo: Bool
    var body: some View {
        HStack(spacing: 6) {
            ClaudeLogoMark(size: 16)
            Text("Claude Usage")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            if isDemo {
                Text("DEMO")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(cOrange)
            }
            Spacer()
            Text(Date(), format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Entry View

struct ClaudeUsageEntryView: View {
    var entry: UsageEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        ZStack {
            switch family {

            // ── Small: header compact, anneau centré ─────────────────────
            case .systemSmall:
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        ClaudeLogoMark(size: 18)
                        Text("Claude Usage")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    Spacer()
                    RingView(pct: entry.session.pct, size: 82, lineWidth: 9)
                    Spacer().frame(height: 8)
                    Text("Current Session")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, 2)
                    Text("↺ \(countdown(entry.session.resetAt))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            // ── Medium: anneaux ────────────────────────────────────────────
            case .systemMedium:
                VStack(spacing: 10) {
                    WidgetHeader(isDemo: entry.isDemo)
                        .padding(.bottom, 2)
                    HStack(spacing: 0) {
                        RingSection(label: "Session", pct: entry.session.pct,
                                    resetAt: entry.session.resetAt, size: 78, lineWidth: 8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        Divider().opacity(0.25)
                        RingSection(label: "Weekly", pct: entry.weekly.pct,
                                    resetAt: entry.weekly.resetAt, size: 78, lineWidth: 8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        if let s45 = entry.sonnet45 {
                            Divider().opacity(0.25)
                            RingSection(label: "Sonnet 4.5", pct: s45.pct,
                                        resetAt: s45.resetAt, size: 78, lineWidth: 8)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .padding(16)

            // ── Large: barres pour tout ────────────────────────────────────
            default:
                VStack(alignment: .leading, spacing: 0) {
                    WidgetHeader(isDemo: entry.isDemo)
                        .padding(.bottom, 6)
                    Divider().opacity(0.15)
                    Spacer().frame(height: 18)
                    BarView(label: "Session",
                            pct: entry.session.pct,
                            resetAt: entry.session.resetAt)
                    Spacer().frame(height: 18)
                    Divider().opacity(0.2)
                    Spacer().frame(height: 18)
                    BarView(label: "Weekly",
                            pct: entry.weekly.pct,
                            resetAt: entry.weekly.resetAt)
                    if let s45 = entry.sonnet45 {
                        Spacer().frame(height: 18)
                        Divider().opacity(0.2)
                        Spacer().frame(height: 18)
                        BarView(label: "Sonnet 4.5 Weekly",
                                pct: s45.pct,
                                resetAt: s45.resetAt)
                    }
                    Spacer()
                }
                .padding(20)
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                // Base verre liquide macOS 26
                Rectangle()
                    .fill(.ultraThinMaterial)
                // Halo orange doux qui accentue la couleur
                RadialGradient(
                    colors: [cOrange.opacity(0.22), cOrange.opacity(0.06), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 160
                )
                // Liseré chaud en bas
                LinearGradient(
                    colors: [.clear, cOrange.opacity(0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}

// MARK: - Widget

struct ClaudeUsageWidget: Widget {
    let kind = "ClaudeUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            ClaudeUsageEntryView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Session · Weekly · Sonnet 4.5")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Preview

#Preview(as: .systemLarge) {
    ClaudeUsageWidget()
} timeline: {
    UsageEntry(
        date: .now,
        session:  UsageMetric(pct: 42, resetAt: .now + 3 * 3600),
        weekly:   UsageMetric(pct: 18, resetAt: .now + 4 * 86400),
        sonnet45: UsageMetric(pct: 12, resetAt: .now + 5 * 86400),
        isDemo:   false
    )
}
