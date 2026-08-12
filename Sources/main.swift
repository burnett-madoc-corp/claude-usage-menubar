import AppKit
import Foundation
import Security

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
    case noCredentials, keychainBlocked, tokenExpired, http(Int)

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "No Claude credentials in Keychain"
        case .keychainBlocked:
            // Names the fix, because the dialog is easy to miss behind other
            // windows and the section stays empty until it is answered.
            return "waiting for Keychain approval — click Always Allow"
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
        let data: Data
        switch KeychainCLI.read(["find-generic-password", "-s", "Claude Code-credentials", "-w"]) {
        case .success(let payload): data = payload
        case .failure(.blocked): throw ClaudeError.keychainBlocked
        case .failure(.failed): throw ClaudeError.noCredentials // any exit status: no usable token
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
            return Card(provider: name, rows: [], error: "rate limited by usage API", rateLimited: true)
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
    // Detailed-mode (Phase 4c) bookkeeping. `detailedRowViews` parallels
    // sessionRowItems/sessionRowKeys so an in-place update can patch the
    // same SessionRowView instances rather than recreating them (needed to
    // keep the pulsing dot and expanded state alive across a tick).
    // `expandedSessionKeys` persists expanded state independently of any
    // one view instance, so it survives even a full rebuild (e.g. a
    // session reorders because new usage landed while the menu was open).
    // `isMenuOpen` gates whether a row's dot timer is allowed to run at
    // all — see the pulsing-dot run-loop trap note on SessionRowView.
    private var detailedRowViews: [SessionRowView] = []
    private var expandedSessionKeys: Set<String> = []
    private var isMenuOpen = false
    /// Every custom view in the panel is drawn to one fixed width. The old
    /// "measure the widest attributedTitle row and clamp it" approach has no
    /// input left now that the quota blocks are custom views too — and a fixed
    /// width is what stops the panel breathing as labels change length.
    private var detailedRowWidth: CGFloat { Panel.width }
    // The Anthropic usage endpoint rate-limits aggressively; Prefs enforces a
    // 60s floor (default 120s) for exactly that reason — see Prefs.swift.
    /// The user's setting is the *active* rate; PollPolicy scales the idle
    /// tiers off it. Nothing polls faster than this.
    private var baseInterval: TimeInterval { Prefs.refreshInterval() }
    /// Poll-cadence state. `lastUsageFingerprint` starts nil so the very first
    /// poll cannot be mistaken for movement.
    private var scheduledInterval: TimeInterval?
    private var lastUsageFingerprint: String?
    /// Whether the most recent poll's numbers differed from the one before.
    /// Held as state rather than recomputed inside retune(), because retune()
    /// also runs when only the session set changed — recomputing there would
    /// compare the fingerprint against itself, always yield "unchanged", and
    /// silently undo the drifting tier a moment after a poll chose it.
    private var usageMoved = false
    private var consecutiveRateLimits = 0

    /// The settings window's text fields would not accept ⌘V.
    ///
    /// AppKit dispatches ⌘X/⌘C/⌘V/⌘A by walking `NSApp.mainMenu` for a matching
    /// key equivalent and sending its action down the responder chain. This app
    /// is LSUIElement/.accessory and never built a main menu, so there was
    /// nothing to match: the keystroke was swallowed before the field editor
    /// ever saw it, and a paste silently did nothing. Right-clicking a field
    /// still offered Paste, which is why this looked like the field rejecting
    /// the text rather than the shortcut never arriving.
    ///
    /// An .accessory app never displays a menu bar, so this menu is invisible.
    /// It exists purely so those key equivalents have somewhere to resolve.
    /// Every item is left target-less on purpose — that is what sends the
    /// action to the first responder, i.e. whichever field editor is focused.
    nonisolated static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        // undo:/redo: are responder-chain conventions with no Swift-visible
        // method to point #selector at, unlike the four editing actions below.
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        return main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
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
            // Sessions load asynchronously and separately from the provider
            // poll, so the first retune() after launch would otherwise decide
            // the cadence while `sessions` was still empty — parking an
            // actively-working machine in the hourly tier until the next poll,
            // an hour away. Re-pick whenever the session set lands.
            self.retune()
        }
    }

    /// Invalidate + reschedule rather than mutating in place — Timer has no
    /// mutable interval, and this keeps .common run-loop mode registration
    /// (needed so the timer keeps firing while a menu's modal tracking loop
    /// is open) in exactly one place.
    private func scheduleTimer(interval: TimeInterval? = nil) {
        let target = interval ?? baseInterval
        // Rescheduling restarts the countdown, so only do it when the cadence
        // actually changed — otherwise a quiet-tier poll would keep pushing its
        // own next fire another hour out on every retune.
        guard scheduledInterval != target || timer == nil else { return }
        scheduledInterval = target
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: target, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Re-picks the cadence from what the last poll revealed, after every poll,
    /// so a session starting or the quota moving takes effect on the next
    /// interval rather than at some fixed re-evaluation point.
    private func retune() {
        let tier = PollPolicy.tier(
            sessionsActive: PollPolicy.isActive(sessions, now: Date()),
            usageChanged: usageMoved
        )
        scheduleTimer(interval: PollPolicy.backedOff(
            PollPolicy.interval(base: baseInterval, tier: tier),
            consecutiveRateLimits: consecutiveRateLimits
        ))
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
        // The base moved, so every tier derived from it did too — drop the memo
        // so the next scheduleTimer call is not skipped as a no-op.
        scheduledInterval = nil
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
            let fresh = await Providers.loadAll()
            // Read the rate-limit signal before merge(), which swaps a failed
            // card for the previous good rows and takes the flag with it.
            consecutiveRateLimits = fresh.contains(where: \.rateLimited) ? consecutiveRateLimits + 1 : 0
            cards = Self.merge(new: fresh, previous: cards)
            let fingerprint = PollPolicy.usageFingerprint(cards)
            usageMoved = lastUsageFingerprint.map { $0 != fingerprint } ?? false
            lastUsageFingerprint = fingerprint
            lastUpdated = Date()
            renderTitle()
            rebuildMenu()
            retune()
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
            // The staleness marker moved from the block's note line to its
            // header badge: it qualifies every row underneath it, so it
            // belongs beside the provider name rather than below the numbers.
            stale.badge = Badge(text: "stale — \(error)", kind: .amber)
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

    /// H2: a provider is only polled OR only title-shown but still gets a
    /// `Card` back from loadAll() — this decides whether that card belongs
    /// in the dropdown at all. `nil` (unrecognized name) defaults to shown,
    /// matching `Providers.shouldPoll`.
    nonisolated static func shouldShowInDropdown(_ card: Card) -> Bool {
        guard let id = ProviderID(displayName: card.provider) else { return true }
        return Prefs.showInDropdown(id)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        sessionRowItems.removeAll()
        sessionRowKeys.removeAll()
        detailedRowViews.removeAll()
        sessionOverflow = 0

        // H2: `cards` now includes providers polled for the title only (see
        // Providers.shouldPoll) — those must not also render in the
        // dropdown, so this filters on Dropdown visibility specifically
        // rather than assuming "polled" implies "shown here".
        // Quota blocks are joined by inset hairlines — they are one section,
        // not five — while the breaks before Sessions and before the footer
        // are NSMenu's own full-width separators.
        let visibleCards = cards.filter(Self.shouldShowInDropdown)
        for (index, card) in visibleCards.enumerated() {
            if index > 0 { addInsetDivider() }
            addQuotaBlock(card)
        }
        if !visibleCards.isEmpty { menu.addItem(.separator()) }

        addSessionsSection()

        if !(menu.items.last?.isSeparatorItem ?? true) { menu.addItem(.separator()) }

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

    // MARK: Sessions section
    //
    // Two first-class row styles (Prefs.sessionRowStyle()), neither a
    // fallback for the other:
    //  - Compact (Phase 4b): the same NSMenuItem.attributedTitle mechanism
    //    addRow uses, inheriting highlight, sizing, dark-mode, and
    //    accessibility rendering for free.
    //  - Detailed (Phase 4c): a custom NSMenuItem.view (SessionRowView)
    //    that hand-rolls all of the above — see SessionRowView.swift.
    // Hidden entirely (header included) when there are no live sessions or
    // Prefs.showSessions() is off.

    private func addSessionsSection() {
        guard Prefs.showSessions(), !sessions.isEmpty else { return }
        addSectionHeader("Sessions")
        let visible = Self.visibleSessions(sessions)
        let detailed = !Prefs.rendersCompact(Prefs.sessionRowStyle())
        // Detailed reads as a table, so it is ordered by what the table is
        // for — worst first. Compact keeps the recency order it was designed
        // around. Both draw the same cap/overflow selection, so switching
        // styles never changes *which* sessions you can see, only their order.
        let rows = detailed ? Self.severityOrdered(visible.rows) : visible.rows
        if detailed {
            let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            header.view = SessionHeaderView(width: detailedRowWidth)
            menu.addItem(header)
        }
        for session in rows {
            if detailed { addDetailedSessionRow(session) } else { addSessionRow(session) }
        }
        sessionOverflow = visible.overflow
        if visible.overflow > 0 {
            addLine("  +\(visible.overflow) more", color: .tertiaryLabelColor, size: 10)
        }
    }

    /// Worst-first, with most-recent activity breaking ties. The tiebreak is
    /// not cosmetic: `sorted(by:)` is not guaranteed stable, so without a
    /// total order two equally-severe rows could swap places on any tick,
    /// and every swap costs a full menu rebuild (see applySessionUpdates).
    nonisolated static func severityOrdered(_ rows: [AgentSession]) -> [AgentSession] {
        rows.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
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
        let compact = Prefs.rendersCompact(Prefs.sessionRowStyle())
        // Must apply the SAME ordering the rows were built with, or the
        // key comparison below reports a structural change on every tick
        // (and, worse, a matching key list could pair a view with the wrong
        // session's data).
        let rows = compact ? visible.rows : Self.severityOrdered(visible.rows)
        guard rows.map(Self.sessionKey) == sessionRowKeys,
              visible.overflow == sessionOverflow
        else { rebuildMenu(); return }

        if compact {
            for (item, session) in zip(sessionRowItems, rows) {
                item.attributedTitle = Self.sessionRowText(for: session)
                item.toolTip = Self.sessionTooltip(for: session)
            }
        } else {
            // Patches the SAME SessionRowView instances in place — this is
            // what lets the pulsing dot and any expanded row survive a 2s
            // tick instead of being torn down and recreated.
            for (view, session) in zip(detailedRowViews, rows) {
                view.update(session: session, animate: isMenuOpen)
            }
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

    /// Detailed-mode row (Phase 4c): a custom NSMenuItem.view. `action` is
    /// deliberately left nil — see SessionRowView's obligation-5 comment —
    /// so NSMenu never treats a click on the row as a selection that should
    /// dismiss the menu; the view handles mouseUp itself.
    ///
    /// Expanded state is seeded from expandedSessionKeys (not always
    /// false), so a session that structurally reorders — forcing
    /// rebuildMenu() instead of the in-place patch path — still reopens
    /// expanded if the user had it expanded before.
    private func addDetailedSessionRow(_ session: AgentSession) {
        let key = Self.sessionKey(for: session)
        let view = SessionRowView(
            session: session, width: detailedRowWidth,
            expanded: expandedSessionKeys.contains(key), animate: isMenuOpen
        )
        view.onToggleExpanded = { [weak self] expanded in
            guard let self else { return }
            if expanded { self.expandedSessionKeys.insert(key) } else { self.expandedSessionKeys.remove(key) }
        }
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = view
        menu.addItem(item)
        sessionRowItems.append(item)
        sessionRowKeys.append(key)
        detailedRowViews.append(view)
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

    /// A provider's whole quota block — header, badge and window rows — as one
    /// custom view. The four columns only line up if a single drawing pass
    /// owns the block, which is why this replaced the per-row attributedTitle
    /// items and their text `████░░` bars.
    private func addQuotaBlock(_ card: Card) {
        let view = QuotaBlockView(card: card, width: detailedRowWidth)
        view.onOpenSettings = { [weak self] in self?.openSettings() }
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = view
        menu.addItem(item)
    }

    private func addInsetDivider() {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = InsetDividerView(width: detailedRowWidth)
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
        // Set before rebuildMenu() so any Detailed row constructed during
        // this rebuild starts its pulsing-dot timer immediately if busy,
        // rather than waiting for the next tick.
        isMenuOpen = true
        rebuildMenu()
        if let updated = lastUpdated,
           PollPolicy.shouldRefreshOnOpen(age: Date().timeIntervalSince(updated),
                                          base: baseInterval,
                                          consecutiveRateLimits: consecutiveRateLimits) {
            refresh()
        }
        refreshSessions()

        // Session transcript files change on the order of seconds while a
        // session is active — much faster than the provider poll interval —
        // so re-scan every 2s for as long as the menu stays open. .common
        // mode is required so this keeps firing during the menu's modal
        // event-tracking loop, same reasoning as the main refresh timer
        // and each Detailed row's own dot-animation timer.
        sessionsTick?.invalidate()
        let tick = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSessions() }
        }
        RunLoop.main.add(tick, forMode: .common)
        sessionsTick = tick
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        sessionsTick?.invalidate()
        sessionsTick = nil
        // A Detailed row's animation timer is otherwise idempotent and
        // would happily keep firing forever — invalidate every one here so
        // nothing burns cycles animating a dot nobody can see.
        for view in detailedRowViews { view.stopAnimating() }
    }
}

// MARK: - Provider registry

enum Providers {
    /// H2: a provider must be polled if EITHER visibility flag would show
    /// it. Filtering on `showInDropdown` alone meant unticking Dropdown
    /// while leaving Menu bar ticked stopped ClaudeProvider/CodexProvider's
    /// `load()` from ever running again — but `headline` (what the title
    /// renders) is only ever written as a side effect of `load()`, so the
    /// title froze on whatever numbers were last polled, with no staleness
    /// marker, and read as confidently wrong quota forever. `nil` (an
    /// unrecognized name) defaults to shown, matching every other Prefs
    /// lookup's "never configured means show everything".
    nonisolated static func shouldPoll(id: ProviderID?) -> Bool {
        guard let id else { return true }
        return Prefs.showInDropdown(id) || (id.supportsTitle && Prefs.showInTitle(id))
    }

    /// `includeHidden` is the `--once` escape hatch: headless output is a
    /// diagnostic, not a display, so it deliberately ignores Prefs
    /// visibility and always reports all five providers. The live menu bar
    /// (refresh(), applicationDidFinishLaunching) always calls the default,
    /// filtered form — a provider hidden from BOTH the dropdown and the
    /// title is not polled at all; one shown in either place is.
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
        return providers.filter { shouldPoll(id: ProviderID(displayName: $0.name)) }
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

/// L9: a KeyStore whose `set` always fails — exercises LegacyImport's error
/// path without needing a real Keychain in a failed state.
private final class FailingKeyStore: KeyStore, @unchecked Sendable {
    func get(_ account: String) -> String? { nil }
    func set(_ account: String, value: String) throws {
        throw KeyStoreError.commandFailed(action: "save", code: 1)
    }
    func delete(_ account: String) throws {
        throw KeyStoreError.commandFailed(action: "delete", code: 1)
    }
}

// MARK: - Compact session-row self-tests
//
// Fixture-only — no live process, no file I/O — covering `compactLine`'s
// composition (mirroring the `headlineText` fixture-testing pattern) plus
// the sort/cap rule that feeds it. `AgentSession` fixtures below fill in
// every field explicitly via keyword args so a future field addition can't
// silently leave a test using a stale default.

// Not private: DetailedSessionRowSelfTests (SessionRowView.swift) reuses
// this exact fixture builder so Compact and Detailed self-tests can never
// silently diverge on what a given AgentSession fixture actually contains.
func makeSession(
    label: String = "session",
    taskTitle: String? = nil,
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
        kind: .claude, pid: 1, label: label, taskTitle: taskTitle,
        cwd: "/Users/alex/\(label)", model: "claude-opus-5",
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

// MARK: - Keychain-timeout self-tests
//
// The failure this guards against is silent and total: an unanswered access
// dialog blanks the whole usage section, because loadAll awaits every provider
// and a blocked one never returns. So the bound itself is asserted, not just
// the parsing around it.

/// The argument vectors handed to security(1). These are asserted because
/// getting one wrong is invisible: the build succeeds, the Settings window
/// still says "Saved", and the key lands under the wrong service or not at
/// all.
private func testKeychainCommand() {
    let service = KeychainStore.service
    let find = KeychainCommand.find(service: service, account: KeyAccount.openRouter)
    precondition(find.first == "find-generic-password")
    precondition(find.contains(service) && find.contains(KeyAccount.openRouter))
    precondition(find.contains("-w"), "without -w, security prints attributes and never the key")

    let add = KeychainCommand.add(service: service, account: KeyAccount.xai, value: "xai-secret")
    precondition(add.first == "add-generic-password")
    precondition(add.contains(service) && add.contains(KeyAccount.xai))
    precondition(add.contains("xai-secret"))
    // The regression this guards: -U updates an existing item in place, which
    // needs decrypt authorization on it and so puts the approval dialog back
    // on screen for anything written by an older build. set deletes first.
    precondition(!add.contains("-U"), "add must not update in place")

    let remove = KeychainCommand.delete(service: service, account: KeyAccount.xai)
    precondition(remove.first == "delete-generic-password")
    precondition(!remove.contains("-w"), "delete takes no value")

    // security -w terminates the password with exactly one newline.
    precondition(KeychainCommand.parse(Data("sk-or-v1-abc\n".utf8)) == "sk-or-v1-abc")
    precondition(KeychainCommand.parse(Data("sk-or-v1-abc".utf8)) == "sk-or-v1-abc")
    precondition(KeychainCommand.parse(Data()) == nil)
    precondition(KeychainCommand.parse(Data("\n".utf8)) == nil, "an empty stored password is not a key")
    // Only the delimiter comes off. Anything else the user typed was already
    // trimmed by APIKeySave.normalize, so surviving whitespace is the key.
    precondition(KeychainCommand.parse(Data("a b\n".utf8)) == "a b")
    precondition(KeychainCommand.parse(Data("tail \n".utf8)) == "tail ")

    precondition(KeychainCommand.itemNotFound == 44, "security reports a missing item as 44")
    precondition(KeychainCommand.duplicateItem == 45)
}

private func testKeychainBounds() {
    // A command that never exits must come back as .blocked within the
    // timeout, not hang — this is the actual regression being prevented.
    let started = Date()
    let result = KeychainCLI.read(["-h"], timeout: 0.1)
    if case .failure(.blocked) = result {
        preconditionFailure("`security -h` exits immediately; it must not report as blocked")
    }
    precondition(Date().timeIntervalSince(started) < 5, "a fast command must not wait out the timeout")

    // A nonexistent keychain item is a failure, never a block — the two drive
    // different messages and only one of them tells the user to click Allow.
    let missing = KeychainCLI.read(
        ["find-generic-password", "-s", "local.claude-usage-menubar.definitely-absent", "-w"]
    )
    if case .success = missing {
        preconditionFailure("a nonexistent item must not read as success")
    }
    if case .failure(.blocked) = missing {
        preconditionFailure("a missing item is .failed, not .blocked")
    }

    // The blocked message has to name the fix; the dialog is easy to miss.
    let blocked = ClaudeError.keychainBlocked.localizedDescription
    precondition(blocked.contains("Keychain"))
    precondition(blocked.contains("Allow"))
    precondition(blocked != ClaudeError.noCredentials.localizedDescription)
}

// MARK: - Edit-menu self-tests
//
// The paste bug was invisible to every existing test because nothing ever
// asserted the app had a main menu at all. These pin the mechanism: the key
// equivalents exist, and their actions are target-less so they reach the
// focused field editor rather than a fixed object.

private func testEditMenu() {
    let main = UsageMenuBar.makeMainMenu()
    let edit = main.items.compactMap(\.submenu).first { $0.title == "Edit" }
    precondition(edit != nil, "an Edit menu must exist or ⌘V has nowhere to resolve")

    let expected: [(String, String, Selector)] = [
        ("Cut", "x", #selector(NSText.cut(_:))),
        ("Copy", "c", #selector(NSText.copy(_:))),
        ("Paste", "v", #selector(NSText.paste(_:))),
        ("Select All", "a", #selector(NSText.selectAll(_:))),
    ]
    for (title, key, action) in expected {
        guard let item = edit?.items.first(where: { $0.title == title }) else {
            preconditionFailure("Edit menu is missing \(title)")
        }
        precondition(item.keyEquivalent == key)
        precondition(item.keyEquivalentModifierMask == .command)
        precondition(item.action == action)
        precondition(item.target == nil,
                     "\(title) must stay target-less so it reaches the first responder")
    }

    // Redo shares ⌘Z with Undo and is distinguished only by the shift modifier.
    let undo = edit?.items.first { $0.title == "Undo" }
    let redo = edit?.items.first { $0.title == "Redo" }
    precondition(undo?.keyEquivalent == "z" && undo?.keyEquivalentModifierMask == .command)
    precondition(redo?.keyEquivalent == "z")
    precondition(redo?.keyEquivalentModifierMask == [.command, .shift])
}

// MARK: - Detailed-table ordering self-tests
//
// Detailed rows are ordered worst-first; Compact and the `--once` printer keep
// the recency order `visibleSessions` produces. Both facts are asserted here
// so the redesign can't quietly re-order the two surfaces it left alone.

private func testSeverityOrdering() {
    let now = Date()
    // xFloor thresholds (Sessions.swift): <1.5 green, <4.0 yellow, >=7.0 red.
    let calm = makeSession(label: "calm", contextTokens: 20_000, xFloorMultiple: 1.0,
                           lastActivityAt: now)
    let warm = makeSession(label: "warm", contextTokens: 20_000, xFloorMultiple: 3.0,
                           lastActivityAt: now.addingTimeInterval(-60))
    let hot = makeSession(label: "hot", contextTokens: 20_000, xFloorMultiple: 8.0,
                          lastActivityAt: now.addingTimeInterval(-120))

    precondition(calm.severity < warm.severity && warm.severity < hot.severity,
                 "fixtures must actually span three severities for this test to mean anything")

    let ordered = UsageMenuBar.severityOrdered([calm, warm, hot])
    precondition(ordered.map(\.label) == ["hot", "warm", "calm"], "worst first")

    // Equal severity falls back to most-recent activity, giving a total order
    // — without it, an unstable sort could swap rows on any tick and force a
    // full menu rebuild every time.
    let older = makeSession(label: "older", contextTokens: 20_000, xFloorMultiple: 1.0,
                            lastActivityAt: now.addingTimeInterval(-600))
    let newer = makeSession(label: "newer", contextTokens: 20_000, xFloorMultiple: 1.0,
                            lastActivityAt: now)
    precondition(UsageMenuBar.severityOrdered([older, newer]).map(\.label) == ["newer", "older"])
    precondition(UsageMenuBar.severityOrdered([newer, older]).map(\.label) == ["newer", "older"],
                 "the tiebreak must not depend on input order")

    // A session with no activity timestamp still sorts, and still isn't dropped.
    let unknown = makeSession(label: "unknown", contextTokens: 20_000, xFloorMultiple: 1.0,
                              lastActivityAt: nil)
    precondition(UsageMenuBar.severityOrdered([unknown, newer]).map(\.label) == ["newer", "unknown"])

    // Re-ordering is Detailed-only: the shared selection helper that Compact
    // and --once use is untouched and still recency-ordered.
    precondition(UsageMenuBar.visibleSessions([calm, warm, hot]).rows.map(\.label)
                 == ["calm", "warm", "hot"],
                 "visibleSessions must stay recency-ordered for Compact and --once")
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

    // H2: the four Dropdown x Menu-bar visibility combinations for a
    // title-capable provider (.claude) — must poll whenever EITHER is on,
    // and rebuildMenu must still hide it from the dropdown when only the
    // title is on. Plus a non-title-capable provider, where title state
    // must never matter at all.
    Prefs.setShowInDropdown(.claude, true); Prefs.setShowInTitle(.claude, true)
    precondition(Providers.shouldPoll(id: .claude))
    Prefs.setShowInDropdown(.claude, true); Prefs.setShowInTitle(.claude, false)
    precondition(Providers.shouldPoll(id: .claude))
    Prefs.setShowInDropdown(.claude, false); Prefs.setShowInTitle(.claude, true)
    precondition(Providers.shouldPoll(id: .claude), "menu-bar-title-only visibility must still be polled")
    precondition(!UsageMenuBar.shouldShowInDropdown(Card(provider: "Claude", rows: [])),
                 "title-only visibility must still be hidden from the dropdown")
    Prefs.setShowInDropdown(.claude, false); Prefs.setShowInTitle(.claude, false)
    precondition(!Providers.shouldPoll(id: .claude), "both hidden must not be polled")

    Prefs.setShowInDropdown(.antigravity, false); Prefs.setShowInTitle(.antigravity, true) // no-op: doesn't support title
    precondition(!Providers.shouldPoll(id: .antigravity),
                 "a non-title-capable provider's title flag must never matter")
    precondition(Providers.shouldPoll(id: nil), "an unrecognized provider id must default to polled")

    Prefs.setShowInDropdown(.claude, true) // restore a clean default for anything reading after this point
    precondition(UsageMenuBar.shouldShowInDropdown(Card(provider: "unrecognized-name", rows: [])),
                 "an unrecognized provider name must default to shown in the dropdown")

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

    // Phase 4c ships a real Detailed renderer (SessionRowView), so Detailed
    // no longer falls back to Compact rendering.
    precondition(Prefs.rendersCompact(.compact))
    precondition(!Prefs.rendersCompact(.detailed),
                 "Phase 4c ships a Detailed renderer — Detailed must render as Detailed, not fall back")

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

        // M4: env is tier 1 of the precedence being tested here, but unlike
        // Prefs.defaults/Config.legacyPath/the KeyStore it was never
        // isolated — a real OPENROUTER_API_KEY/XAI_API_KEY in the runner's
        // environment made "None present -> nil" false and crashed the run
        // (SIGTRAP). Save and clear both up front, restore in the same
        // defer that already restores legacyPath, so this block can never
        // observe (or clobber) the user's real environment.
        let savedOpenRouterEnv = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
        let savedXaiEnv = ProcessInfo.processInfo.environment["XAI_API_KEY"]
        unsetenv("OPENROUTER_API_KEY")
        unsetenv("XAI_API_KEY")
        defer {
            if let savedOpenRouterEnv { setenv("OPENROUTER_API_KEY", savedOpenRouterEnv, 1) } else { unsetenv("OPENROUTER_API_KEY") }
            if let savedXaiEnv { setenv("XAI_API_KEY", savedXaiEnv, 1) } else { unsetenv("XAI_API_KEY") }
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

        // L15: an empty (or whitespace-only) env var must not shadow a good
        // Keychain key — `env["…"] ?? …` alone treats "" as present.
        setenv("OPENROUTER_API_KEY", "", 1)
        precondition(Config.load(store: fakeStore).openRouterKey == "keychain-or",
                     "an empty env var must not win tier 1 over a valid Keychain key")
        setenv("OPENROUTER_API_KEY", "   ", 1)
        precondition(Config.load(store: fakeStore).openRouterKey == "keychain-or",
                     "a whitespace-only env var must be treated as absent")
        unsetenv("OPENROUTER_API_KEY")

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

    // L9: LegacyImport must surface a store failure per-key instead of
    // swallowing it (the original `if (try? …) != nil` bug — indistinguishable
    // from "0 keys found to import").
    do {
        let store = FakeKeyStore()
        let clean = LegacyImport.run(legacy: (openRouterKey: "or-1", xaiKey: "xai-1"), store: store)
        precondition(clean.importedCount == 2 && clean.errors.isEmpty)
        precondition(store.get(KeyAccount.openRouter) == "or-1")
        precondition(store.get(KeyAccount.xai) == "xai-1")

        // Already-present Keychain values are left untouched, not re-imported.
        let noop = LegacyImport.run(legacy: (openRouterKey: "or-2", xaiKey: "xai-2"), store: store)
        precondition(noop.importedCount == 0 && noop.errors.isEmpty)
        precondition(store.get(KeyAccount.openRouter) == "or-1", "an existing Keychain value must win, never be overwritten by import")

        let failingStore = FailingKeyStore()
        let failed = LegacyImport.run(legacy: (openRouterKey: "or-3", xaiKey: "xai-3"), store: failingStore)
        precondition(failed.importedCount == 0, "a store failure must not be counted as a successful import")
        precondition(failed.errors.count == 2, "both key failures must be reported, not just the first")
        precondition(failed.errors.contains { $0.contains("OpenRouter") })
        precondition(failed.errors.contains { $0.contains("Grok") })
    }

    // KeychainStore must degrade, never crash, on a lookup miss — the same
    // code path a locked login keychain takes, e.g. a headless --once over
    // SSH, so Config can fall back to the legacy JSON/no-key tiers instead
    // of throwing.
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
    DetailedSessionRowSelfTests.run()
    ThemeSelfTests.run()
    QuotaBlockSelfTests.run()
    testSeverityOrdering()
    testEditMenu()
    PollPolicySelfTests.run()
    testKeychainBounds()
    testKeychainCommand()

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
            // Note and badge used to be one joined `note` string; the panel
            // now draws them in two different places, so this rejoins them to
            // keep the headless diagnostic's output exactly as it was.
            let annotations = [card.note, card.badge?.text].compactMap { $0 }
            if !annotations.isEmpty { print("  (\(annotations.joined(separator: " · ")))") }
        }

        print("Sessions")
        let sessions = await Sessions.snapshot()
        if sessions.isEmpty {
            print("  no live sessions")
        } else {
            // Reuses the same pure sort/cap/line-composition the Compact
            // dropdown row uses, so this diagnostic output and the live menu
            // can never silently disagree.
            let visible = UsageMenuBar.visibleSessions(sessions)
            for s in visible.rows {
                print("  \(UsageMenuBar.compactLine(for: s))  [\(s.kind.rawValue)] pid \(s.pid)")
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
