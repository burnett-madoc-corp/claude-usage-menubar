import AppKit
import Foundation

// MARK: - Model

/// One rate-limit window as reported by /api/oauth/usage.
struct Window {
    let label: String
    let percent: Int
    let severity: String
    let resetsAt: Date?
    let isActive: Bool
}

struct Usage {
    let session: Window?
    let weekly: Window?
    /// Per-model weekly windows (Fable, Opus, …), keyed off `limits[].scope.model.display_name`.
    let scoped: [Window]
    let extraCreditsEnabled: Bool
    let spendPercent: Int?
}

enum UsageError: LocalizedError {
    case noCredentials
    case tokenExpired
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "No Claude credentials in Keychain"
        case .tokenExpired: return "Token expired — run `claude` to refresh"
        case .http(let code): return "Usage API returned HTTP \(code)"
        }
    }
}

// MARK: - Credentials

/// Reads the OAuth access token out of the login Keychain.
///
/// We deliberately only ever *read*. Anthropic rotates refresh tokens, so
/// redeeming one here would silently invalidate the token Claude Code itself
/// holds and break its login. When the token goes stale we surface that
/// instead — running `claude` refreshes it and we pick the new one up on the
/// next poll, since the Keychain is re-read every time.
enum Credentials {
    static func accessToken() throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw UsageError.noCredentials }
        return token
    }
}

// MARK: - API client

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async throws -> Usage {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(try Credentials.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-usage-menubar/1.0", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 401 ? UsageError.tokenExpired : UsageError.http(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.http(-1)
        }
        return parse(json)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// The `limits` array is the authoritative view: it carries severity and,
    /// for per-model caps, a `scope.model.display_name` such as "Fable".
    private static func parse(_ json: [String: Any]) -> Usage {
        var session: Window?
        var weekly: Window?
        var scoped: [Window] = []

        for case let limit as [String: Any] in json["limits"] as? [Any] ?? [] {
            let percent = (limit["percent"] as? NSNumber)?.intValue ?? 0
            let severity = limit["severity"] as? String ?? "normal"
            let resets = date(limit["resets_at"])
            let active = limit["is_active"] as? Bool ?? false
            let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String

            switch limit["kind"] as? String {
            case "session":
                session = Window(label: "5-hour", percent: percent, severity: severity, resetsAt: resets, isActive: active)
            case "weekly_all":
                weekly = Window(label: "Weekly", percent: percent, severity: severity, resetsAt: resets, isActive: active)
            case "weekly_scoped":
                scoped.append(Window(label: model ?? "Weekly (scoped)", percent: percent,
                                     severity: severity, resetsAt: resets, isActive: active))
            default:
                break
            }
        }

        let extra = json["extra_usage"] as? [String: Any]
        let spend = json["spend"] as? [String: Any]
        return Usage(
            session: session,
            weekly: weekly,
            scoped: scoped,
            extraCreditsEnabled: extra?["is_enabled"] as? Bool ?? false,
            spendPercent: (spend?["percent"] as? NSNumber)?.intValue
        )
    }
}

// MARK: - Formatting

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

enum Format {
    static func color(for severity: String, percent: Int) -> NSColor {
        switch severity {
        case "critical": return .systemRed
        case "warning": return .systemOrange
        default: return percent >= 90 ? .systemRed : .labelColor
        }
    }

    /// "2h 14m", "3d 4h" — compact enough for a menu row.
    static func countdown(to date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "now" }
        let (d, h, m) = (seconds / 86400, (seconds % 86400) / 3600, (seconds % 3600) / 60)
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func bar(_ percent: Int, width: Int = 10) -> String {
        let filled = max(0, min(width, Int((Double(percent) / 100.0 * Double(width)).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }
}

// MARK: - Menu bar controller

@MainActor
final class UsageMenuBar: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private var lastUsage: Usage?
    private var lastError: Error?
    private var lastUpdated: Date?

    private let refreshInterval: TimeInterval = 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.menu = menu
        menu.delegate = self
        render()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Keep polling while a menu is open, and survive App Nap throttling.
        RunLoop.main.add(timer!, forMode: .common)
    }

    @objc func refresh() {
        Task { @MainActor in
            do {
                lastUsage = try await UsageAPI.fetch()
                lastError = nil
            } catch {
                lastError = error
            }
            lastUpdated = Date()
            render()
        }
    }

    // MARK: Title

    private func render() {
        guard let button = statusItem.button else { return }

        guard let usage = lastUsage else {
            button.attributedTitle = NSAttributedString(
                string: lastError == nil ? "◌ …" : "◌ !",
                attributes: [.foregroundColor: lastError == nil ? NSColor.secondaryLabelColor : NSColor.systemRed]
            )
            return
        }

        // Compact title: 5h and weekly, each tinted by its own severity.
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        func append(_ text: String, _ color: NSColor) {
            title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }

        if let session = usage.session {
            append("5h ", .secondaryLabelColor)
            append("\(session.percent)%", Format.color(for: session.severity, percent: session.percent))
        }
        if let weekly = usage.weekly {
            if usage.session != nil { append("  ", .secondaryLabelColor) }
            append("wk ", .secondaryLabelColor)
            append("\(weekly.percent)%", Format.color(for: weekly.severity, percent: weekly.percent))
        }
        button.attributedTitle = title
        button.toolTip = "Claude usage — updated \(lastUpdated.map(Self.clock.string(from:)) ?? "never")"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    // MARK: Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        if let error = lastError {
            addHeader(error.localizedDescription, color: .systemRed)
            if case UsageError.tokenExpired = error {
                addHeader("Run `claude` once; this picks it up automatically.", color: .secondaryLabelColor)
            }
            menu.addItem(.separator())
        }

        if let usage = lastUsage {
            addWindow(usage.session)
            addWindow(usage.weekly)
            for window in usage.scoped { addWindow(window) }

            if usage.extraCreditsEnabled, let spend = usage.spendPercent {
                menu.addItem(.separator())
                addHeader("Extra credits: \(spend)% used", color: .secondaryLabelColor)
            }
        } else if lastError == nil {
            addHeader("Loading…", color: .secondaryLabelColor)
        }

        menu.addItem(.separator())
        if let updated = lastUpdated {
            addHeader("Updated \(Self.clock.string(from: updated))", color: .tertiaryLabelColor)
        }

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private func addWindow(_ window: Window?) {
        guard let window else { return }
        let color = Format.color(for: window.severity, percent: window.percent)
        let line = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let name = window.label.padding(toLength: max(8, window.label.count + 1), withPad: " ", startingAt: 0)
        line.append(NSAttributedString(string: name, attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
        line.append(NSAttributedString(string: Format.bar(window.percent) + "  ",
                                       attributes: [.font: mono, .foregroundColor: color]))
        line.append(NSAttributedString(string: String(format: "%3d%%", window.percent),
                                       attributes: [.font: mono, .foregroundColor: color]))
        line.append(NSAttributedString(string: "   resets in \(Format.countdown(to: window.resetsAt))",
                                       attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))

        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = line
        menu.addItem(item)
    }

    private func addHeader(_ text: String, color: NSColor) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: color,
        ])
        menu.addItem(item)
    }
}

extension UsageMenuBar: NSMenuDelegate {
    // Rebuild on open so countdowns are current, and kick a fetch if data is stale.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        if let updated = lastUpdated, Date().timeIntervalSince(updated) > refreshInterval / 2 {
            refresh()
        }
    }
}

// MARK: - Entry point

// `--once` prints the same numbers to stdout and exits — handy for scripting
// and for checking the fetch/parse path without the GUI.
if CommandLine.arguments.contains("--once") {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    Task {
        do {
            let usage = try await UsageAPI.fetch()
            for window in [usage.session, usage.weekly].compactMap({ $0 }) + usage.scoped {
                let name = window.label.padding(toLength: 10, withPad: " ", startingAt: 0)
                let percent = String(window.percent).leftPadded(to: 3)
                print("\(name) \(Format.bar(window.percent)) \(percent)%  resets in \(Format.countdown(to: window.resetsAt))")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(exitCode)
}

// Top-level code always runs on the main thread, so asserting main-actor
// isolation here is sound and keeps the AppKit setup off the nonisolated path.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = UsageMenuBar()
    app.delegate = controller
    app.setActivationPolicy(.accessory) // menu bar only: no Dock icon, no app switcher entry
    app.run()
}
