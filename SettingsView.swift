import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let onSave: () -> Void

    @State private var hasOAuth:        Bool = false
    @State private var launchAtLogin:   Bool = false
    @State private var refreshInterval: Int  = UserDefaults.standard.integer(forKey: "refreshInterval").nonZero ?? 300
    @ObservedObject private var notifMgr = NotificationManager.shared

    private let orange = Color(red: 0.81, green: 0.48, blue: 0.34)
    private let intervals = [60: "1 min", 120: "2 min", 300: "5 min", 600: "10 min"]
    private let intervalKeys = [60, 120, 300, 600]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────
            HStack(spacing: 12) {
                logoMark
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Usage").font(.headline)
                    Text("macOS Widget").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 16)

            // ── Auth status ──────────────────────────────────────────────
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Authentification", systemImage: "key.fill")
                        .font(.subheadline.bold())

                    if hasOAuth {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connecté via Claude Code (OAuth)")
                                    .foregroundStyle(.primary)
                                Text("Token lu depuis le Keychain Claude Code")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Claude Code non connecté")
                                    .foregroundStyle(.primary)
                                Text("Lancez le terminal et exécutez :")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("brew install --cask claude-code && claude login")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(6)
            }

            Spacer().frame(height: 10)

            // ── Refresh interval ─────────────────────────────────────────
            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Intervalle de rafraîchissement").font(.subheadline.bold())
                        Text("Fréquence de mise à jour des données")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $refreshInterval) {
                        ForEach(intervalKeys, id: \.self) { key in
                            Text(intervals[key] ?? "\(key)s").tag(key)
                        }
                    }
                    .frame(width: 90)
                    .onChange(of: refreshInterval) { _, val in
                        UserDefaults.standard.set(val, forKey: "refreshInterval")
                        writeServerConfig(interval: val)
                        onSave()
                    }
                }
                .padding(6)
            }

            Spacer().frame(height: 10)

            // ── Notifications ────────────────────────────────────────────
            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications de seuil").font(.subheadline.bold())
                        Text("Alerte quand un indicateur dépasse le seuil")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $notifMgr.threshold) {
                        ForEach(NotifThreshold.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .frame(width: 110)
                }
                .padding(6)
            }

            Spacer().frame(height: 10)

            // ── Launch at Login ───────────────────────────────────────────
            GroupBox {
                Toggle(isOn: $launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lancer au démarrage").font(.subheadline.bold())
                        Text("Démarrage automatique à la connexion")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .onChange(of: launchAtLogin) { _, enabled in
                    Task {
                        do {
                            if enabled { try SMAppService.mainApp.register()
                            } else     { try await SMAppService.mainApp.unregister() }
                        } catch {
                            await MainActor.run { launchAtLogin = !enabled }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 380)
        .onAppear { loadState() }
    }

    // ── Logo mark ──────────────────────────────────────────────────────
    private var logoMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(orange).frame(width: 32, height: 32)
            Canvas { ctx, sz in
                let cx = sz.width / 2, cy = sz.height / 2
                let r = sz.width * 0.28, lw = sz.width * 0.12
                for i in 0..<6 {
                    let a = Double(i) * .pi / 3
                    var p = Path()
                    p.move(to:    CGPoint(x: cx + r * 0.22 * cos(a), y: cy - r * 0.22 * sin(a)))
                    p.addLine(to: CGPoint(x: cx + r * cos(a),         y: cy - r * sin(a)))
                    ctx.stroke(p, with: .color(.white),
                               style: StrokeStyle(lineWidth: lw, lineCap: .round))
                }
            }
            .frame(width: 32, height: 32)
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────
    private func loadState() {
        hasOAuth      = DataFetcher.shared.loadOAuthToken() != nil
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Write refresh interval to ~/.claude-widget/config.json so the server picks it up.
    private func writeServerConfig(interval: Int) {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return }
        let base = URL(fileURLWithPath: String(cString: dir))
            .appendingPathComponent(".claude-widget")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let config: [String: Any] = ["refreshInterval": interval]
        if let data = try? JSONSerialization.data(withJSONObject: config) {
            try? data.write(to: base.appendingPathComponent("config.json"), options: .atomic)
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
