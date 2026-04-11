import SwiftUI
import Combine

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
        }
        .menuBarExtraStyle(.menu)

        // ── Fenêtre Réglages (unique, ouverte via openWindow) ────────────
        Window("Réglages — Claude Usage", id: "settings") {
            SettingsView { model.refresh() }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 320)
    }
}

// MARK: - Model

@MainActor
final class UsageModel: ObservableObject {
    @Published var entry:  CacheEntry? = nil
    @Published var hasKey: Bool        = DataFetcher.shared.hasAuth

    var label: String {
        guard hasKey, let e = entry else { return "⚙" }
        return "\(Int(e.session.pct))%"
    }

    private var timer: Timer?

    init() {
        Task { @MainActor [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        Task {
            hasKey = DataFetcher.shared.hasAuth
            entry  = await DataFetcher.shared.fetch()
        }
    }
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
            Divider()
            Button("Actualiser") { model.refresh() }
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
