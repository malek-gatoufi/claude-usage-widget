import SwiftUI
import Combine
import WidgetKit

// MARK: - Entry point

@main
struct ClaudeUsageApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        // ── Menu bar icon + dropdown ─────────────────────────────────────
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Text(model.label)
                .monospacedDigit()
                .foregroundStyle(model.labelColor)
        }
        .menuBarExtraStyle(.menu)

        // ── Fenêtre Réglages ─────────────────────────────────────────────
        Window("Réglages — Claude Usage", id: "settings") {
            SettingsView { model.refresh() }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 380)

        // ── Fenêtre Historique ───────────────────────────────────────────
        Window("Historique — Claude Usage", id: "history") {
            HistoryView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 540, height: 420)
    }
}

// MARK: - Model

@MainActor
final class UsageModel: ObservableObject {
    @Published var entry:  CacheEntry? = nil
    @Published var hasKey: Bool        = DataFetcher.shared.hasAuth

    // Menu bar label: shows session % when data available
    var label: String {
        guard hasKey, let e = entry else { return "⚙" }
        return "\(Int(e.session.pct))%"
    }

    // Green < 50 %, orange 50-80 %, red ≥ 80 %
    var labelColor: Color {
        guard hasKey, let e = entry else { return .primary }
        let pct = e.session.pct
        if pct >= 80 { return .red }
        if pct >= 50 { return Color(red: 0.93, green: 0.60, blue: 0.20) }
        return Color(red: 0.30, green: 0.75, blue: 0.40)
    }

    private var timer: Timer?

    init() {
        NotificationManager.shared.requestPermission()
        Task { @MainActor [weak self] in self?.refresh() }
        let interval = Double(UserDefaults.standard.integer(forKey: "refreshInterval")
                              .nonZero ?? 300)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        Task {
            hasKey = DataFetcher.shared.hasAuth
            entry  = await DataFetcher.shared.fetch()
            if let e = entry {
                HistoryStore.shared.append(e)
                NotificationManager.shared.check(entry: e)
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Restart the refresh timer with a new interval (called from Settings).
    func updateTimer(interval: Int) {
        timer?.invalidate()
        let secs = Double(interval)
        timer = Timer.scheduledTimer(withTimeInterval: secs, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
}

// MARK: - Int helper

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

// MARK: - Menu content

struct MenuBarContent: View {
    @ObservedObject var model: UsageModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Données
        if model.hasKey, let e = model.entry {
            Text("Session    \(Int(e.session.pct))%   ↺ \(eta(e.session.resetAtDate))")
                .foregroundStyle(.secondary)
            Text("Weekly    \(Int(e.weekly.pct))%   ↺ \(eta(e.weekly.resetAtDate))")
                .foregroundStyle(.secondary)
            if let s = e.sonnet45 {
                Text("Sonnet 4.5   \(Int(s.pct))%   ↺ \(eta(s.resetAtDate))")
                    .foregroundStyle(.secondary)
            }
            if let ex = e.extra {
                Text("Extra   \(Int(ex.pct))%   ↺ \(eta(ex.resetAtDate))")
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button("Actualiser") { model.refresh() }
            Button("Historique…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "history")
            }
        } else if !model.hasKey {
            Text("Aucune authentification configurée").foregroundStyle(.secondary)
            Divider()
        }

        Divider()

        Button("Réglages…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }

        Divider()

        Button("Quitter Claude Usage") { NSApp.terminate(nil) }
    }

    private func eta(_ date: Date?) -> String {
        guard let d = date else { return "--" }
        let s = d.timeIntervalSinceNow
        guard s > 60 else { return "now" }
        let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
        return h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
    }
}
