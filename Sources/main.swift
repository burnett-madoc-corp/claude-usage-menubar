import AppKit
import Foundation

// MARK: - Formatting

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

enum Format {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func color(for _: String, percent: Int) -> NSColor {
        if percent >= 95 { return .systemRed }
        if percent >= 80 { return .systemOrange }
        return .systemGreen
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

    static func ago(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let (d, h, m) = (seconds / 86400, (seconds % 86400) / 3600, (seconds % 3600) / 60)
        if d > 0 { return "\(d)d ago" }
        if h > 0 { return "\(h)h ago" }
        return m > 0 ? "\(m)m ago" : "just now"
    }

    static func usd(_ amount: Double) -> String {
        String(format: amount.magnitude < 10 ? "$%.3f" : "$%.2f", amount)
    }

    static func bar(_ percent: Int, width: Int = 10) -> String {
        let filled = max(0, min(width, Int((Double(percent) / 100.0 * Double(width)).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }
}

// MARK: - Claude

enum ClaudeError: LocalizedError {
    case noCredentials, tokenExpired, http(Int)

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "No Claude credentials in Keychain"
        case .tokenExpired: return "Token expired — run `claude` to refresh"
        case .http(let code): return "Usage API returned HTTP \(code)"
        }
    }
}

/// Reads the OAuth access token out of the login Keychain.
///
/// We deliberately only ever *read*. Anthropic rotates refresh tokens, so
/// redeeming one here would silently invalidate the token Claude Code itself
/// holds and break its login. When the token goes stale we surface that
/// instead — running `claude` refreshes it and we pick the new one up on the
/// next poll, since the Keychain is re-read every time.
enum Keychain {
    static func claudeToken() throws -> String {
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
        else { throw ClaudeError.noCredentials }
        return token
    }
}

/// The `limits` array is authoritative: it carries severity and, for per-model
/// caps, a `scope.model.display_name` such as "Fable". Scoped windows are
/// iterated rather than hardcoded, so new per-model caps appear on their own.
struct ClaudeProvider: Provider {
    let name = "Claude"

    /// Headline numbers for the menu bar title, set as a side effect of load().
    static let headline = Headline()

    final class Headline: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: (session: Int, weekly: Int, severity: String)?
        var value: (session: Int, weekly: Int, severity: String)? {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    func load() async -> Card {
        do {
            let token = try Keychain.claudeToken()
            let json = try await Net.getJSON(
                URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                bearer: token,
                extraHeaders: ["anthropic-beta": "oauth-2025-04-20"]
            )

            var rows: [Row] = []
            var session = 0, weekly = 0, worst = "normal"

            for case let limit as [String: Any] in json["limits"] as? [Any] ?? [] {
                let percent = (limit["percent"] as? NSNumber)?.intValue ?? 0
                let severity = limit["severity"] as? String ?? "normal"
                let resets = (limit["resets_at"] as? String).flatMap {
                    Format.iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
                }
                let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String

                let label: String
                switch limit["kind"] as? String {
                case "session": label = "5-hour"; session = percent
                case "weekly_all": label = "Weekly"; weekly = percent
                case "weekly_scoped": label = model ?? "Weekly (scoped)"
                default: continue
                }
                if severity == "critical" || (severity == "warning" && worst == "normal") { worst = severity }
                rows.append(Row(label: label, percent: percent,
                                detail: "resets in \(Format.countdown(to: resets))", severity: severity))
            }

            Self.headline.value = (session, weekly, worst)
            return Card(provider: name, rows: rows)
        } catch let error as NSError where error.domain == "http" && error.code == 401 {
            // Only a genuine auth failure invalidates the headline; transient
            // errors below keep the last good numbers on screen.
            Self.headline.value = nil
            return Card(provider: name, rows: [], error: ClaudeError.tokenExpired.localizedDescription)
        } catch let error as NSError where error.domain == "http" && error.code == 429 {
            return Card(provider: name, rows: [], error: "rate limited by usage API")
        } catch {
            return Card(provider: name, rows: [], error: error.localizedDescription)
        }
    }
}

// MARK: - Menu bar

@MainActor
final class UsageMenuBar: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private var cards: [Card] = []
    private var lastUpdated: Date?
    // The Anthropic usage endpoint rate-limits aggressively; 2 minutes keeps
    // well clear while still feeling live.
    private let refreshInterval: TimeInterval = 120

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.menu = menu
        menu.delegate = self
        renderTitle()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    @objc func refresh() {
        Task { @MainActor in
            cards = Self.merge(new: await Providers.loadAll(), previous: cards)
            lastUpdated = Date()
            renderTitle()
            rebuildMenu()
        }
    }

    /// A failed poll (a 429, a dropped network) should not blank a provider
    /// that was working a minute ago — keep the last good rows and mark them
    /// stale instead.
    private static func merge(new: [Card], previous: [Card]) -> [Card] {
        let byName = Dictionary(previous.map { ($0.provider, $0) }, uniquingKeysWith: { first, _ in first })
        return new.map { card in
            guard let error = card.error, card.rows.isEmpty,
                  let old = byName[card.provider], !old.rows.isEmpty
            else { return card }
            var stale = old
            stale.note = "stale — \(error)"
            return stale
        }
    }

    // MARK: Title — Claude and Codex stay visible; other providers live in the dropdown.

    nonisolated static func headlineText(claude: (session: Int, weekly: Int)?, codex: Int?) -> String {
        let session = claude.map { "\($0.session)%" } ?? "—"
        let weekly = claude.map { "\($0.weekly)%" } ?? "—"
        let codexWeekly = codex.map { "\($0)%" } ?? "—"
        return "Claude 5h \(session) wk \(weekly)   Codex wk \(codexWeekly)"
    }

    nonisolated static func logoImage(resource: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "svg"),
              let source = NSImage(contentsOf: url)
        else { return nil }

        let size = NSSize(width: 13, height: 13)
        let image = NSImage(size: size)
        image.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: size))
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let title = NSMutableAttributedString()
        let claude = ClaudeProvider.headline.value
        let codex = CodexProvider.headline.value

        func append(_ text: String, _ color: NSColor) {
            title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }

        func appendLogo(_ resource: String, fallback: String) {
            guard let image = Self.logoImage(resource: resource) else {
                append(fallback, .secondaryLabelColor)
                return
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
            title.append(NSAttributedString(attachment: attachment))
        }

        appendLogo("claude-template", fallback: "Claude")
        append(" 5h ", .secondaryLabelColor)
        append(claude.map { "\($0.session)%" } ?? "—",
               claude.map { Format.color(for: $0.severity, percent: $0.session) } ?? .secondaryLabelColor)
        append("  wk ", .secondaryLabelColor)
        append(claude.map { "\($0.weekly)%" } ?? "—",
               claude.map { Format.color(for: $0.severity, percent: $0.weekly) } ?? .secondaryLabelColor)
        append("   ", .secondaryLabelColor)
        appendLogo("codex-template", fallback: "Codex")
        append(" wk ", .secondaryLabelColor)
        append(codex.map { "\($0.percent)%" } ?? "—",
               codex.map { Format.color(for: $0.severity, percent: $0.percent) } ?? .secondaryLabelColor)

        button.attributedTitle = title
        let plainText = Self.headlineText(
            claude: claude.map { ($0.session, $0.weekly) },
            codex: codex?.percent
        )
        button.toolTip = plainText
        button.setAccessibilityLabel(plainText)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    // MARK: Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        for card in cards {
            addSectionHeader(card.provider)
            if let error = card.error {
                addLine("  \(error)", color: .systemRed, size: 11)
            }
            let labelWidth = card.rows.map(\.label.count).max() ?? 8
            for row in card.rows { addRow(row, labelWidth: labelWidth) }
            if let note = card.note {
                addLine("  \(note)", color: .tertiaryLabelColor, size: 10)
            }
            menu.addItem(.separator())
        }

        if let updated = lastUpdated {
            addLine("Updated \(Self.clock.string(from: updated))", color: .tertiaryLabelColor, size: 10)
        }

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addRow(_ row: Row, labelWidth: Int) {
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let line = NSMutableAttributedString()
        let name = "  " + row.label.padding(toLength: max(labelWidth, row.label.count) + 1,
                                            withPad: " ", startingAt: 0)
        line.append(NSAttributedString(string: name, attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))

        if let percent = row.percent {
            let color = Format.color(for: row.severity, percent: percent)
            line.append(NSAttributedString(string: Format.bar(percent) + " ",
                                          attributes: [.font: mono, .foregroundColor: color]))
            line.append(NSAttributedString(string: String(percent).leftPadded(to: 3) + "%",
                                          attributes: [.font: mono, .foregroundColor: color]))
        }
        if !row.detail.isEmpty {
            let color: NSColor = row.severity == "critical" ? .systemRed : .secondaryLabelColor
            line.append(NSAttributedString(string: (row.percent == nil ? "" : "   ") + row.detail,
                                          attributes: [.font: mono, .foregroundColor: color]))
        }

        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = line
        menu.addItem(item)
    }

    private func addSectionHeader(_ text: String) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        menu.addItem(item)
    }

    private func addLine(_ text: String, color: NSColor, size: CGFloat) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
        ])
        menu.addItem(item)
    }
}

extension UsageMenuBar: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        if let updated = lastUpdated, Date().timeIntervalSince(updated) > refreshInterval / 2 { refresh() }
    }
}

// MARK: - Provider registry

enum Providers {
    static func all() -> [Provider] {
        let config = Config.load()
        return [
            ClaudeProvider(),
            CodexProvider(),
            AntigravityProvider(),
            OpenRouterProvider(key: config.openRouterKey),
            XAIProvider(key: config.xaiKey),
        ]
    }

    /// Fetch every provider concurrently but keep registry order in the menu,
    /// so rows don't jump around between refreshes.
    static func loadAll() async -> [Card] {
        let providers = all()
        return await withTaskGroup(of: (Int, Card).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await provider.load()) }
            }
            var results: [(Int, Card)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

// MARK: - Entry point

private func runSelfTests() {
    let normalLimits: [String: Any] = [
        "primary": ["window_minutes": 300, "used_percent": 12.0],
        "secondary": ["window_minutes": 10080, "used_percent": 63.0],
    ]
    precondition(CodexProvider.extractWeeklyHeadline(from: normalLimits)?.percent == 63)
    precondition(CodexProvider.extractWeeklyHeadline(from: normalLimits)?.severity == "normal")

    let criticalLimits: [String: Any] = [
        "primary": ["window_minutes": 300, "used_percent": 12.0],
        "secondary": ["window_minutes": 10080, "used_percent": 96.0],
    ]
    precondition(CodexProvider.extractWeeklyHeadline(from: criticalLimits)?.severity == "critical")

    precondition(UsageMenuBar.headlineText(claude: (17, 85), codex: 42)
                 == "Claude 5h 17% wk 85%   Codex wk 42%")
    precondition(UsageMenuBar.headlineText(claude: nil, codex: 42)
                 == "Claude 5h — wk —   Codex wk 42%")
    precondition(UsageMenuBar.headlineText(claude: (17, 85), codex: nil)
                 == "Claude 5h 17% wk 85%   Codex wk —")

    precondition(Format.color(for: "normal", percent: 79).isEqual(NSColor.systemGreen))
    precondition(Format.color(for: "normal", percent: 80).isEqual(NSColor.systemOrange))
    precondition(Format.color(for: "normal", percent: 95).isEqual(NSColor.systemRed))

    let logo = UsageMenuBar.logoImage(resource: "codex-template")
    precondition(logo != nil)
    precondition(logo!.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)).map { bitmap in
        (0..<bitmap.pixelsHigh).contains { y in
            (0..<bitmap.pixelsWide).contains { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.alphaComponent > 0.5
                    && color.redComponent > 0.9
                    && color.greenComponent > 0.9
                    && color.blueComponent > 0.9
            }
        }
    } == true)
    print("Self-tests passed")
}

if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
    exit(0)
}

if CommandLine.arguments.contains("--once") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        for card in await Providers.loadAll() {
            print(card.provider)
            if let error = card.error { print("  \(error)") }
            let width = card.rows.map(\.label.count).max() ?? 0
            for row in card.rows {
                // padding(toLength:) truncates when the label is longer, which
                // collapses distinct model names — pad to the widest instead.
                let name = row.label.padding(toLength: max(width, 8), withPad: " ", startingAt: 0)
                let gauge = row.percent.map { "\(Format.bar($0)) \(String($0).leftPadded(to: 3))%  " } ?? ""
                print("  \(name) \(gauge)\(row.detail)")
            }
            if let note = card.note { print("  (\(note))") }
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
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
