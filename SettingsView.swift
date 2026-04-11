import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let onSave: () -> Void

    @State private var apiKeyInput:   String = ""
    @State private var hasOAuth:      Bool   = false
    @State private var hasKey:        Bool   = false
    @State private var statusMsg:     String = ""
    @State private var isGreen:       Bool   = false
    @State private var isTesting:     Bool   = false
    @State private var launchAtLogin: Bool   = false

    private let orange = Color(red: 0.81, green: 0.48, blue: 0.34)

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
            .padding(.bottom, 20)

            // ── Auth status ──────────────────────────────────────────────
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Authentification", systemImage: "key.fill")
                        .font(.subheadline.bold())

                    if hasOAuth {
                        // OAuth (Claude Pro/Max/Team) — no config needed
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connecté via Claude Pro (OAuth)")
                                    .foregroundStyle(.primary)
                                Text("Les données viennent de ~/.claude/.credentials.json")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    } else if hasKey {
                        // API key fallback
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("Clé API sauvegardée").foregroundStyle(.secondary)
                            Spacer()
                            Button("Changer") {
                                hasKey = false; apiKeyInput = ""; statusMsg = ""
                            }
                            .buttonStyle(.borderless).foregroundStyle(orange)
                        }
                    } else {
                        // No auth found
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Aucun token OAuth Claude trouvé.\nEntrez une clé API Anthropic en fallback :")
                                .font(.caption).foregroundStyle(.secondary)

                            SecureField("sk-ant-api03-…", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)

                            HStack(alignment: .center, spacing: 10) {
                                Button(isTesting ? "Test en cours…" : "Sauvegarder & Tester") {
                                    Task { await saveAndTest() }
                                }
                                .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || isTesting)
                                .buttonStyle(.borderedProminent)
                                .tint(orange)

                                if !statusMsg.isEmpty {
                                    Text(statusMsg)
                                        .font(.caption)
                                        .foregroundStyle(isGreen ? .green : .red)
                                }
                            }

                            Link("Obtenir une clé → console.anthropic.com",
                                 destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(6)
            }

            Spacer().frame(height: 12)

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
        .frame(width: 420, height: 340)
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
        hasOAuth = DataFetcher.shared.loadOAuthToken() != nil
        hasKey   = DataFetcher.shared.loadAPIKey() != nil
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func saveAndTest() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespaces)
        isTesting = true; statusMsg = ""
        do {
            try DataFetcher.shared.saveAPIKey(key)
            let entry = await DataFetcher.shared.fetch()
            isTesting = false
            if let e = entry {
                statusMsg = "✓ Session \(Int(e.session.pct))%  ·  Weekly \(Int(e.weekly.pct))%"
                isGreen = true; hasKey = true; apiKeyInput = ""
                onSave()
            } else {
                statusMsg = "✗ Clé invalide ou erreur réseau"
                isGreen = false
            }
        } catch {
            isTesting = false
            statusMsg = "✗ Erreur keychain"
            isGreen = false
        }
    }
}
