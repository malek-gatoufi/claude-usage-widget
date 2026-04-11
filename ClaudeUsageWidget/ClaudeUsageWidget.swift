import WidgetKit
import SwiftUI

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

// MARK: - Cache reader

private struct RawMetric: Codable {
    var pct: Double
    var resetAt: String?
}
private struct RawUsage: Codable {
    var session: RawMetric?
    var weekly: RawMetric?
    var sonnet: RawMetric?
    var sonnet45: RawMetric?
    var _demo: Bool?
}

private func loadEntry() -> UsageEntry {
    let now = Date()
    let demo = UsageEntry(
        date: now,
        session:  UsageMetric(pct: 11, resetAt: now.addingTimeInterval(3 * 3600)),
        weekly:   UsageMetric(pct: 18, resetAt: now.addingTimeInterval(4 * 86400)),
        sonnet:   nil,
        sonnet45: UsageMetric(pct: 12, resetAt: now.addingTimeInterval(5 * 86400)),
        isDemo:   true
    )
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-widget/usage-cache.json")
    guard let data = try? Data(contentsOf: url),
          let raw = try? JSONDecoder().decode(RawUsage.self, from: data)
    else { return demo }

    func toDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
    func toMetric(_ m: RawMetric?) -> UsageMetric? {
        guard let m else { return nil }
        return UsageMetric(pct: m.pct, resetAt: toDate(m.resetAt))
    }
    return UsageEntry(
        date: now,
        session:  toMetric(raw.session)  ?? UsageMetric(pct: 0),
        weekly:   toMetric(raw.weekly)   ?? UsageMetric(pct: 0),
        sonnet:   toMetric(raw.sonnet),
        sonnet45: toMetric(raw.sonnet45),
        isDemo:   raw._demo ?? false
    )
}

// MARK: - Provider

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(),
                   session:  UsageMetric(pct: 11),
                   weekly:   UsageMetric(pct: 18),
                   sonnet45: UsageMetric(pct: 12),
                   isDemo:   true)
    }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(loadEntry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = loadEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
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
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(Int(pct))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(barColor)
                Text("↺ \(countdown(resetAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(barColor.opacity(0.18))
                        .frame(height: 6)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * fill, height: 6)
                }
            }
            .frame(height: 6)
        }
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
                    Spacer().frame(height: 6)
                    Text("Current Session")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("↺ \(countdown(entry.session.resetAt))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            // ── Medium: anneaux (inchangé) ─────────────────────────────────
            case .systemMedium:
                VStack(spacing: 8) {
                    WidgetHeader(isDemo: entry.isDemo)
                    HStack(spacing: 0) {
                        RingSection(label: "Session", pct: entry.session.pct,
                                    resetAt: entry.session.resetAt, size: 78, lineWidth: 8)
                            .frame(maxWidth: .infinity)
                        Divider().opacity(0.25)
                        RingSection(label: "Weekly", pct: entry.weekly.pct,
                                    resetAt: entry.weekly.resetAt, size: 78, lineWidth: 8)
                            .frame(maxWidth: .infinity)
                        if let s45 = entry.sonnet45 {
                            Divider().opacity(0.25)
                            RingSection(label: "Sonnet 4.5", pct: s45.pct,
                                        resetAt: s45.resetAt, size: 78, lineWidth: 8)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(14)

            // ── Large: barres pour tout ────────────────────────────────────
            default:
                VStack(alignment: .leading, spacing: 0) {
                    WidgetHeader(isDemo: entry.isDemo)
                    Spacer().frame(height: 16)
                    BarView(label: "Session",
                            pct: entry.session.pct,
                            resetAt: entry.session.resetAt)
                    Spacer().frame(height: 14)
                    Divider().opacity(0.2)
                    Spacer().frame(height: 14)
                    BarView(label: "Weekly",
                            pct: entry.weekly.pct,
                            resetAt: entry.weekly.resetAt)
                    if let s45 = entry.sonnet45 {
                        Spacer().frame(height: 14)
                        Divider().opacity(0.2)
                        Spacer().frame(height: 14)
                        BarView(label: "Sonnet 4.5 Weekly",
                                pct: s45.pct,
                                resetAt: s45.resetAt)
                    }
                    Spacer()
                }
                .padding(16)
            }
        }
        .containerBackground(Color(NSColor.windowBackgroundColor), for: .widget)
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
