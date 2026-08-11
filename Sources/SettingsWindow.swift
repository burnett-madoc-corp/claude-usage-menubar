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

    private override init() { super.init() }

    /// The app runs with activationPolicy .accessory (no Dock icon), so
    /// without an explicit activate the window opens behind whatever app
    /// currently has focus — makeKeyAndOrderFront alone isn't enough.
    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
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
        root.addArrangedSubview(refreshSection())

        // --- Extension seam --------------------------------------------
        // A later phase adds an "API Keys" section (Feature B) and a
        // "Sessions" section (Feature C) here — each is one more
        // root.addArrangedSubview(_:) call with its own private builder
        // method below, following the same section shape as the two
        // above. Nothing above this comment should need to change.
        // -----------------------------------------------------------------

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let scroll = container // plain container; window is fixed-size, no scrolling needed yet
        scroll.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: scroll.topAnchor),
            root.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            root.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: scroll.bottomAnchor),
        ])
        return scroll
    }

    // MARK: Providers section

    private func providersSection() -> NSView {
        let header = NSTextField(labelWithString: "Providers")
        header.font = .boldSystemFont(ofSize: 13)

        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 14

        let columnTitles = ["", "Dropdown", "Menu bar"]
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

            if id.supportsTitle {
                let titleCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(titleToggled(_:)))
                titleCheck.state = Prefs.showInTitle(id) ? .on : .off
                titleCheck.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
                grid.addRow(with: [nameField, dropdownCheck, titleCheck])
            } else {
                // Absent, not disabled: this provider has no headline value
                // to put in the title, so there is nothing for the checkbox
                // to control. NSGridCell.emptyContentView marks the cell as
                // deliberately empty rather than leaving a hole.
                grid.addRow(with: [nameField, dropdownCheck, NSGridCell.emptyContentView])
            }
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

    @objc private func titleToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = ProviderID(rawValue: raw) else { return }
        Prefs.setShowInTitle(id, sender.state == .on)
    }

    // MARK: Refresh interval section

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
            wrappingLabelWithString: "minimum 1 min — the Claude usage API rate-limits aggressively"
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
}
