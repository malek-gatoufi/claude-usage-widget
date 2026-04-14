import UserNotifications
import Foundation

// MARK: - Notification thresholds

enum NotifThreshold: Int, CaseIterable, Identifiable {
    case disabled = 0
    case at80     = 80
    case at90     = 90

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .disabled: return "Désactivées"
        case .at80:     return "À 80%"
        case .at90:     return "À 90%"
        }
    }
}

// MARK: - Manager

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    /// Threshold chosen by the user in Settings.
    @Published var threshold: NotifThreshold = {
        let raw = UserDefaults.standard.integer(forKey: "notifThreshold")
        return NotifThreshold(rawValue: raw) ?? .at80
    }() {
        didSet { UserDefaults.standard.set(threshold.rawValue, forKey: "notifThreshold") }
    }

    // Track which metrics were already notified so we don't spam.
    // Key: metric name, Value: last pct that triggered a notification.
    private var notifiedAt: [String: Double] = [:]

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(entry: CacheEntry) {
        guard threshold != .disabled else { return }
        let limit = Double(threshold.rawValue)

        let metrics: [(String, Double)] = [
            ("Session",    entry.session.pct),
            ("Weekly",     entry.weekly.pct),
            ("Sonnet 4.5", entry.sonnet45?.pct ?? -1),
            ("Extra",      entry.extra?.pct    ?? -1),
        ].filter { $0.1 >= 0 }

        for (name, pct) in metrics {
            let wasOver = (notifiedAt[name] ?? 0) >= limit
            let isOver  = pct >= limit

            if isOver && !wasOver {
                send(metric: name, pct: pct)
                notifiedAt[name] = pct
            } else if !isOver {
                notifiedAt[name] = 0   // reset so we notify again next time it crosses
            }
        }
    }

    private func send(metric: String, pct: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Claude Usage — \(metric)"
        content.body  = "\(Int(pct))% utilisé — approche de la limite."
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "claude-usage-\(metric)-\(Int(pct))",
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(req) { _ in }
    }
}
