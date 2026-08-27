import AppKit

/// Programmatic AppKit settings window — no SwiftUI, no xib, matching the
/// rest of the app. One shared instance so re-opening "Settings…" focuses
/// the existing window instead of stacking duplicates on top of it.
@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var intervalPopup: NSPopUpButton?
    private var intervalChoices: [(title: String, seconds: TimeInterval)] = []

    /// Unbounded on purpose: the user opened this window to manage keys, so a
    /// Keychain prompt is expected here and waiting for it is correct. Only
    /// the background poll needs the bounded store.
    private let keyStore: KeyStore = KeychainStore()
    private var openRouterRow: APIKeyRow!
    private var migrationBanner: NSStackView?
    private var justImportedCount: Int?
    private var importError: String?

    private override init() { super.init() }

    /// The app runs with activationPolicy .accessory (no Dock icon), so
    /// without an explicit activate the window opens behind whatever app
    /// currently has focus — makeKeyAndOrderFront alone isn't enough.
    func show() {
        if window == nil { window = makeWindow() }
        // L10: "Imported N keys" is a one-time notice about the Import click
        // that just happened — without this it survived close/reopen and
        // read as permanently true on every future visit to Settings.
        justImportedCount = nil
        // Not app-launch: refreshed here, every time the window opens, so
        // there is no surprise Keychain read/write at login via the
        // LaunchAgent, and the env-var/migration state (which can change
        // between opens) is never stale.
        refreshAPIKeysUI()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "AI Usage Settings"
        win.isReleasedWhenClosed = false // shared instance: hide, don't destroy
        win.contentView = buildContent()
        win.center()
        return win
    }

    private func buildContent() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 20
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(providersSection())
        root.addArrangedSubview(menuBarSection())
        root.addArrangedSubview(refreshSection())
        root.addArrangedSubview(apiKeysSection())
        root.addArrangedSubview(sessionsSection())

        // Plain container, not a scroll view: the window is fixed-size and
        // the content is short enough to fit. A later phase adding sections
        // at the seam above may need to revisit that.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: Providers section

    private func providersSection() -> NSView {
        let header = NSTextField(labelWithString: "Providers")
        header.font = .boldSystemFont(ofSize: 13)

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 14

        let columnTitles = ["", "Dropdown"]
        let headerRow = columnTitles.map { title -> NSView in
            let field = NSTextField(labelWithString: title)
            field.font = .systemFont(ofSize: 11, weight: .semibold)
            field.textColor = .secondaryLabelColor
            return field
        }
        grid.addRow(with: headerRow)

        for id in ProviderID.allCases {
            let nameField = NSTextField(labelWithString: id.displayName)

            let dropdownCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(dropdownToggled(_:)))
            dropdownCheck.state = Prefs.showInDropdown(id) ? .on : .off
            dropdownCheck.identifier = NSUserInterfaceItemIdentifier(id.rawValue)

            // What appears in the menu bar is chosen per number, not per
            // provider, in its own section below — Antigravity contributes
            // four unrelated numbers and one checkbox cannot speak for them.
            grid.addRow(with: [nameField, dropdownCheck])
        }

        let stack = NSStackView(views: [header, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    @objc private func dropdownToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = ProviderID(rawValue: raw) else { return }
        Prefs.setShowInDropdown(id, sender.state == .on)
    }

    @objc private func metricToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let metric = TitleMetric.metric(id: raw) else { return }
        Prefs.setShowMetricInTitle(metric, sender.state == .on)
    }

    // MARK: Refresh interval section

    // MARK: Menu bar section

    /// One checkbox per title number rather than per provider.
    ///
    /// Antigravity contributes four numbers across two unrelated quota groups
    /// (Gemini, and Claude/GPT) and no single one of them is a fair headline
    /// for the others, so the choice belongs to the user. Claude and Codex
    /// get the same treatment for consistency — and because someone who only
    /// cares about their weekly window can now say so.
    private func menuBarSection() -> NSView {
        let header = NSTextField(labelWithString: "Menu bar")
        header.font = .boldSystemFont(ofSize: 13)

        let caption = NSTextField(labelWithString:
            "Antigravity's numbers come from the agy CLI and are only live while it runs.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        for metric in TitleMetric.all {
            let check = NSButton(
                checkboxWithTitle: "\(metric.provider.displayName) · \(metric.label)",
                target: self, action: #selector(metricToggled(_:)))
            check.state = Prefs.showMetricInTitle(metric) ? .on : .off
            check.identifier = NSUserInterfaceItemIdentifier(metric.id)
            stack.addArrangedSubview(check)
        }
        stack.addArrangedSubview(caption)
        return stack
    }

    private func refreshSection() -> NSView {
        let header = NSTextField(labelWithString: "Refresh")
        header.font = .boldSystemFont(ofSize: 13)

        intervalChoices = [
            (title: "1 minute", seconds: 60),
            (title: "2 minutes", seconds: 120),
            (title: "5 minutes", seconds: 300),
            (title: "10 minutes", seconds: 600),
            (title: "15 minutes", seconds: 900),
        ]

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for choice in intervalChoices { popup.addItem(withTitle: choice.title) }
        popup.target = self
        popup.action = #selector(intervalChanged(_:))
        selectClosestInterval(in: popup, to: Prefs.refreshInterval())
        intervalPopup = popup

        let rowLabel = NSTextField(labelWithString: "Refresh every")
        let row = NSStackView(views: [rowLabel, popup])
        row.orientation = .horizontal
        row.spacing = 8

        let caption = NSTextField(
            wrappingLabelWithString: "while a session is active. With nothing running it eases to "
                + "10 min, then hourly once the numbers stop moving — the Claude usage API "
                + "rate-limits aggressively. Minimum 1 min."
        )
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = 320

        let stack = NSStackView(views: [header, row, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func selectClosestInterval(in popup: NSPopUpButton, to seconds: TimeInterval) {
        guard !intervalChoices.isEmpty else { return }
        let index = intervalChoices.indices.min {
            abs(intervalChoices[$0].seconds - seconds) < abs(intervalChoices[$1].seconds - seconds)
        }
        popup.selectItem(at: index ?? 0)
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard intervalChoices.indices.contains(index) else { return }
        Prefs.setRefreshInterval(intervalChoices[index].seconds)
    }

    // MARK: API Keys section

    private func apiKeysSection() -> NSView {
        let header = NSTextField(labelWithString: "API Keys")
        header.font = .boldSystemFont(ofSize: 13)

        openRouterRow = APIKeyRow(
            providerLabel: "OpenRouter",
            account: KeyAccount.openRouter,
            envVarName: "OPENROUTER_API_KEY",
            keyStore: keyStore,
            legacyValue: { Config.legacyOpenRouterKey() },
            validate: { key in
                let json = try await Net.getJSON(URL(string: "https://openrouter.ai/api/v1/credits")!, bearer: key)
                return OpenRouterProvider.creditsMessage(from: json)
            }
        )
        openRouterRow.onSaved = { [weak self] in self?.keyRowSaved() }

        let banner = NSStackView()
        banner.orientation = .vertical
        banner.alignment = .leading
        banner.spacing = 4
        migrationBanner = banner

        let stack = NSStackView(views: [header, openRouterRow.rowView(), banner])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    /// Re-derives every piece of API-key UI state that can change without an
    /// app restart: whether an env var now overrides a field, whether a
    /// Keychain item exists, and whether the legacy-JSON migration banner
    /// should show. Called on every window open, never at app launch.
    private func refreshAPIKeysUI() {
        openRouterRow.refresh()
        refreshMigrationBanner()
    }

    /// A Save (or Import) changes exactly the state refreshMigrationBanner
    /// depends on (a Keychain item appearing or disappearing), so the row's
    /// onSaved routes here rather than re-deriving the banner
    /// independently.
    private func keyRowSaved() {
        justImportedCount = nil
        importError = nil
        refreshMigrationBanner()
    }

    private func refreshMigrationBanner() {
        guard let banner = migrationBanner else { return }
        for view in banner.arrangedSubviews {
            banner.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // L9: a failed import (e.g. a Keychain write error) is shown
        // explicitly rather than silently looking identical to "0 keys to
        // import".
        if let importError {
            let notice = NSTextField(wrappingLabelWithString: "Import failed — \(importError)")
            notice.font = .systemFont(ofSize: 11)
            notice.textColor = .systemRed
            notice.preferredMaxLayoutWidth = 380
            banner.addArrangedSubview(notice)
            return
        }

        if let count = justImportedCount, count > 0 {
            let notice = NSTextField(wrappingLabelWithString:
                "Imported \(count) key\(count == 1 ? "" : "s") from config.json — "
                + "you can now delete ~/.config/claude-usage/config.json")
            notice.font = .systemFont(ofSize: 11)
            notice.textColor = .secondaryLabelColor
            notice.preferredMaxLayoutWidth = 380
            banner.addArrangedSubview(notice)
            return
        }

        // Import is offered only where the legacy file holds a key AND the
        // Keychain item is absent. Both present (and differing) means the
        // Keychain already won that key — no banner. Neither present (the
        // common case: no legacy file on this machine at all) means nothing
        // to offer, and that must render as no banner, not an error.
        guard Config.legacyOpenRouterKey() != nil, keyStore.get(KeyAccount.openRouter) == nil else { return }

        let label = NSTextField(wrappingLabelWithString:
            "Found 1 key in ~/.config/claude-usage/config.json")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 380

        let button = NSButton(title: "Import from config.json", target: self, action: #selector(importLegacyKeys))

        banner.addArrangedSubview(label)
        banner.addArrangedSubview(button)
    }

    @objc private func importLegacyKeys() {
        // Import = SecItemAdd (via KeyStore.set), file left untouched. Only
        // where the Keychain item is still absent — if it appeared between
        // refreshAPIKeysUI() and this click, Keychain already wins and we
        // must not clobber a value the user may have just typed and saved.
        let result = LegacyImport.run(legacyOpenRouterKey: Config.legacyOpenRouterKey(), store: keyStore)
        justImportedCount = result.importedCount
        importError = result.errors.isEmpty ? nil : result.errors.joined(separator: "; ")
        openRouterRow.refresh()
        refreshMigrationBanner()
    }

    // MARK: Sessions section (Feature C, Phase 4c)
    //
    // Both row styles are real, independently-maintained renderers now:
    // Compact through the existing addRow/attributedTitle path, Detailed
    // through the custom NSMenuItem.view in Sources/SessionRowView.swift.
    // The stored default is Detailed (Prefs.swift), so an install that
    // never opens Settings gets the rich rows out of the box; switching
    // either way here takes effect on the next menu rebuild — no restart.

    private func sessionsSection() -> NSView {
        let header = NSTextField(labelWithString: "Sessions")
        header.font = .boldSystemFont(ofSize: 13)

        let showCheck = NSButton(checkboxWithTitle: "Show sessions", target: self, action: #selector(showSessionsToggled(_:)))
        showCheck.state = Prefs.showSessions() ? .on : .off

        let styleLabel = NSTextField(labelWithString: "Row style")
        let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        stylePopup.addItem(withTitle: "Compact")
        stylePopup.addItem(withTitle: "Detailed")
        stylePopup.target = self
        stylePopup.action = #selector(sessionRowStyleChanged(_:))
        stylePopup.selectItem(at: Prefs.sessionRowStyle() == .detailed ? 1 : 0)

        let styleRow = NSStackView(views: [styleLabel, stylePopup])
        styleRow.orientation = .horizontal
        styleRow.spacing = 8

        let caption = NSTextField(wrappingLabelWithString:
            "Compact is one line per session; Detailed is a richer two-line row you can click to expand " +
            "for cwd and compaction detail.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = 320

        let stack = NSStackView(views: [header, showCheck, styleRow, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    @objc private func showSessionsToggled(_ sender: NSButton) {
        Prefs.setShowSessions(sender.state == .on)
    }

    @objc private func sessionRowStyleChanged(_ sender: NSPopUpButton) {
        let style: SessionRowStyle = sender.indexOfSelectedItem == 1 ? .detailed : .compact
        Prefs.setSessionRowStyle(style)
    }
}

// MARK: - APIKeyRow

/// One key's live row: a secure field, Test/Save buttons, and a status line
/// — plus the logic behind them. One instance per key, so it stays generic
/// even though OpenRouter is currently the only one; SettingsWindowController
/// builds it once and calls refresh() every time the window opens, since the
/// env-var override and Keychain/legacy state can all change between opens
/// without an app restart.
@MainActor
private final class APIKeyRow: NSObject, NSTextFieldDelegate {
    let providerLabel: String
    let account: String
    let envVarName: String
    let keyStore: KeyStore
    let legacyValue: () -> String?
    let validate: (String) async throws -> String

    /// Fired after a successful Save (store or delete) so the section can
    /// re-derive banner/other-row state that depends on this row's key.
    var onSaved: (() -> Void)?

    let field = NSSecureTextField()
    let testButton = NSButton(title: "Test", target: nil, action: nil)
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")

    init(
        providerLabel: String, account: String, envVarName: String, keyStore: KeyStore,
        legacyValue: @escaping () -> String?, validate: @escaping (String) async throws -> String
    ) {
        self.providerLabel = providerLabel
        self.account = account
        self.envVarName = envVarName
        self.keyStore = keyStore
        self.legacyValue = legacyValue
        self.validate = validate
        super.init()
        field.delegate = self
        testButton.target = self
        testButton.action = #selector(testTapped)
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        // Disabled until the field is actually edited — Save applying to an
        // untouched, empty field (every field starts empty; secrets are
        // never re-displayed) would otherwise silently delete an existing
        // key the moment someone opens settings and mis-clicks.
        saveButton.isEnabled = false
    }

    func rowView() -> NSView {
        let nameLabel = NSTextField(labelWithString: providerLabel)
        nameLabel.alignment = .right
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true

        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let controlsRow = NSStackView(views: [nameLabel, field, testButton, saveButton])
        controlsRow.orientation = .horizontal
        controlsRow.spacing = 8

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let column = NSStackView(views: [controlsRow, statusLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }

    /// Re-derives everything about this row that can change without an app
    /// restart: an env var appearing/disappearing, or the Keychain item
    /// this row controls changing (Save, delete, or an Import elsewhere in
    /// the window).
    func refresh() {
        // L16: a typed-but-unsaved secret must not survive close/reopen —
        // the window is a shared instance that's never released
        // (isReleasedWhenClosed = false), so without this the field kept
        // whatever text was last typed, saved or not. Cleared unconditionally
        // here, not just in the env-overridden branch below.
        field.stringValue = ""

        let envValue = ProcessInfo.processInfo.environment[envVarName]
        let hasKeychainValue = keyStore.get(account) != nil

        let envOverridden = envValue != nil
        field.isEnabled = !envOverridden
        testButton.isEnabled = !envOverridden
        // Never re-armed here: only an actual edit (controlTextDidChange)
        // should make Save clickable again — see the "empty field on open"
        // note in init().
        saveButton.isEnabled = false

        if envOverridden {
            field.placeholderString = "(set by environment variable)"
            statusLabel.stringValue = "\(envVarName) overrides this — see README"
        } else if hasKeychainValue {
            field.placeholderString = "•••••••• (saved)"
            statusLabel.stringValue = "Keychain: key stored"
        } else if BlockedAccounts.shared.contains(account) {
            // There *is* an item, it just cannot be read without an approval
            // dialog nobody answered — almost always one written by a build
            // from before this app used security. Saying "no key set" here
            // would be a lie the user could not act on; saving repairs it.
            field.placeholderString = ""
            statusLabel.stringValue = "stored key unreadable — paste it again and Save to repair"
        } else if legacyValue() != nil {
            field.placeholderString = "•••••••• (from config.json)"
            statusLabel.stringValue = "using legacy config.json — import below to move it to the Keychain"
        } else {
            field.placeholderString = ""
            statusLabel.stringValue = "no key set"
        }
        statusLabel.textColor = .secondaryLabelColor
    }

    func controlTextDidChange(_ obj: Notification) {
        saveButton.isEnabled = field.isEnabled
    }

    /// Validates the field's CURRENT TEXT, not the stored key — independent
    /// of the poll loop (its own URLSession call), so users can test before
    /// saving and a Test never shares state with a refresh in flight.
    @objc private func testTapped() {
        // Same normalisation Save applies, so "Test" can never pass on a
        // string that Save would then store differently (or vice versa).
        let value = APIKeySave.normalize(field.stringValue)
        guard !value.isEmpty else {
            statusLabel.stringValue = "enter a key to test"
            statusLabel.textColor = .secondaryLabelColor
            return
        }
        statusLabel.stringValue = "testing…"
        statusLabel.textColor = .secondaryLabelColor
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let message = try await self.validate(value)
                self.statusLabel.stringValue = "✓ \(message)"
                self.statusLabel.textColor = .systemGreen
            } catch {
                self.statusLabel.stringValue = "✗ \(error.localizedDescription)"
                self.statusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func saveTapped() {
        let value = APIKeySave.normalize(field.stringValue)
        do {
            try APIKeySave.apply(value, account: account, store: keyStore)
            statusLabel.stringValue = value.isEmpty ? "removed from Keychain" : "saved to Keychain"
            statusLabel.textColor = .secondaryLabelColor
            saveButton.isEnabled = false
            onSaved?()
        } catch {
            statusLabel.stringValue = "✗ \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }
}
