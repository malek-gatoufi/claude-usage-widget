import SwiftUI
import AppKit

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Fenêtre minimale – fermée immédiatement, app = menu bar only
        WindowGroup("Claude Usage", id: "main") {
            Color.clear.frame(width: 1, height: 1)
        }
        .defaultSize(width: 1, height: 1)
        .windowResizability(.contentMinSize)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Ferme la fenêtre WindowGroup ouverte par SwiftUI
        DispatchQueue.main.async {
            NSApp.windows.filter { $0.title == "Claude Usage" }.forEach { $0.orderOut(nil) }
        }

        setupStatusItem()
        buildMenu()

        Task { await doRefresh() }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.doRefresh() }
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
    }

    @MainActor
    private func doRefresh() async {
        let entry = await DataFetcher.shared.fetch()
        updateButton(entry: entry)
        buildMenu(entry: entry)
    }

    @MainActor
    private func updateButton(entry: CacheEntry?) {
        if let e = entry {
            statusItem.button?.title = "\(Int(e.session.pct))%"
        } else if !DataFetcher.shared.hasAPIKey {
            statusItem.button?.title = "⚙"
        } else {
            statusItem.button?.title = "–"
        }
    }

    // MARK: Menu

    @MainActor
    private func buildMenu(entry: CacheEntry? = nil) {
        let menu = NSMenu()

        if DataFetcher.shared.hasAPIKey {
            if let e = entry {
                func row(_ title: String) -> NSMenuItem {
                    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    i.isEnabled = false
                    return i
                }
                menu.addItem(row("Session    \(Int(e.session.pct))%   ↺ \(eta(e.session.resetAtDate))"))
                menu.addItem(row("Weekly     \(Int(e.weekly.pct))%   ↺ \(eta(e.weekly.resetAtDate))"))
                if let s = e.sonnet45 {
                    menu.addItem(row("Sonnet 4.5  \(Int(s.pct))%   ↺ \(eta(s.resetAtDate))"))
                }
                menu.addItem(.separator())
            }
            let refresh = NSMenuItem(title: "Actualiser", action: #selector(manualRefresh), keyEquivalent: "r")
            refresh.target = self
            menu.addItem(refresh)
        } else {
            let noKey = NSMenuItem(title: "Aucune clé API — cliquer pour configurer",
                                   action: #selector(openSettings), keyEquivalent: "")
            noKey.target = self
            menu.addItem(noKey)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Réglages…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quitter Claude Usage",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func manualRefresh() {
        Task { await doRefresh() }
    }

    // MARK: Settings window

    @objc func openSettings() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
                styleMask:   [.titled, .closable],
                backing:     .buffered,
                defer:       false
            )
            win.title = "Réglages — Claude Usage"
            win.contentView = NSHostingView(rootView: SettingsView {
                Task { await self.doRefresh() }
            })
            win.center()
            win.delegate = self
            settingsWindow = win
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Helper

    private func eta(_ date: Date?) -> String {
        guard let d = date else { return "--" }
        let s = d.timeIntervalSinceNow
        guard s > 60 else { return "now" }
        let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
        return h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
    }
}

