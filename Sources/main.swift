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

    /// Compact token-count formatter for session rows/tooltips ("1.2M",
    /// "45k") — raw counts here run into the tens of millions and would blow
    /// the row width budget.
    static func tokens(_ count: Int64) -> String {
        let value = Double(count)
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fk", value / 1_000) }
        return String(count)
    }
}

/// Maps the Sessions worse-of-two severity onto the same colour family the
/// rest of the app already uses (Format.color), so a session row and a
/// provider row agree on what "orange" means.
extension SessionScanner.Severity {
    var color: NSColor {
        switch self {
        case .green: return .systemGreen
        case .dimGreen: return NSColor.systemGreen.withAlphaComponent(0.65)
        case .yellow: return .systemYellow
        case .orange: return .systemOrange
        case .red: return .systemRed
        }
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
    private var prefsRefreshDebounce: Timer?
    private var cards: [Card] = []
    private var lastUpdated: Date?
    private var sessions: [AgentSession] = []
    // Only ticks while the menu is actually open — session files change on
    // the order of seconds, much faster than the provider poll interval, so
    // the dropdown re-scans them while visible rather than waiting for the
    // next full refresh(). Stopped in menuDidClose so it costs nothing idle.
    private var sessionsTick: Timer?
    // Identity + handles for the session rows currently in the menu, so an
    // update while the menu is open can patch them in place (see
    // applySessionUpdates) instead of rebuilding and killing the tooltip.
    private var sessionRowItems: [NSMenuItem] = []
    private var sessionRowKeys: [String] = []
    private var sessionOverflow = 0
    // The Anthropic usage endpoint rate-limits aggressively; Prefs enforces a
    // 60s floor (default 120s) for exactly that reason — see Prefs.swift.
    private var refreshInterval: TimeInterval { Prefs.refreshInterval() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.menu = menu
        menu.delegate = self
        renderTitle()
        refresh()
        refreshSessions()
        scheduleTimer()

        Prefs.onChange = { [weak self] in
            Task { @MainActor in self?.handlePrefsChanged() }
        }
    }

    /// Local/cheap by design (no network I/O) — see Sessions.swift. Called on
    /// launch, on every provider refresh, and on the menuWillOpen/2s-tick
    /// cycle below so the dropdown reflects appended transcript bytes while
    /// it's actually visible.
    private func refreshSessions() {
        Task { @MainActor in
            self.sessions = await Sessions.snapshot()
            // While the menu is open, patch rows in place; a full rebuild
            // would dismiss the tooltip the user is reading. Closed, a
            // rebuild is free and keeps the code path simple.
            if self.sessionsTick != nil { self.applySessionUpdates() } else { self.rebuildMenu() }
        }
    }

    /// Invalidate + reschedule rather than mutating in place — Timer has no
    /// mutable interval, and this keeps .common run-loop mode registration
    /// (needed so the timer keeps firing while a menu's modal tracking loop
    /// is open) in exactly one place.
    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Fires for any settings change (visibility or interval).
    ///
    /// The title is re-rendered synchronously because a title-visibility
    /// toggle needs no new data — only a redraw from the headline values
    /// already in hand.
    ///
    /// The poll itself is coalesced. A newly-shown provider does need a
    /// refresh (it has no `previous` card for merge() to fall back on), but
    /// firing one per checkbox would mean five polls of the Anthropic usage
    /// endpoint while someone ticks their way down the list — and that
    /// endpoint rate-limits aggressively enough that the app already surfaces
    /// 429s. One poll, shortly after the user stops clicking, is what's
    /// actually wanted.
    private func handlePrefsChanged() {
        scheduleTimer()
        renderTitle()
        prefsRefreshDebounce?.invalidate()
        let debounce = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(debounce, forMode: .common)
        prefsRefreshDebounce = debounce
    }

    @objc func refresh() {
        Task { @MainActor in
            cards = Self.merge(new: await Providers.loadAll(), previous: cards)
            lastUpdated = Date()
            renderTitle()
            rebuildMenu()
        }
        refreshSessions()
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

    // MARK: Title — Claude and Codex are the only providers with a headline
    // value; other providers live in the dropdown only.

    /// Plain-text title: the source of truth for the tooltip/accessibility
    /// label, and the decision renderTitle() mirrors when building the
    /// attributed (logo-bearing) version, so the two never drift apart.
    ///
    /// Both groups hidden must still produce a non-empty string — an empty
    /// title makes the status item zero-width and unclickable, and with no
    /// Dock icon (LSUIElement) that would make the app unreachable.
    nonisolated static func headlineText(
        claudeVisible: Bool, codexVisible: Bool,
        claude: (session: Int, weekly: Int)?, codex: Int?
    ) -> String {
        var groups: [String] = []
        if claudeVisible {
            let session = claude.map { "\($0.session)%" } ?? "—"
            let weekly = claude.map { "\($0.weekly)%" } ?? "—"
            groups.append("Claude 5h \(session) wk \(weekly)")
        }
        if codexVisible {
            let weekly = codex.map { "\($0)%" } ?? "—"
            groups.append("Codex wk \(weekly)")
        }
        return groups.isEmpty ? "AI" : groups.joined(separator: "   ")
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
        let claudeVisible = Prefs.showInTitle(.claude)
        let codexVisible = Prefs.showInTitle(.codex)

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

        if claudeVisible {
            appendLogo("claude-template", fallback: "Claude")
            append(" 5h ", .secondaryLabelColor)
            append(claude.map { "\($0.session)%" } ?? "—",
                   claude.map { Format.color(for: $0.severity, percent: $0.session) } ?? .secondaryLabelColor)
            append("  wk ", .secondaryLabelColor)
            append(claude.map { "\($0.weekly)%" } ?? "—",
                   claude.map { Format.color(for: $0.severity, percent: $0.weekly) } ?? .secondaryLabelColor)
        }
        if claudeVisible && codexVisible {
            append("   ", .secondaryLabelColor)
        }
        if codexVisible {
            appendLogo("codex-template", fallback: "Codex")
            append(" wk ", .secondaryLabelColor)
            append(codex.map { "\($0.percent)%" } ?? "—",
                   codex.map { Format.color(for: $0.severity, percent: $0.percent) } ?? .secondaryLabelColor)
        }
        if !claudeVisible && !codexVisible {
            // Both title providers hidden: fall back to a literal label so
            // the status item is never zero-width (see headlineText's doc).
            append("AI", .labelColor)
        }

        button.attributedTitle = title
        let plainText = Self.headlineText(
            claudeVisible: claudeVisible, codexVisible: codexVisible,
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
        sessionRowItems.removeAll()
        sessionRowKeys.removeAll()
        sessionOverflow = 0

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

        addSessionsSection()

        if let updated = lastUpdated {
            addLine("Updated \(Self.clock.string(from: updated))", color: .tertiaryLabelColor, size: 10)
        }

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    // MARK: Sessions section (Compact — Phase 4b)
    //
    // Renders through the same NSMenuItem.attributedTitle mechanism addRow
    // uses (no custom NSMenuItem.view — that's Phase 4c), so it inherits
    // highlight, sizing, dark-mode, and accessibility rendering for free.
    // Hidden entirely (header included) when there are no live sessions or
    // Prefs.showSessions() is off.

    private func addSessionsSection() {
        guard Prefs.showSessions(), !sessions.isEmpty else { return }
        addSectionHeader("Sessions")
        let visible = Self.visibleSessions(sessions)
        for session in visible.rows { addSessionRow(session) }
        sessionOverflow = visible.overflow
        if visible.overflow > 0 {
            addLine("  +\(visible.overflow) more", color: .tertiaryLabelColor, size: 10)
        }
        menu.addItem(.separator())
    }

    /// Refreshing session rows while the menu is OPEN must not rebuild the
    /// menu: `removeAllItems` destroys and recreates the item under the
    /// cursor, which dismisses its tooltip — and in Compact mode the tooltip
    /// carries cwd, reclaim and subagent burn, i.e. every detail the row
    /// itself has no width for. It also drops the keyboard highlight.
    ///
    /// So when the visible sessions are structurally unchanged (same rows, in
    /// the same order, same overflow count) only the text and tooltips are
    /// swapped in place. Anything else — a session appearing, exiting, or
    /// reordering — still needs a real rebuild.
    private func applySessionUpdates() {
        guard Prefs.showSessions(), !sessions.isEmpty else { rebuildMenu(); return }
        let visible = Self.visibleSessions(sessions)
        guard visible.rows.map(Self.sessionKey) == sessionRowKeys,
              visible.overflow == sessionOverflow
        else { rebuildMenu(); return }

        for (item, session) in zip(sessionRowItems, visible.rows) {
            item.attributedTitle = Self.sessionRowText(for: session)
            item.toolTip = Self.sessionTooltip(for: session)
        }
    }

    /// Sort by most-recent transcript activity, cap at 8 rows, report the
    /// rest as a count for a single "+N more" line — NSMenu has no internal
    /// scrolling worth fighting. Pure and nonisolated so it's fixture-testable.
    nonisolated static func visibleSessions(_ sessions: [AgentSession], cap: Int = 8) -> (rows: [AgentSession], overflow: Int) {
        let sorted = sessions.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
        guard sorted.count > cap else { return (sorted, 0) }
        return (Array(sorted.prefix(cap)), sorted.count - cap)
    }

    /// Labels truncate around 14 chars with an ellipsis so the bar column
    /// stays aligned. `padding(toLength:)` alone would silently truncate a
    /// too-long string with no ellipsis (the hazard already noted at the
    /// --once printer below) — this always applies the ellipsis itself
    /// first, then only ever pads a string that's already short enough.
    nonisolated static func truncateLabel(_ label: String, maxLength: Int) -> String {
        guard label.count > maxLength else {
            return label.padding(toLength: maxLength, withPad: " ", startingAt: 0)
        }
        let cut = String(label.prefix(maxLength - 1))
        return cut + "…"
    }

    nonisolated static let sessionLabelWidth = 14

    /// Heuristically-matched sessions (not yet possible in Phase 4a's
    /// registry-only matching, but the field exists for when they are) get a
    /// "(?)" suffix rather than folding into the fixed-width column.
    nonisolated static func sessionLabel(for session: AgentSession) -> String {
        let truncated = truncateLabel(session.label, maxLength: sessionLabelWidth)
        return session.matched ? truncated : truncated + "(?)"
    }

    /// The context bar/percent, or one of the three non-bar states the plan
    /// calls out by name: no usage yet, unknown window, or (unreachable
    /// today, since Claude sessions never leave contextTokens nil once
    /// hasUsage is true — kept for Codex, Phase 5, whose "pending" state is
    /// exactly this) a token count is known but a window truly isn't there
    /// either. A 0% bar never stands in for any of these — that would read
    /// as an empty context, the opposite of the truth.
    nonisolated static func sessionGauge(for session: AgentSession) -> String {
        if !session.hasUsage { return "starting — no usage yet" }
        if let percent = session.contextPercent {
            return "\(Format.bar(percent)) \(String(percent).leftPadded(to: 3))%"
        }
        if let tokens = session.contextTokens {
            return "\(Format.tokens(tokens)) ctx  window unknown"
        }
        return "context —"
    }

    /// `nil` under 5 deduped turns since the last compaction boundary reads
    /// as "—", never a fabricated 1.0x (Sessions.swift's contract).
    nonisolated static func sessionMultiple(for session: AgentSession) -> String {
        session.xFloorMultiple.map { String(format: "%.1fx", $0) } ?? "—"
    }

    /// "⌁0" must never render — absence of compactions is the display.
    nonisolated static func sessionCompactHint(for session: AgentSession) -> String {
        session.compactionCount > 0 ? " ⌁\(session.compactionCount)" : ""
    }

    /// Pure line composition, mirroring how `headlineText` is structured —
    /// fixture-testable with zero UI involvement. The coloured menu row
    /// below renders the same sub-strings with severity colour applied;
    /// this is the plain-text form used by self-tests, the --once printer,
    /// and as the basis for the row's accessibility text.
    nonisolated static func compactLine(for session: AgentSession) -> String {
        let dot = session.busy ? "●" : "○"
        let label = sessionLabel(for: session)
        let gauge = sessionGauge(for: session)
        let multiple = sessionMultiple(for: session)
        let turns = session.hasUsage ? "  \(session.turns)t" : ""
        let hint = sessionCompactHint(for: session)
        return "\(dot) \(label)  \(gauge)  \(multiple)\(turns)\(hint)"
    }

    /// Detail that doesn't fit on the line — cwd, last-compaction reclaim,
    /// subagent burn — rides the item's native tooltip. Compact deliberately
    /// has no click-to-expand: an attributedTitle item click natively
    /// dismisses the menu, and Compact embraces that rather than fighting it.
    nonisolated static func sessionTooltip(for session: AgentSession) -> String {
        var lines: [String] = [session.cwd]
        if let model = session.model { lines.append("model: \(model)") }
        if session.hasUsage {
            lines.append("in \(Format.tokens(session.inputTokens))  out \(Format.tokens(session.outputTokens))")
        }
        if session.compactionCount > 0 {
            let when = session.lastCompactionAt.map(Format.ago) ?? "—"
            let pre = session.lastCompactionPreCtx.map { Format.tokens($0) } ?? "—"
            let post = session.lastCompactionPostCtx.map { Format.tokens($0) } ?? "pending"
            lines.append("last compaction \(when): \(pre) → \(post)")
        }
        if let subagent = session.subagentTokens {
            lines.append("subagents: \(Format.tokens(subagent)) tokens")
        }
        if !session.matched {
            lines.append("(?) matched heuristically — the PID↔transcript link is a best guess, not exact")
        }
        return lines.joined(separator: "\n")
    }

    private func addSessionRow(_ session: AgentSession) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = Self.sessionRowText(for: session)
        item.toolTip = Self.sessionTooltip(for: session)
        menu.addItem(item)
        sessionRowItems.append(item)
        sessionRowKeys.append(Self.sessionKey(for: session))
    }

    /// Identity of a row, so an in-place update can tell "same sessions, new
    /// numbers" from "the set of sessions changed and the menu must be rebuilt".
    nonisolated static func sessionKey(for session: AgentSession) -> String {
        "\(session.kind.rawValue):\(session.pid)"
    }

    nonisolated static func sessionRowText(for session: AgentSession) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let line = NSMutableAttributedString()
        let severityColor = session.severity.color

        func append(_ text: String, _ color: NSColor) {
            line.append(NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: color]))
        }

        append("  \(session.busy ? "●" : "○") ", .labelColor)
        append(Self.sessionLabel(for: session) + "  ", .labelColor)

        if !session.hasUsage {
            append(Self.sessionGauge(for: session), .secondaryLabelColor)
        } else if session.contextPercent != nil {
            // Bar + percent are the same coloured metric — worse-of-two
            // severity, not the provider rows' 80/95-only mapping.
            append(Self.sessionGauge(for: session), severityColor)
        } else {
            append(Self.sessionGauge(for: session), .secondaryLabelColor)
        }

        append("  " + Self.sessionMultiple(for: session), severityColor)
        if session.hasUsage {
            append("  \(session.turns)t", .secondaryLabelColor)
        }
        if session.compactionCount > 0 {
            append(" ⌁\(session.compactionCount)", .secondaryLabelColor)
        }
        return line
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
        refreshSessions()

        // Session transcript files change on the order of seconds while a
        // session is active — much faster than the provider poll interval —
        // so re-scan every 2s for as long as the menu stays open. .common
        // mode is required so this keeps firing during the menu's modal
        // event-tracking loop, same reasoning as the main refresh timer.
        sessionsTick?.invalidate()
        let tick = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSessions() }
        }
        RunLoop.main.add(tick, forMode: .common)
        sessionsTick = tick
    }

    func menuDidClose(_ menu: NSMenu) {
        sessionsTick?.invalidate()
        sessionsTick = nil
    }
}

// MARK: - Provider registry

enum Providers {
    /// `includeHidden` is the `--once` escape hatch: headless output is a
    /// diagnostic, not a display, so it deliberately ignores Prefs
    /// visibility and always reports all five providers. The live menu bar
    /// (refresh(), applicationDidFinishLaunching) always calls the default,
    /// filtered form — hidden providers are not polled at all.
    static func all(includeHidden: Bool = false) -> [Provider] {
        let config = Config.load()
        let providers: [Provider] = [
            ClaudeProvider(),
            CodexProvider(),
            AntigravityProvider(),
            OpenRouterProvider(key: config.openRouterKey),
            XAIProvider(key: config.xaiKey),
        ]
        if includeHidden { return providers }
        return providers.filter { provider in
            guard let id = ProviderID(displayName: provider.name) else { return true }
            return Prefs.showInDropdown(id)
        }
    }

    /// Fetch every provider concurrently but keep registry order in the menu,
    /// so rows don't jump around between refreshes.
    static func loadAll(includeHidden: Bool = false) async -> [Card] {
        let providers = all(includeHidden: includeHidden)
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

// MARK: - Self-test support

/// In-memory KeyStore for --self-test — lets the Config.load(store:)
/// precedence logic and the Save/empty-delete semantics be exercised
/// without ever touching the real Keychain. Self-test code runs
/// single-threaded on the main thread, so a plain (unlocked) dictionary is
/// sufficient; @unchecked Sendable mirrors the pattern the headline storage
/// classes in Providers.swift/main.swift already use for the same reason.
private final class FakeKeyStore: KeyStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    func get(_ account: String) -> String? { storage[account] }
    func set(_ account: String, value: String) throws { storage[account] = value }
    func delete(_ account: String) throws { storage.removeValue(forKey: account) }
}

// MARK: - Compact session-row self-tests
//
// Fixture-only — no live process, no file I/O — covering `compactLine`'s
// composition (mirroring the `headlineText` fixture-testing pattern) plus
// the sort/cap rule that feeds it. `AgentSession` fixtures below fill in
// every field explicitly via keyword args so a future field addition can't
// silently leave a test using a stale default.

private func makeSession(
    label: String = "session",
    busy: Bool = false,
    turns: Int = 12,
    contextTokens: Int64? = 100_000,
    contextWindow: Int64? = 200_000,
    xFloorMultiple: Double? = 2.0,
    compactionCount: Int = 0,
    hasUsage: Bool = true,
    matched: Bool = true,
    lastActivityAt: Date? = nil
) -> AgentSession {
    AgentSession(
        kind: .claude, pid: 1, label: label, cwd: "/Users/alex/\(label)", model: "claude-opus-5",
        busy: busy, turns: turns, inputTokens: 1_000_000, outputTokens: 45_000, subagentTokens: nil,
        contextTokens: contextTokens, contextWindow: contextWindow, xFloorMultiple: xFloorMultiple,
        compactionCount: compactionCount, lastCompactionAt: nil, lastCompactionPreCtx: nil,
        lastCompactionPostCtx: nil, hasUsage: hasUsage, lastActivityAt: lastActivityAt, matched: matched
    )
}

private func testCompactSessionRendering() {
    // Format.tokens — the compact formatter session rows/tooltips rely on.
    precondition(Format.tokens(1_200_000) == "1.2M")
    precondition(Format.tokens(45_000) == "45k")
    precondition(Format.tokens(999) == "999")

    // Busy vs idle glyph.
    precondition(UsageMenuBar.compactLine(for: makeSession(busy: true)).hasPrefix("●"))
    precondition(UsageMenuBar.compactLine(for: makeSession(busy: false)).hasPrefix("○"))

    // ⌁N present vs absent — "⌁0" must never render; absence is the display.
    precondition(!UsageMenuBar.compactLine(for: makeSession(compactionCount: 0)).contains("⌁"))
    precondition(UsageMenuBar.compactLine(for: makeSession(compactionCount: 3)).contains("⌁3"))

    // Nil xFloor → "—", never a fabricated 1.0x.
    precondition(UsageMenuBar.sessionMultiple(for: makeSession(xFloorMultiple: nil)) == "—")
    precondition(UsageMenuBar.sessionMultiple(for: makeSession(xFloorMultiple: 3.2)) == "3.2x")

    // Unknown context window → tokens shown, no bar, "window unknown". A 0%
    // bar must never stand in for unknown.
    let unknownWindow = makeSession(contextTokens: 488_000, contextWindow: nil)
    let unknownGauge = UsageMenuBar.sessionGauge(for: unknownWindow)
    precondition(unknownGauge.contains("window unknown"))
    precondition(!unknownGauge.contains("█") && !unknownGauge.contains("░"),
                 "no bar beats a fabricated denominator")
    precondition(unknownGauge.contains("488k") || unknownGauge.contains("0.5M"),
                 "the known token count must still be shown even with no window")

    // No usage yet → label + "starting — no usage yet", no bar, no turns.
    let noUsage = makeSession(turns: 0, contextTokens: nil, contextWindow: nil, hasUsage: false)
    precondition(UsageMenuBar.sessionGauge(for: noUsage) == "starting — no usage yet")
    let noUsageLine = UsageMenuBar.compactLine(for: noUsage)
    precondition(!noUsageLine.contains("█") && !noUsageLine.contains("░"))
    precondition(!noUsageLine.contains("0t"), "turns must not render for a session with no usage yet")

    // Heuristically-matched (?) suffix.
    precondition(UsageMenuBar.sessionLabel(for: makeSession(label: "short", matched: false)).hasSuffix("(?)"))
    precondition(!UsageMenuBar.sessionLabel(for: makeSession(label: "short", matched: true)).contains("?"))
    precondition(UsageMenuBar.sessionTooltip(for: makeSession(matched: false)).contains("heuristically"))

    // Long-label truncation around 14 chars with an ellipsis, and short
    // labels pad out to the same width so the bar column stays aligned.
    let longLabel = UsageMenuBar.sessionLabel(for: makeSession(label: "a-very-long-project-directory-name"))
    precondition(longLabel.count == UsageMenuBar.sessionLabelWidth)
    precondition(longLabel.hasSuffix("…"))
    let shortLabel = UsageMenuBar.sessionLabel(for: makeSession(label: "abc"))
    precondition(shortLabel.count == UsageMenuBar.sessionLabelWidth)

    // A known context window renders the bar via the worse-of-two severity
    // colour, not the provider rows' plain percent mapping — exercised via
    // Sessions.swift's own severity(), already self-tested there; here we
    // only check the gauge text carries the bar and percent.
    let normal = makeSession(contextTokens: 84_000, contextWindow: 200_000)
    precondition(UsageMenuBar.sessionGauge(for: normal).contains("42%"))

    // Sorting: most-recent transcript activity first, cap at 8, "+N more".
    let now = Date()
    let many = (0..<10).map { i in makeSession(label: "s\(i)", lastActivityAt: now.addingTimeInterval(Double(-i))) }
    let capped = UsageMenuBar.visibleSessions(many)
    precondition(capped.rows.count == 8)
    precondition(capped.overflow == 2)
    precondition(capped.rows.first?.label == "s0", "most-recent activity must sort first")
    precondition(capped.rows.last?.label == "s7")

    let few = UsageMenuBar.visibleSessions(Array(many.prefix(5)))
    precondition(few.rows.count == 5 && few.overflow == 0)

    // A session with no activity timestamp at all must sort last, not crash
    // the comparator and not be dropped.
    let mixed = [makeSession(label: "known", lastActivityAt: now),
                 makeSession(label: "unknown", lastActivityAt: nil)]
    let mixedSorted = UsageMenuBar.visibleSessions(mixed)
    precondition(mixedSorted.rows.map(\.label) == ["known", "unknown"])
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

    // Title composition, all four visibility combinations (claudeVisible x
    // codexVisible) — including the both-hidden fallback, which must be
    // non-empty or the status item becomes a zero-width, unclickable dead
    // end (no Dock icon to fall back on).
    precondition(UsageMenuBar.headlineText(claudeVisible: true, codexVisible: true, claude: (17, 85), codex: 42)
                 == "Claude 5h 17% wk 85%   Codex wk 42%")
    precondition(UsageMenuBar.headlineText(claudeVisible: true, codexVisible: true, claude: nil, codex: 42)
                 == "Claude 5h — wk —   Codex wk 42%")
    precondition(UsageMenuBar.headlineText(claudeVisible: true, codexVisible: true, claude: (17, 85), codex: nil)
                 == "Claude 5h 17% wk 85%   Codex wk —")
    precondition(UsageMenuBar.headlineText(claudeVisible: true, codexVisible: false, claude: (17, 85), codex: 42)
                 == "Claude 5h 17% wk 85%")
    precondition(UsageMenuBar.headlineText(claudeVisible: false, codexVisible: true, claude: (17, 85), codex: 42)
                 == "Codex wk 42%")
    precondition(UsageMenuBar.headlineText(claudeVisible: false, codexVisible: false, claude: (17, 85), codex: 42)
                 == "AI")
    for claudeVisible in [true, false] {
        for codexVisible in [true, false] {
            precondition(!UsageMenuBar.headlineText(
                claudeVisible: claudeVisible, codexVisible: codexVisible, claude: nil, codex: nil
            ).isEmpty)
        }
    }

    // Provider-filter mapping: ProviderID.displayName must round-trip
    // through ProviderID(displayName:) for every case (this is the mapping
    // Providers.all() relies on to filter by Prefs.showInDropdown), and an
    // unrecognized name must not crash — it returns nil.
    for id in ProviderID.allCases {
        precondition(ProviderID(displayName: id.displayName) == id)
    }
    precondition(ProviderID(displayName: "Nonexistent") == nil)
    precondition(ProviderID.claude.displayName == "Claude")
    precondition(ProviderID.codex.displayName == "Codex")
    precondition(ProviderID.antigravity.displayName == "Antigravity")
    precondition(ProviderID.openrouter.displayName == "OpenRouter")
    precondition(ProviderID.grok.displayName == "Grok (xAI)")
    precondition(ProviderID.claude.supportsTitle && ProviderID.codex.supportsTitle)
    precondition(!ProviderID.antigravity.supportsTitle
                 && !ProviderID.openrouter.supportsTitle
                 && !ProviderID.grok.supportsTitle)

    // Prefs — run against an isolated UserDefaults suite, never
    // UserDefaults.standard, so --self-test can't clobber the user's real
    // preferences. Save/restore Prefs.defaults around the suite and wipe
    // the suite's persistent domain both before (in case a previous crashed
    // run left it dirty) and after.
    let selfTestSuite = "local.claude-usage-menubar.self-test"
    let testDefaults = UserDefaults(suiteName: selfTestSuite)!
    testDefaults.removePersistentDomain(forName: selfTestSuite)
    let savedDefaults = Prefs.defaults
    Prefs.defaults = testDefaults
    defer {
        testDefaults.removePersistentDomain(forName: selfTestSuite)
        Prefs.defaults = savedDefaults
    }

    // Unset reads true — "never configured" means "show everything".
    for id in ProviderID.allCases {
        precondition(Prefs.showInDropdown(id) == true)
        precondition(Prefs.showInTitle(id) == true)
    }
    Prefs.setShowInDropdown(.grok, false)
    precondition(Prefs.showInDropdown(.grok) == false)
    precondition(Prefs.showInDropdown(.claude) == true) // untouched keys stay default-true
    Prefs.setShowInTitle(.codex, false)
    precondition(Prefs.showInTitle(.codex) == false)
    precondition(Prefs.showInTitle(.claude) == true)

    precondition(Prefs.refreshInterval() == 120) // default
    Prefs.setRefreshInterval(5)
    precondition(Prefs.refreshInterval() == 60) // clamped low on write
    Prefs.setRefreshInterval(5000)
    precondition(Prefs.refreshInterval() == 900) // clamped high on write

    // Clamping must also apply to values read back from defaults, not just
    // values Prefs itself wrote — a hand-edited plist must not produce a
    // 5-second poll.
    testDefaults.set(5.0, forKey: "refreshInterval")
    precondition(Prefs.refreshInterval() == 60)
    testDefaults.set(5000.0, forKey: "refreshInterval")
    precondition(Prefs.refreshInterval() == 900)

    // Sessions prefs (Phase 4b). Unset showSessions reads true, matching the
    // provider-visibility flags' "never configured means show everything".
    precondition(Prefs.showSessions() == true)
    Prefs.setShowSessions(false)
    precondition(Prefs.showSessions() == false)
    Prefs.setShowSessions(true)
    precondition(Prefs.showSessions() == true)

    // The stored default is Detailed *deliberately* — see Prefs.swift — so
    // an install that never touches Settings gets the rich rows the moment
    // Phase 4c ships a renderer for them.
    precondition(Prefs.sessionRowStyle() == .detailed)
    Prefs.setSessionRowStyle(.compact)
    precondition(Prefs.sessionRowStyle() == .compact)
    Prefs.setSessionRowStyle(.detailed)
    precondition(Prefs.sessionRowStyle() == .detailed)

    // An unrecognized stored raw value (a stray value from a future build,
    // or hand-edited defaults) must not crash — falls back to the default
    // rather than blowing up SessionRowStyle(rawValue:).
    testDefaults.set("garbage-value", forKey: "sessions.rowStyle")
    precondition(Prefs.sessionRowStyle() == .detailed)
    Prefs.setSessionRowStyle(.detailed) // restore a clean value for anything reading after this point

    // Phase 4b has no Detailed renderer yet, so every stored value —
    // including the deliberate Detailed default — must still render as
    // Compact rather than draw nothing. Phase 4c flips this by changing
    // Prefs.rendersCompact's body, not by adding a second fallback path
    // somewhere else.
    precondition(Prefs.rendersCompact(.compact))
    precondition(Prefs.rendersCompact(.detailed),
                 "non-Compact must fall back to Compact rendering until Phase 4c ships a Detailed renderer")

    precondition(Format.color(for: "normal", percent: 79).isEqual(NSColor.systemGreen))
    precondition(Format.color(for: "normal", percent: 80).isEqual(NSColor.systemOrange))
    precondition(Format.color(for: "normal", percent: 95).isEqual(NSColor.systemRed))

    // Config.load(store:) precedence — env > Keychain > legacy JSON —
    // against an in-memory fake KeyStore and a temp-dir JSON fixture, so
    // none of this touches the real Keychain or the user's real config
    // file. Config.legacyPath is swappable exactly like Prefs.defaults.
    do {
        let fakeStore = FakeKeyStore()
        let savedLegacyPath = Config.legacyPath
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempConfigPath = tempDir.appendingPathComponent("config.json")
        Config.legacyPath = tempConfigPath
        defer {
            Config.legacyPath = savedLegacyPath
            try? FileManager.default.removeItem(at: tempDir)
        }

        // None present -> nil.
        precondition(Config.load(store: fakeStore).openRouterKey == nil)
        precondition(Config.load(store: fakeStore).xaiKey == nil)

        // Legacy JSON alone (tier 3).
        let legacyJSON = #"{"openrouter_key": "legacy-or", "xai_key": "legacy-xai"}"#
        try? legacyJSON.write(to: tempConfigPath, atomically: true, encoding: .utf8)
        precondition(Config.load(store: fakeStore).openRouterKey == "legacy-or")
        precondition(Config.load(store: fakeStore).xaiKey == "legacy-xai")

        // Keychain beats legacy JSON (tier 2 over tier 3) — only the key
        // that's actually set in the fake is overridden; the untouched one
        // still falls through to legacy.
        try? fakeStore.set(KeyAccount.openRouter, value: "keychain-or")
        precondition(Config.load(store: fakeStore).openRouterKey == "keychain-or")
        precondition(Config.load(store: fakeStore).xaiKey == "legacy-xai")

        // Env beats Keychain and legacy JSON (tier 1 over everything).
        setenv("OPENROUTER_API_KEY", "env-or", 1)
        precondition(Config.load(store: fakeStore).openRouterKey == "env-or")
        unsetenv("OPENROUTER_API_KEY")
        precondition(Config.load(store: fakeStore).openRouterKey == "keychain-or") // falls back once env clears

        // Keychain alone (no legacy file at all — the common case on this
        // machine per the plan: "no file" must not be an error).
        try? FileManager.default.removeItem(at: tempConfigPath)
        precondition(Config.load(store: fakeStore).openRouterKey == "keychain-or")
        precondition(Config.load(store: fakeStore).xaiKey == nil) // never set in Keychain, legacy now gone too
    }

    // Empty-string-means-delete semantics (the Save button's contract,
    // exercised as a pure function against a fake store).
    do {
        let store = FakeKeyStore()
        try? APIKeySave.apply("secret123", account: "k", store: store)
        precondition(store.get("k") == "secret123")
        try? APIKeySave.apply("", account: "k", store: store)
        precondition(store.get("k") == nil)

        // Pasted keys carry trailing whitespace/newlines; storing that
        // verbatim sends a Bearer token with a newline in it and earns an
        // undiagnosable 401. Trim on the way in, and treat whitespace-only
        // input as empty so it deletes rather than storing a blank "key".
        try? APIKeySave.apply("  secret123\n", account: "k", store: store)
        precondition(store.get("k") == "secret123")
        try? APIKeySave.apply("   \n ", account: "k", store: store)
        precondition(store.get("k") == nil)
        precondition(APIKeySave.normalize("\tsk-or-v1-abc \n") == "sk-or-v1-abc")
    }

    // KeychainStore must degrade, never crash, on a lookup miss — this is
    // the same code path errSecInteractionNotAllowed (a locked login
    // keychain, e.g. a headless --once over SSH) falls through, so Config
    // can fall back to the legacy JSON/no-key tiers instead of throwing.
    precondition(KeychainStore().get("selftest_definitely_absent_key_should_not_exist") == nil)

    // Gated real-Keychain round-trip: a throwaway account under this app's
    // own service ("local.claude-usage-menubar"), distinct from both real
    // key accounts and from "Claude Code-credentials" (a different
    // service entirely) — add -> read -> update -> delete, cleaning up
    // after itself. Skips cleanly, without failing the run, if the
    // Keychain is unavailable in this environment.
    do {
        let realStore = KeychainStore()
        let selfTestAccount = "selftest_key"
        precondition(selfTestAccount != KeyAccount.openRouter && selfTestAccount != KeyAccount.xai)

        try? realStore.delete(selfTestAccount) // clean slate if a prior run crashed mid-test

        if (try? realStore.set(selfTestAccount, value: "round-trip-1")) != nil {
            precondition(realStore.get(selfTestAccount) == "round-trip-1")
            if (try? realStore.set(selfTestAccount, value: "round-trip-2")) != nil {
                precondition(realStore.get(selfTestAccount) == "round-trip-2")
            }
            try? realStore.delete(selfTestAccount)
            precondition(realStore.get(selfTestAccount) == nil)
            print("Keychain round-trip: ran")
        } else {
            print("Keychain round-trip: skipped (Keychain unavailable)")
        }
    }

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

    SessionSelfTests.run()
    testCompactSessionRendering()

    print("Self-tests passed")
}

if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
    exit(0)
}

if CommandLine.arguments.contains("--once") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        // --once ignores visibility on purpose (Providers.all's doc
        // comment): headless output is a diagnostic, not a display, so it
        // always reports all five providers regardless of what's hidden
        // from the live dropdown/title.
        for card in await Providers.loadAll(includeHidden: true) {
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

        print("Sessions")
        let sessions = await Sessions.snapshot()
        if sessions.isEmpty {
            print("  no live Claude sessions")
        } else {
            // Reuses the same pure sort/cap/line-composition the Compact
            // dropdown row uses, so this diagnostic output and the live menu
            // can never silently disagree.
            let visible = UsageMenuBar.visibleSessions(sessions)
            for s in visible.rows {
                print("  \(UsageMenuBar.compactLine(for: s))  pid \(s.pid)")
                for detail in UsageMenuBar.sessionTooltip(for: s).split(separator: "\n") {
                    print("      \(detail)")
                }
            }
            if visible.overflow > 0 {
                print("  +\(visible.overflow) more")
            }
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
