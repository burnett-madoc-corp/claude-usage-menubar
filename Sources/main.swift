import AppKit
import Foundation
import Security

// MARK: - Formatting

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

/// Headline values for the menu bar title, keyed by TitleMetric.id and
/// published by providers as a side effect of load().
///
/// One store rather than a lock-box per provider: the title now reads up to
/// seven numbers from four providers, and four bespoke singletons is three
/// too many. Mirrors the @unchecked Sendable pattern the two Headline classes
/// it replaces already used.
final class TitleValues: @unchecked Sendable {
    static let shared = TitleValues()
    private let lock = NSLock()
    private var storage: [String: HeadlineValue] = [:]

    static func set(_ id: String, _ value: HeadlineValue?) {
        shared.lock.lock(); defer { shared.lock.unlock() }
        shared.storage[id] = value
    }

    static func get(_ id: String) -> HeadlineValue? {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return shared.storage[id]
    }

    /// On an auth failure a provider's numbers are wrong, not merely old, so
    /// they must leave the title rather than sit there looking current.
    static func clear(provider: ProviderID) {
        shared.lock.lock(); defer { shared.lock.unlock() }
        for metric in TitleMetric.all where metric.provider == provider {
            shared.storage[metric.id] = nil
        }
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
        String(format: "$%.2f", amount)
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

            // Both numbers carry the worst severity of the two, which is what
            // the old tuple did; Format.color ignores it and colours by
            // percent anyway, so this only feeds the tooltip's wording.
            TitleValues.set("claude.session", HeadlineValue(percent: session, severity: worst))
            TitleValues.set("claude.weekly", HeadlineValue(percent: weekly, severity: worst))
            return Card(provider: name, rows: rows)
        } catch let error as NSError where error.domain == "http" && error.code == 401 {
            // Only a genuine auth failure invalidates the headline; transient
            // errors below keep the last good numbers on screen.
            TitleValues.clear(provider: .claude)
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

    /// What the status item thinks of itself, for --status-check.
    ///
    /// "The item is missing" is otherwise undebuggable without a screen: a
    /// zero-width button, a hidden item, and an item macOS never placed all
    /// look identical from the outside.
    func statusReport() -> String {
        let button = statusItem.button
        let title = button?.attributedTitle.string ?? "<no button>"
        return """
        isVisible      = \(statusItem.isVisible)
        length         = \(statusItem.length)
        button frame   = \(button?.frame.debugDescription ?? "<none>")
        window frame   = \(button?.window?.frame.debugDescription ?? "<no window>")
        screen         = \(button?.window?.screen?.frame.debugDescription ?? "<no screen>")
        title          = "\(title)" (\(title.count) chars)
        """
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Order matters: pull settings across from the pre-rename bundle id
        // first, so the title-metric migration below sees the legacy
        // title.<provider> flags it is meant to read.
        Prefs.migrateLegacyDomainIfNeeded()
        Prefs.migrateTitleMetricsIfNeeded()
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

    // MARK: Title — composed from TitleMetric.all, filtered by per-metric
    // prefs. A provider with no ticked metric simply contributes nothing.

    /// Plain-text title: the source of truth for the tooltip/accessibility
    /// label, and the decision renderTitle() mirrors when building the
    /// attributed (logo-bearing) version, so the two never drift apart.
    ///
    /// Consecutive metrics from one provider share a single provider name, so
    /// Claude's two numbers read "Claude 5h 17% wk 85%" rather than naming
    /// Claude twice.
    ///
    /// Both groups hidden must still produce a non-empty string — an empty
    /// title makes the status item zero-width and unclickable, and with no
    /// Dock icon (LSUIElement) that would make the app unreachable.
    nonisolated static func headlineText(_ entries: [(TitleMetric, HeadlineValue?)]) -> String {
        // Empty must stay non-empty: a zero-width status item is unclickable
        // and there is no Dock icon to fall back on.
        guard !entries.isEmpty else { return "AI" }

        var groups: [String] = []
        var current: (provider: ProviderID, parts: [String])?
        for (metric, value) in entries {
            let piece = "\(metric.shortLabel) \(value?.text ?? "—")"
            if var open = current, open.provider == metric.provider {
                open.parts.append(piece)
                current = open
            } else {
                if let open = current {
                    groups.append(([open.provider.displayName] + open.parts).joined(separator: " "))
                }
                current = (metric.provider, [piece])
            }
        }
        if let open = current {
            groups.append(([open.provider.displayName] + open.parts).joined(separator: " "))
        }
        return groups.joined(separator: "   ")
    }

    /// The metrics currently ticked, paired with whatever value their provider
    /// last published. One source for both renderTitle() and headlineText(),
    /// so the drawn title and the tooltip cannot disagree.
    nonisolated static func visibleTitleEntries() -> [(TitleMetric, HeadlineValue?)] {
        TitleMetric.all
            .filter { Prefs.showMetricInTitle($0) }
            .map { ($0, TitleValues.get($0.id)) }
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
        let entries = Self.visibleTitleEntries()

        func append(_ text: String, _ color: NSColor) {
            title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }

        func appendLogo(_ provider: ProviderID) {
            guard let image = Self.logoImage(resource: "\(provider.rawValue)-template") else {
                append(provider.displayName, .secondaryLabelColor)
                return
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
            title.append(NSAttributedString(attachment: attachment))
        }

        // Walk the registry in order, drawing each provider's mark once and
        // then its ticked numbers — mirroring headlineText's grouping exactly.
        var previousProvider: ProviderID?
        for (metric, value) in entries {
            if metric.provider != previousProvider {
                if previousProvider != nil { append("   ", .secondaryLabelColor) }
                appendLogo(metric.provider)
                previousProvider = metric.provider
            }
            append(" \(metric.shortLabel) ", .secondaryLabelColor)
            append(value?.text ?? "—",
                   value.map { Format.color(for: $0.severity, percent: $0.percent) } ?? .secondaryLabelColor)
        }
        if entries.isEmpty {
            // Every metric unticked: fall back to a literal label so the
            // status item is never zero-width (see headlineText's doc).
            append("AI", .labelColor)
        }

        button.attributedTitle = title
        let plainText = Self.headlineText(entries)
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
    /// scrolling worth fighting. 12 (up from 8): a pi+agy machine routinely
    /// runs 8-12 live agents now, and every hidden row was one the panel's
    /// whole point — "should I clear this session?" — could not answer.
    /// Pure and nonisolated so it's fixture-testable.
    nonisolated static func visibleSessions(_ sessions: [AgentSession], cap: Int = 12) -> (rows: [AgentSession], overflow: Int) {
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
    /// `load()` from ever running again — but the headline values the title
    /// renders are only ever written as a side effect of `load()`, so the
    /// title froze on whatever numbers were last polled, with no staleness
    /// marker, and read as confidently wrong quota forever. `nil` (an
    /// unrecognized name) defaults to shown, matching every other Prefs
    /// lookup's "never configured means show everything".
    nonisolated static func shouldPoll(id: ProviderID?) -> Bool {
        guard let id else { return true }
        return Prefs.showInDropdown(id)
            || TitleMetric.all.contains { $0.provider == id && Prefs.showMetricInTitle($0) }
    }

    /// `includeHidden` is the `--once` escape hatch: headless output is a
    /// diagnostic, not a display, so it deliberately ignores Prefs
    /// visibility and always reports every provider. The live menu bar
    /// (refresh(), applicationDidFinishLaunching) always calls the default,
    /// filtered form — a provider hidden from BOTH the dropdown and the
    /// title is not polled at all; one shown in either place is.
    static func all(includeHidden: Bool = false) -> [Provider] {
        // Config.load() shells out to `security` (see KeychainCLI.read) —
        // real cost, paid on every refresh. A user who hides OpenRouter from
        // both the dropdown and the title still had that subprocess run for
        // them on every poll, for a key nothing was ever going to display.
        // Skip the read entirely when OpenRouter will not be shown.
        let openRouterVisible = includeHidden || shouldPoll(id: .openrouter)
        let openRouterKey = openRouterVisible ? Config.load().openRouterKey : nil
        let providers: [Provider] = [
            ClaudeProvider(),
            CodexProvider(),
            OpenRouterProvider(key: openRouterKey),
            AntigravityProvider(),
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
        cwd: "/Users/dev/\(label)", model: "claude-opus-5",
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

    // Sorting: most-recent transcript activity first, cap at 12, "+N more".
    let now = Date()
    let many = (0..<15).map { i in makeSession(label: "s\(i)", lastActivityAt: now.addingTimeInterval(Double(-i))) }
    let capped = UsageMenuBar.visibleSessions(many)
    precondition(capped.rows.count == 12)
    precondition(capped.overflow == 3)
    precondition(capped.rows.first?.label == "s0", "most-recent activity must sort first")
    precondition(capped.rows.last?.label == "s11")

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

    // The value must never appear as a bare, unquoted argv-shaped token —
    // it goes to security(1) on stdin (see addLine), specifically so it
    // never becomes a `ps`-visible argument in the first place.
    let addLine = KeychainCommand.addLine(service: service, account: KeyAccount.openRouter, value: "or-secret")
    precondition(addLine.hasPrefix("add-generic-password "))
    precondition(addLine.contains(service) && addLine.contains(KeyAccount.openRouter))
    precondition(addLine.contains("-w \"or-secret\""), "the value must be quoted, not a bare argv-shaped token")
    // The regression this guards: -U updates an existing item in place, which
    // needs decrypt authorization on it and so puts the approval dialog back
    // on screen for anything written by an older build. set deletes first.
    precondition(!addLine.contains("-U"), "add must not update in place")

    // Quoting must round-trip a value carrying both characters the stdin
    // parser treats specially — backslash and the closing quote itself —
    // or a pasted key containing either would truncate mid-line and either
    // store garbage or hand the rest to the parser as a second command.
    let tricky = KeychainCommand.quoteForStdin("a\"b\\c")
    precondition(tricky == "\"a\\\"b\\\\c\"", "backslash and double-quote must both be escaped")

    let remove = KeychainCommand.delete(service: service, account: KeyAccount.openRouter)
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

/// A read left parked behind an approval dialog must not be re-issued every
/// poll — that is the difference between one dialog and an endless stream of
/// them. Uses a scratch account so it cannot touch the real key.
private func testBlockedAccounts() {
    let scratch = "selftest_blocked_account"
    precondition(scratch != KeyAccount.openRouter)
    let blocked = BlockedAccounts.shared
    blocked.remove(scratch)
    precondition(!blocked.contains(scratch))

    blocked.insert(scratch)
    precondition(blocked.contains(scratch))
    // Short-circuits before spawning security at all: a blocked account reads
    // as "no key" without going near the Keychain.
    let started = Date()
    precondition(KeychainStore().get(scratch) == nil)
    precondition(Date().timeIntervalSince(started) < 0.05,
                 "a blocked account must not reach security(1) again")

    // Writing the account repairs the item, so the block must lift with it —
    // otherwise a user who re-saves their key still gets no key.
    if (try? KeychainStore().set(scratch, value: "repaired")) != nil {
        precondition(!blocked.contains(scratch), "a successful save must clear the block")
        precondition(KeychainStore().get(scratch) == "repaired")
        try? KeychainStore().delete(scratch)
    }
    blocked.remove(scratch)
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

    // MARK: Title composition
    //
    // REGRESSION GUARD: with default prefs the title must be byte-identical
    // to what the old hardcoded renderTitle() produced. If the first
    // assertion below ever needs "updating", this refactor has silently
    // widened everyone's menu bar.
    let mClaudeSession = TitleMetric.metric(id: "claude.session")!
    let mClaudeWeekly = TitleMetric.metric(id: "claude.weekly")!
    let mCodexWeekly = TitleMetric.metric(id: "codex.weekly")!
    let mAgyWeekly = TitleMetric.metric(id: "antigravity.3p-weekly")!
    let vSession = HeadlineValue(percent: 17, severity: "normal")
    let vWeekly = HeadlineValue(percent: 85, severity: "warning")
    let vCodex = HeadlineValue(percent: 42, severity: "normal")
    let vAgy = HeadlineValue(percent: 75, severity: "normal")

    precondition(UsageMenuBar.headlineText([(mClaudeSession, vSession), (mClaudeWeekly, vWeekly),
                                            (mCodexWeekly, vCodex)])
                 == "Claude 5h 17% wk 85%   Codex wk 42%",
                 "the default title must not change shape")
    precondition(UsageMenuBar.headlineText([(mClaudeSession, vSession), (mClaudeWeekly, vWeekly),
                                            (mCodexWeekly, vCodex), (mAgyWeekly, vAgy)])
                 == "Claude 5h 17% wk 85%   Codex wk 42%   Antigravity 3p wk 75%")
    // A provider named once per run of consecutive metrics, not once per metric.
    precondition(UsageMenuBar.headlineText([(mClaudeSession, vSession), (mClaudeWeekly, vWeekly)])
                 == "Claude 5h 17% wk 85%")
    precondition(UsageMenuBar.headlineText([(mCodexWeekly, vCodex)]) == "Codex wk 42%")
    // A single Antigravity metric ticked on its own still names its provider.
    precondition(UsageMenuBar.headlineText([(mAgyWeekly, vAgy)]) == "Antigravity 3p wk 75%")
    // A metric whose provider has not reported yet renders an em dash — not a
    // stale number, and not a missing column.
    precondition(UsageMenuBar.headlineText([(mCodexWeekly, nil)]) == "Codex wk —")
    precondition(UsageMenuBar.headlineText([(mClaudeSession, nil), (mClaudeWeekly, nil)])
                 == "Claude 5h — wk —")
    // A non-percentage headline draws its own text. The percent is still
    // there, colouring it, but never reaches the bar.
    let mCredit = TitleMetric.metric(id: "openrouter.credit")!
    let vCredit = OpenRouterProvider.headline(granted: 20, used: 11.58)
    precondition(vCredit.text == "$8.42")
    precondition(vCredit.percent == 58, "colour comes from spend against the grant")
    precondition(vCredit.severity == "normal")
    precondition(UsageMenuBar.headlineText([(mCredit, vCredit)]) == "OpenRouter cr $8.42")
    precondition(UsageMenuBar.headlineText([(mCodexWeekly, vCodex), (mCredit, vCredit)])
                 == "Codex wk 42%   OpenRouter cr $8.42")
    // Overdrawn: the balance goes negative and the colour goes critical.
    let vOverdrawn = OpenRouterProvider.headline(granted: 20, used: 20.17)
    precondition(vOverdrawn.text == "$-0.17")
    precondition(vOverdrawn.severity == "critical")
    // Nothing granted: no denominator, so the balance itself decides the
    // colour rather than a meaningless 0%. An empty account is empty whether
    // it got there by spending or by never being funded.
    precondition(OpenRouterProvider.headline(granted: 0, used: 3).severity == "critical")
    precondition(OpenRouterProvider.headline(granted: 0, used: 0).severity == "critical")
    precondition(OpenRouterProvider.headline(granted: 0, used: -3).severity == "warning",
                 "a small positive balance with no grant warns rather than alarms")
    precondition(OpenRouterProvider.headline(granted: 0, used: -20).severity == "normal")

    // MARK: Top-up ledger — the API only exposes LIFETIME totals, so usage
    // since the last top-up must be detected locally. A grown grant IS the
    // top-up; its delta is the cycle grant. (Numbers chosen so every
    // subtraction is exact in binary — a float here would be a lie.)
    let atTopup = Date(timeIntervalSinceReferenceDate: 700_000_000)

    // First poll on an upgrading install: no history exists, so the current
    // balance seeds the cycle — spend counts against it, not lifetime.
    let seededLedger = OpenRouterProvider.update(ledger: nil, granted: 20, used: 11, now: atTopup)
    precondition(seededLedger.lastTotalCredits == 20)
    precondition(seededLedger.topup?.seeded == true)
    precondition(seededLedger.topup?.granted == 9, "seeded grant = current balance")
    precondition(seededLedger.topup?.usageAtTopup == 11)

    // Subsequent polls without a top-up must keep the cycle untouched.
    let steady = OpenRouterProvider.update(ledger: seededLedger, granted: 20, used: 12, now: atTopup)
    precondition(steady.topup == seededLedger.topup, "a poll where the grant did not move must not touch the cycle")

    // A grown grant IS the top-up: delta = cycle grant, lifetime usage at
    // that moment starts the cycle counter, seeded flag retires.
    let toppedUp = OpenRouterProvider.update(ledger: seededLedger, granted: 30, used: 13, now: atTopup)
    precondition(toppedUp.lastTotalCredits == 30)
    precondition(toppedUp.topup?.granted == 10)
    precondition(toppedUp.topup?.usageAtTopup == 13)
    precondition(toppedUp.topup?.seeded == false)

    // Cycle-aware headline: spend since the top-up against the top-up.
    let cycleHeadline = OpenRouterProvider.headline(ledger: toppedUp, granted: 30, used: 18)
    precondition(cycleHeadline.percent == 50, "used $5 of the $10 top-up → 50%")
    precondition(cycleHeadline.display == "$12.00", "display stays the remaining balance")
    precondition(cycleHeadline.severity == "normal")

    // Past the cycle grant, the percent clamps at 100 and goes critical —
    // the top-up is burned and the old balance is being eaten.
    let burned = OpenRouterProvider.headline(ledger: toppedUp, granted: 30, used: 28.5)
    precondition(burned.percent == 100)
    precondition(burned.severity == "critical")

    // A SHRUNK grant (adjustment/revocation) makes lifetime totals
    // incomparable — tracking restarts and the card falls back to lifetime.
    let shrunk = OpenRouterProvider.update(ledger: toppedUp, granted: 25, used: 14, now: atTopup)
    precondition(shrunk.topup == nil)
    precondition(shrunk.lastTotalCredits == 25)
    precondition(OpenRouterProvider.headline(ledger: shrunk, granted: 25, used: 14).percent == 56,
                 "no cycle → lifetime ratio")

    // Sub-cent grant movement is float noise, not a top-up.
    let noise = OpenRouterProvider.update(ledger: toppedUp, granted: 30.004, used: 13.1, now: atTopup)
    precondition(noise.topup?.granted == 10)
    // A plain percentage metric carries no display string, so nothing changed
    // for the numbers that were already there.
    precondition(vCodex.display == nil && vCodex.text == "42%")

    // Everything unticked must still produce a non-empty title, or the status
    // item becomes a zero-width, unclickable dead end.
    precondition(UsageMenuBar.headlineText([]) == "AI")
    // No combination of missing values may ever yield an empty title.
    for count in 0...TitleMetric.all.count {
        precondition(!UsageMenuBar.headlineText(
            TitleMetric.all.prefix(count).map { ($0, nil) }
        ).isEmpty)
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
    precondition(ProviderID.openrouter.displayName == "OpenRouter")
    precondition(ProviderID.claude.ownsTitleMetrics && ProviderID.codex.ownsTitleMetrics)
    precondition(ProviderID.antigravity.ownsTitleMetrics)
    precondition(ProviderID.openrouter.ownsTitleMetrics,
                 "OpenRouter publishes a credit balance, so it owns a metric")

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

    // Ledger persistence — placed BELOW the suite swap deliberately. The
    // cycle must survive an app relaunch, or the top-up detected before it
    // is forgotten; but saveLedger writes wherever Prefs.defaults points,
    // and the self-tests above this line run against the real suite.
    OpenRouterProvider.saveLedger(toppedUp)
    let reloaded = OpenRouterProvider.loadLedger()
    precondition(reloaded == toppedUp, "ledger must round-trip byte-stable through the scratch suite")
    precondition(reloaded?.topup?.topupAt == atTopup)
    OpenRouterProvider.saveLedger(OpenRouterProvider.update(ledger: nil, granted: 0, used: 0, now: atTopup))
    precondition(OpenRouterProvider.loadLedger()?.topup == nil)

    // Unset reads true — "never configured" means "show everything".
    for id in ProviderID.allCases {
        precondition(Prefs.showInDropdown(id) == true)
    }
    Prefs.setShowInDropdown(.openrouter, false)
    precondition(Prefs.showInDropdown(.openrouter) == false)
    precondition(Prefs.showInDropdown(.claude) == true) // untouched keys stay default-true

    // MARK: Title metric registry
    precondition(TitleMetric.all.count == 8)
    precondition(TitleMetric.all.map(\.id) == [
        "claude.session", "claude.weekly", "codex.weekly", "openrouter.credit",
        "antigravity.gemini-5h", "antigravity.gemini-weekly",
        "antigravity.3p-5h", "antigravity.3p-weekly",
    ], "registry order is title order, shortest window first")
    // Antigravity's Gemini pair drops the family prefix — the logo already
    // names the provider, so only the third-party buckets label themselves.
    precondition(TitleMetric.metric(id: "antigravity.gemini-weekly")!.shortLabel == "wk")
    precondition(TitleMetric.metric(id: "antigravity.gemini-5h")!.shortLabel == "5h")
    // The title must not grow on upgrade: only today's three numbers default on.
    precondition(TitleMetric.all.filter(\.defaultOn).map(\.id)
                 == ["claude.session", "claude.weekly", "codex.weekly"])
    // Unset reads the metric's own default, not a blanket true.
    for metric in TitleMetric.all {
        precondition(Prefs.showMetricInTitle(metric) == metric.defaultOn)
    }
    let geminiWeekly = TitleMetric.metric(id: "antigravity.gemini-weekly")!
    let codexWeeklyMetric = TitleMetric.metric(id: "codex.weekly")!
    let claudeSessionMetric = TitleMetric.metric(id: "claude.session")!
    Prefs.setShowMetricInTitle(geminiWeekly, true)
    precondition(Prefs.showMetricInTitle(geminiWeekly))
    Prefs.setShowMetricInTitle(codexWeeklyMetric, false)
    precondition(!Prefs.showMetricInTitle(codexWeeklyMetric))
    precondition(Prefs.showMetricInTitle(claudeSessionMetric), "untouched metrics keep their default")

    // Legacy bundle-id domain: only keys this app owns come across, and an
    // existing value in the new domain always wins. A blanket copy would drag
    // in the global domain and pin those values per-app. The foreign key
    // below is deliberately a made-up name: a real global key like
    // AppleLanguages reads back through NSGlobalDomain from any suite, so it
    // could never prove anything.
    testDefaults.removePersistentDomain(forName: selfTestSuite)
    let legacyProbe = "local.claude-usage-menubar.self-test-legacy"
    let legacyDefaults = UserDefaults(suiteName: legacyProbe)!
    legacyDefaults.removePersistentDomain(forName: legacyProbe)
    legacyDefaults.set(false, forKey: "dropdown.codex")
    legacyDefaults.set(300.0, forKey: "refreshInterval")
    legacyDefaults.set("should-not-copy", forKey: "com.example.notOurs")
    let savedLegacyName = Prefs.legacyDomainNameForTesting
    Prefs.legacyDomainNameForTesting = legacyProbe
    Prefs.setShowInDropdown(.claude, false) // a pre-existing value must win
    Prefs.migrateLegacyDomainIfNeeded()
    precondition(!Prefs.showInDropdown(.codex), "owned keys must come across")
    precondition(Prefs.refreshInterval() == 300, "the refresh interval must come across")
    precondition(Prefs.defaults.object(forKey: "com.example.notOurs") == nil,
                 "only keys this app owns may be copied")
    precondition(!Prefs.showInDropdown(.claude), "an existing value must not be overwritten")
    // Idempotent: a later change must survive a second call.
    Prefs.setShowInDropdown(.codex, true)
    Prefs.migrateLegacyDomainIfNeeded()
    precondition(Prefs.showInDropdown(.codex), "migration must run once, not every launch")
    Prefs.legacyDomainNameForTesting = savedLegacyName
    legacyDefaults.removePersistentDomain(forName: legacyProbe)
    testDefaults.removePersistentDomain(forName: selfTestSuite)

    // Migration from the old per-provider title.<id> booleans. Someone who
    // hid Codex from the bar must stay hidden across the upgrade.
    testDefaults.removePersistentDomain(forName: selfTestSuite)
    Prefs.defaults.set(false, forKey: "title.codex")
    Prefs.defaults.set(true, forKey: "title.claude")
    Prefs.migrateTitleMetricsIfNeeded()
    precondition(!Prefs.showMetricInTitle(codexWeeklyMetric))
    precondition(Prefs.showMetricInTitle(claudeSessionMetric))
    precondition(Prefs.showMetricInTitle(TitleMetric.metric(id: "claude.weekly")!))
    // Antigravity had no legacy flag, so migration must leave it off.
    precondition(!Prefs.showMetricInTitle(geminiWeekly),
                 "migration must not switch on a provider that had no legacy flag")
    // Idempotent: a second run must not undo a later manual change.
    Prefs.setShowMetricInTitle(geminiWeekly, true)
    Prefs.migrateTitleMetricsIfNeeded()
    precondition(Prefs.showMetricInTitle(geminiWeekly), "migration must run once, not every launch")
    // A fresh install has no legacy keys and must land on the defaults.
    testDefaults.removePersistentDomain(forName: selfTestSuite)
    Prefs.migrateTitleMetricsIfNeeded()
    for metric in TitleMetric.all {
        precondition(Prefs.showMetricInTitle(metric) == metric.defaultOn)
    }
    testDefaults.removePersistentDomain(forName: selfTestSuite)

    // H2: the four Dropdown x Menu-bar visibility combinations for a
    // title-capable provider (.claude) — must poll whenever EITHER is on,
    // and rebuildMenu must still hide it from the dropdown when only the
    // title is on. Plus a non-title-capable provider, where title state
    // must never matter at all.
    func setClaudeTitle(_ on: Bool) {
        for metric in TitleMetric.all where metric.provider == .claude {
            Prefs.setShowMetricInTitle(metric, on)
        }
    }
    Prefs.setShowInDropdown(.claude, true); setClaudeTitle(true)
    precondition(Providers.shouldPoll(id: .claude))
    Prefs.setShowInDropdown(.claude, true); setClaudeTitle(false)
    precondition(Providers.shouldPoll(id: .claude))
    Prefs.setShowInDropdown(.claude, false); setClaudeTitle(true)
    precondition(Providers.shouldPoll(id: .claude), "menu-bar-title-only visibility must still be polled")
    precondition(!UsageMenuBar.shouldShowInDropdown(Card(provider: "Claude", rows: [])),
                 "title-only visibility must still be hidden from the dropdown")
    // A SINGLE ticked metric is enough to keep the provider polled — otherwise
    // its headline would freeze on stale numbers with no staleness marker.
    Prefs.setShowInDropdown(.claude, false); setClaudeTitle(false)
    precondition(!Providers.shouldPoll(id: .claude), "both hidden must not be polled")
    Prefs.setShowMetricInTitle(claudeSessionMetric, true)
    precondition(Providers.shouldPoll(id: .claude), "one ticked metric must be enough to poll")
    setClaudeTitle(false)

    Prefs.setShowInDropdown(.openrouter, false)
    precondition(!Providers.shouldPoll(id: .openrouter),
                 "a provider owning no title metric is polled on its dropdown flag alone")
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
        // isolated — a real OPENROUTER_API_KEY in the runner's environment
        // made "None present -> nil" false and crashed the run (SIGTRAP).
        // Save and clear it up front, restore in the same defer that already
        // restores legacyPath, so this block can never observe (or clobber)
        // the user's real environment.
        let savedOpenRouterEnv = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
        unsetenv("OPENROUTER_API_KEY")
        defer {
            if let savedOpenRouterEnv { setenv("OPENROUTER_API_KEY", savedOpenRouterEnv, 1) } else { unsetenv("OPENROUTER_API_KEY") }
            Config.legacyPath = savedLegacyPath
            try? FileManager.default.removeItem(at: tempDir)
        }

        // None present -> nil.
        precondition(Config.load(store: fakeStore).openRouterKey == nil)

        // Legacy JSON alone (tier 3). The now-unsupported "xai_key" is left
        // in the fixture on purpose: a config.json written by an older build
        // must still yield its OpenRouter key, not trip over the stale field.
        let legacyJSON = #"{"openrouter_key": "legacy-or", "xai_key": "legacy-xai"}"#
        try? legacyJSON.write(to: tempConfigPath, atomically: true, encoding: .utf8)
        precondition(Config.load(store: fakeStore).openRouterKey == "legacy-or")

        // Keychain beats legacy JSON (tier 2 over tier 3).
        try? fakeStore.set(KeyAccount.openRouter, value: "keychain-or")
        precondition(Config.load(store: fakeStore).openRouterKey == "keychain-or")

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
        let clean = LegacyImport.run(legacyOpenRouterKey: "or-1", store: store)
        precondition(clean.importedCount == 1 && clean.errors.isEmpty)
        precondition(store.get(KeyAccount.openRouter) == "or-1")

        // Already-present Keychain values are left untouched, not re-imported.
        let noop = LegacyImport.run(legacyOpenRouterKey: "or-2", store: store)
        precondition(noop.importedCount == 0 && noop.errors.isEmpty)
        precondition(store.get(KeyAccount.openRouter) == "or-1", "an existing Keychain value must win, never be overwritten by import")

        let failingStore = FailingKeyStore()
        let failed = LegacyImport.run(legacyOpenRouterKey: "or-3", store: failingStore)
        precondition(failed.importedCount == 0, "a store failure must not be counted as a successful import")
        precondition(failed.errors.count == 1, "the key failure must be reported, not swallowed")
        precondition(failed.errors.contains { $0.contains("OpenRouter") })
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
        precondition(selfTestAccount != KeyAccount.openRouter)

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

    // Every provider that can appear in the title must have a mark that
    // actually rasterizes. A missing or malformed SVG degrades to a text
    // fallback in renderTitle(), which is easy to miss by eye and impossible
    // to miss here. The antigravity mark is machine-traced from a favicon
    // (tools/trace_antigravity_logo.py), so "does the emitted path render at
    // all" is a real question, not a formality.
    // Derived from the registry rather than hardcoded, so adding a provider
    // to TitleMetric.all without shipping its mark fails here.
    for provider in ProviderID.allCases where provider.ownsTitleMetrics {
        let resource = "\(provider.rawValue)-template"
        let logo = UsageMenuBar.logoImage(resource: resource)
        precondition(logo != nil, "\(resource) is missing from the app bundle")
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
        } == true, "\(resource) rasterized to nothing")
    }

    // runSelfTests() is nonisolated but only ever called from the main
    // thread (see the MainActor.assumeIsolated entry point below); the
    // Settings checks touch AppKit views, so they need that stated.
    MainActor.assumeIsolated { SettingsWindowController.runSelfTests() }
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
    testBlockedAccounts()

    print("Self-tests passed")
}

if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
    exit(0)
}

if CommandLine.arguments.contains("--once") {
    // --once reads the same prefs the app does, so it needs the same
    // migration or it reports a factory-fresh config after the rename.
    Prefs.migrateLegacyDomainIfNeeded()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        // --once ignores visibility on purpose (Providers.all's doc
        // comment): headless output is a diagnostic, not a display, so it
        // always reports every provider regardless of what's hidden from
        // the live dropdown/title.
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

        // The menu bar title is the app's most important surface and was the
        // one thing this diagnostic could not show, which made "the item is
        // blank/missing" impossible to debug without a screen.
        let entries = UsageMenuBar.visibleTitleEntries()
        print("Title")
        print("  metrics ticked: \(entries.count) of \(TitleMetric.all.count)")
        for (metric, value) in entries {
            print("    \(metric.id) = \(value?.text ?? "no value yet")")
        }
        let rendered = UsageMenuBar.headlineText(entries)
        print("  renders as: \"\(rendered)\" (\(rendered.count) chars)")

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

if CommandLine.arguments.contains("--status-check") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let controller = UsageMenuBar()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        // Let AppKit finish placing the item before interrogating it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print(controller.statusReport())
            exit(0)
        }
        app.run()
    }
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
