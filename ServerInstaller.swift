import Foundation
import ServiceManagement

/// Installs widget-server.py and its LaunchAgent on first launch.
/// Works whether the app was installed via Homebrew, install.sh, or Xcode.
enum ServerInstaller {

    static let plistLabel = "lekmax.ClaudeUsage.WidgetData"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistLabel).plist")
    }
    static var serverURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-widget/widget-server.py")
    }

    static func setup() {
        registerLoginItem()
        if isAgentLoaded() { return }
        install()
    }

    /// Register the app as a login item so it auto-restarts at login.
    static func registerLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                // Already registered or not supported — ignore
            }
        }
    }

    // MARK: - Private

    private static func isAgentLoaded() -> Bool {
        let result = shell("launchctl", "list", plistLabel)
        return result.status == 0
    }

    @discardableResult
    private static func install() -> Bool {
        // 1. Copy widget-server.py from bundle to ~/.claude-widget/
        guard let bundleServer = Bundle.main.url(forResource: "widget-server", withExtension: "py") else {
            return false
        }
        let fm = FileManager.default
        let serverDir = serverURL.deletingLastPathComponent()
        try? fm.createDirectory(at: serverDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: serverURL)
        guard (try? fm.copyItem(at: bundleServer, to: serverURL)) != nil else { return false }

        // Make executable
        shell("/bin/chmod", "+x", serverURL.path)

        // 2. Write LaunchAgent plist
        let plistDir = plistURL.deletingLastPathComponent()
        try? fm.createDirectory(at: plistDir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(plistLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/python3</string>
                <string>\(serverURL.path)</string>
            </array>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>/tmp/ClaudeUsageWidget.log</string>
        </dict>
        </plist>
        """
        guard (try? plist.write(to: plistURL, atomically: true, encoding: .utf8)) != nil else { return false }

        // 3. Load the agent
        shell("launchctl", "unload", plistURL.path)
        let r = shell("launchctl", "load", "-w", plistURL.path)
        return r.status == 0
    }

    @discardableResult
    private static func shell(_ args: String...) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0].hasPrefix("/") ? args[0] : "/usr/bin/env")
        p.arguments = args[0].hasPrefix("/") ? Array(args.dropFirst()) : args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
