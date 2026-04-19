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

    private let queue = DispatchQueue(label: "lekmax.ClaudeUsage.HistoryStore")
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

    private var points: [HistoryPoint] = []

    /// Thread-safe read of all history points.
    var allPoints: [HistoryPoint] { queue.sync { points } }

    init() { queue.sync { self.load() } }

    // MARK: - Read

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let pts = try? JSONDecoder().decode([HistoryPoint].self, from: data)
        else { return }
        points = pts
    }

    // MARK: - Write

    func append(_ entry: CacheEntry) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            let cal = Calendar.current
            if let last = self.points.last,
               cal.isDate(last.date, equalTo: now, toGranularity: .hour) {
                // Replace the current-hour point with fresher data
                self.points[self.points.count - 1] = HistoryPoint(
                    date:     last.date,
                    session:  entry.session.pct,
                    weekly:   entry.weekly.pct,
                    sonnet45: entry.sonnet45?.pct,
                    extra:    entry.extra?.pct
                )
            } else {
                self.points.append(HistoryPoint(
                    date:     now,
                    session:  entry.session.pct,
                    weekly:   entry.weekly.pct,
                    sonnet45: entry.sonnet45?.pct,
                    extra:    entry.extra?.pct
                ))
            }
            if self.points.count > HistoryStore.maxPoints {
                self.points.removeFirst(self.points.count - HistoryStore.maxPoints)
            }
            self.save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
