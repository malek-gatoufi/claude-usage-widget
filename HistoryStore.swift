import Foundation

// MARK: - History models

struct HistoryPoint: Codable, Identifiable {
    var id: Date { date }
    var date:    Date
    var session: Double
    var weekly:  Double
    var sonnet45: Double?
    var extra:   Double?
}

// MARK: - Store

final class HistoryStore {
    static let shared = HistoryStore()

    private static let maxPoints = 7 * 24   // 7 days of hourly snapshots
    private let url: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let base = URL(fileURLWithPath: String(cString: dir))
                .appendingPathComponent(".claude-widget")
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base.appendingPathComponent("history.json")
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("claude-history.json")
    }()

    private(set) var points: [HistoryPoint] = []

    init() { load() }

    // MARK: - Read

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let pts = try? JSONDecoder().decode([HistoryPoint].self, from: data)
        else { return }
        points = pts
    }

    // MARK: - Write

    func append(_ entry: CacheEntry) {
        let now = Date()
        // Deduplicate: one point per hour
        let cal = Calendar.current
        if let last = points.last,
           cal.isDate(last.date, equalTo: now, toGranularity: .hour) {
            // Replace the current-hour point with fresher data
            points[points.count - 1] = HistoryPoint(
                date:     last.date,
                session:  entry.session.pct,
                weekly:   entry.weekly.pct,
                sonnet45: entry.sonnet45?.pct,
                extra:    entry.extra?.pct
            )
        } else {
            points.append(HistoryPoint(
                date:     now,
                session:  entry.session.pct,
                weekly:   entry.weekly.pct,
                sonnet45: entry.sonnet45?.pct,
                extra:    entry.extra?.pct
            ))
        }
        // Keep only last 7 days
        if points.count > HistoryStore.maxPoints {
            points.removeFirst(points.count - HistoryStore.maxPoints)
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
