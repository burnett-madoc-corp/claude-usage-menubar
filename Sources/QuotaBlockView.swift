import AppKit

// MARK: - Quota block: pure composition helpers
//
// Same split as DetailedSessionRow: everything that turns a `Card` into
// strings and column geometry lives here as pure, fixture-tested functions,
// and the view below is a thin draw-time layer over them.
enum QuotaBlock {
    static let headerHeight: CGFloat = 22
    static let rowHeight: CGFloat = 18
    static let noteHeight: CGFloat = 15
    static let topPadding: CGFloat = 6
    static let bottomPadding: CGFloat = 7

    /// The label column is 56pt for the windows named "5-hour" and "Weekly",
    /// but Claude's `weekly_scoped` rows are labelled with whatever
    /// `scope.model.display_name` the API returns, and those are neither
    /// short nor fixed. At a fixed 56pt, siblings sharing a long prefix all
    /// truncate to the same string — rows that no longer say which model they
    /// are. So the column grows to the widest label in *its own* block,
    /// capped so the bar keeps a usable minimum width.
    static let minLabelWidth: CGFloat = 56
    static let maxLabelWidth: CGFloat = 132
    static let percentWidth: CGFloat = 40
    static let resetWidth: CGFloat = 104
    static let barHeight: CGFloat = 5
    static let dotDiameter: CGFloat = 8

    /// Codex quota is read out of the rollout log of the last turn you took,
    /// so it is a snapshot, not a live reading. The bars are drawn at reduced
    /// opacity to say that continuously, rather than only in the badge.
    static let staleBarOpacity: CGFloat = 0.75

    /// "resets in 4h 53m", or a bare "—" when there is no reset time at all.
    /// Providers compose the detail as "resets in \(countdown)" and
    /// `Format.countdown` already yields "—" for a nil date, so the combined
    /// "resets in —" is the one form that must collapse.
    nonisolated static func resetText(_ detail: String) -> String {
        detail == "resets in —" ? "—" : detail
    }

    /// Keyless providers collapse to a single line: there is no quota to show
    /// and the error is not a failure so much as a setup step.
    nonisolated static func isMissingKey(_ card: Card) -> Bool { card.missingKey }

    nonisolated static let missingKeyText = "no API key"
    nonisolated static let missingKeyHint = "add in Settings →"

    static let labelFont = PanelFont.text(11)

    static func labelWidth(for card: Card) -> CGFloat {
        let widest = card.rows
            .map { ($0.label as NSString).size(withAttributes: [.font: labelFont]).width }
            .max() ?? 0
        return min(maxLabelWidth, max(minLabelWidth, ceil(widest) + 4))
    }

    nonisolated static func height(for card: Card) -> CGFloat {
        var height = topPadding + headerHeight + bottomPadding
        if isMissingKey(card) { return height }
        if card.error != nil { height += noteHeight }
        height += CGFloat(card.rows.count) * rowHeight
        if card.note != nil { height += noteHeight }
        return height
    }

    /// Full-content accessibility text for the block, mirroring what the
    /// Detailed session rows already provide — the drawn panel is otherwise
    /// opaque to VoiceOver, since none of it is a real text control.
    nonisolated static func accessibilityLabel(for card: Card) -> String {
        var parts: [String] = [card.provider]
        if isMissingKey(card) {
            parts.append(missingKeyText)
            return parts.joined(separator: ", ")
        }
        if let badge = card.badge { parts.append(badge.text) }
        if let error = card.error { parts.append(error) }
        for row in card.rows {
            if let percent = row.percent {
                parts.append("\(row.label) \(percent) percent, \(resetText(row.detail))")
            } else {
                parts.append("\(row.label) \(row.detail)")
            }
        }
        if let note = card.note { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Quota block view
//
// One custom view per provider, rather than one per window row: the four
// columns only line up if a single drawing pass owns the whole block, and the
// block has no per-row interaction to preserve. Like SessionRowView, this
// hand-rolls what attributedTitle rows used to get free — sizing, dark mode,
// accessibility — because a custom view inherits none of it.
@MainActor
final class QuotaBlockView: NSView {
    private let card: Card
    private let accent: ProviderAccent
    private let labelWidth: CGFloat

    /// Only ever set for a keyless provider, whose whole block is the
    /// affordance for the "add in Settings →" hint it draws.
    var onOpenSettings: (() -> Void)?

    init(card: Card, width: CGFloat) {
        self.card = card
        self.accent = ProviderAccent.forProvider(card.provider)
        self.labelWidth = QuotaBlock.labelWidth(for: card)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: QuotaBlock.height(for: card)))
        setAccessibilityElement(true)
        setAccessibilityLabel(QuotaBlock.accessibilityLabel(for: card))
    }

    required init?(coder: NSCoder) {
        fatalError("QuotaBlockView does not support NSCoding")
    }

    override var isFlipped: Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard QuotaBlock.isMissingKey(card), let onOpenSettings else { return }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onOpenSettings()
    }

    // Every colour is resolved here, at draw time, from the dynamic system
    // colours and the dynamic accents in Theme.swift — never cached — so a
    // live light/dark or contrast switch needs nothing but a redraw.
    override func draw(_ dirtyRect: NSRect) {
        var y = QuotaBlock.topPadding
        drawHeader(y: y)
        y += QuotaBlock.headerHeight

        if QuotaBlock.isMissingKey(card) { return }

        if let error = card.error {
            Draw.text(error, font: PanelFont.text(11), color: .systemRed,
                      in: NSRect(x: Panel.inset, y: y, width: bounds.width - Panel.inset * 2,
                                 height: QuotaBlock.noteHeight))
            y += QuotaBlock.noteHeight
        }

        for row in card.rows {
            drawRow(row, y: y)
            y += QuotaBlock.rowHeight
        }

        if let note = card.note {
            Draw.text(note, font: PanelFont.text(10), color: .tertiaryLabelColor,
                      in: NSRect(x: Panel.inset, y: y, width: bounds.width - Panel.inset * 2,
                                 height: QuotaBlock.noteHeight))
        }
    }

    private func drawHeader(y: CGFloat) {
        let row = NSRect(x: Panel.inset, y: y, width: bounds.width - Panel.inset * 2,
                         height: QuotaBlock.headerHeight)
        Draw.dot(centeredIn: NSRect(x: row.minX, y: row.minY, width: QuotaBlock.dotDiameter, height: row.height),
                 diameter: QuotaBlock.dotDiameter, color: accent.color, filled: true)

        let nameFont = PanelFont.text(13, .semibold)
        let nameX = row.minX + QuotaBlock.dotDiameter + 7
        let nameWidth = (card.provider as NSString).size(withAttributes: [.font: nameFont]).width
        Draw.text(card.provider, font: nameFont, color: accent.color,
                  in: NSRect(x: nameX, y: row.minY, width: nameWidth, height: row.height))

        var trailingX = nameX + nameWidth + 8
        if let badge = card.badge {
            let drawn = Draw.badge(badge, at: NSPoint(x: trailingX, y: row.minY + (row.height - 15) / 2),
                                   font: PanelFont.text(10))
            trailingX = drawn.maxX + 8
        }

        guard QuotaBlock.isMissingKey(card) else { return }
        let missingFont = PanelFont.text(11)
        let missingWidth = (QuotaBlock.missingKeyText as NSString)
            .size(withAttributes: [.font: missingFont]).width
        Draw.text(QuotaBlock.missingKeyText, font: missingFont, color: .systemRed,
                  in: NSRect(x: trailingX, y: row.minY, width: missingWidth, height: row.height))
        let hintX = trailingX + missingWidth + 8
        Draw.text(QuotaBlock.missingKeyHint, font: missingFont, color: .linkColor,
                  in: NSRect(x: hintX, y: row.minY, width: max(0, row.maxX - hintX), height: row.height))
    }

    private func drawRow(_ row: Row, y: CGFloat) {
        let left = Panel.inset
        let right = bounds.width - Panel.inset
        let box = NSRect(x: left, y: y, width: right - left, height: QuotaBlock.rowHeight)

        Draw.text(row.label, font: QuotaBlock.labelFont, color: .secondaryLabelColor,
                  in: NSRect(x: left, y: y, width: labelWidth, height: box.height))

        let barX = left + labelWidth + Panel.columnGap
        guard let percent = row.percent else {
            // Balances, plan names and key health: no window, so no bar — the
            // detail takes the whole remaining width rather than a 0% bar
            // standing in for something that was never a percentage.
            Draw.text(row.detail, font: PanelFont.number(11), color: .secondaryLabelColor,
                      in: NSRect(x: barX, y: y, width: max(0, right - barX), height: box.height))
            return
        }

        let resetX = right - QuotaBlock.resetWidth
        let percentX = resetX - Panel.columnGap - QuotaBlock.percentWidth
        let barWidth = max(0, percentX - Panel.columnGap - barX)
        let severity = Format.color(for: row.severity, percent: percent)
        let opacity: CGFloat = accent == .codex ? QuotaBlock.staleBarOpacity : 1

        Draw.track(in: NSRect(x: barX, y: y + (box.height - QuotaBlock.barHeight) / 2,
                              width: barWidth, height: QuotaBlock.barHeight),
                   fraction: Double(percent) / 100, fill: severity, opacity: opacity)

        Draw.text("\(percent)%", font: PanelFont.number(11, .semibold), color: severity,
                  in: NSRect(x: percentX, y: y, width: QuotaBlock.percentWidth, height: box.height),
                  alignment: .right)

        Draw.text(QuotaBlock.resetText(row.detail), font: PanelFont.number(10), color: .tertiaryLabelColor,
                  in: NSRect(x: resetX, y: y, width: QuotaBlock.resetWidth, height: box.height),
                  alignment: .right)
    }
}

// MARK: - Inset hairline between quota blocks

@MainActor
final class InsetDividerView: NSView {
    static let height: CGFloat = 9

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("InsetDividerView does not support NSCoding")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Draw.divider(in: bounds, inset: Panel.inset)
    }
}

// MARK: - Self-tests

enum QuotaBlockSelfTests {
    static func run() {
        testResetText()
        testHeight()
        testLabelWidth()
        testAccessibilityLabel()
    }

    private static func makeCard(
        provider: String = "Claude",
        rows: [Row] = [Row(label: "5-hour", percent: 42, detail: "resets in 4h 53m")],
        note: String? = nil,
        error: String? = nil,
        badge: Badge? = nil,
        missingKey: Bool = false
    ) -> Card {
        Card(provider: provider, rows: rows, note: note, error: error,
             badge: badge, missingKey: missingKey)
    }

    private static func testResetText() {
        precondition(QuotaBlock.resetText("resets in 4h 53m") == "resets in 4h 53m")
        precondition(QuotaBlock.resetText("resets in —") == "—",
                     "a missing reset time must read as a bare —, never 'resets in —'")
        precondition(QuotaBlock.resetText("unlimited") == "unlimited")
    }

    private static func testHeight() {
        let base = QuotaBlock.height(for: makeCard())
        let twoRows = QuotaBlock.height(for: makeCard(rows: [
            Row(label: "5-hour", percent: 42, detail: "resets in 4h 53m"),
            Row(label: "Weekly", percent: 71, detail: "resets in 3d 4h"),
        ]))
        precondition(twoRows == base + QuotaBlock.rowHeight)

        let noted = QuotaBlock.height(for: makeCard(note: "plan: max"))
        precondition(noted == base + QuotaBlock.noteHeight)

        // A keyless provider is exactly one line — its rows and note, if any
        // ever arrived, must not add height to a block that draws neither.
        let keyless = makeCard(provider: "OpenRouter", rows: [], error: "no API key", missingKey: true)
        precondition(QuotaBlock.isMissingKey(keyless))
        precondition(QuotaBlock.height(for: keyless)
                     == QuotaBlock.topPadding + QuotaBlock.headerHeight + QuotaBlock.bottomPadding)
    }

    private static func testLabelWidth() {
        // Short window names keep the spec's fixed column.
        let short = makeCard(rows: [
            Row(label: "5-hour", percent: 30, detail: "resets in 3h 48m"),
            Row(label: "Weekly", percent: 71, detail: "resets in 3d 4h"),
        ])
        precondition(QuotaBlock.labelWidth(for: short) == QuotaBlock.minLabelWidth)

        // Scoped-model labels must not all collapse to the same truncated
        // prefix — the column grows, but only up to the cap.
        let long = makeCard(rows: [
            Row(label: "Weekly (Fable)", percent: 0, detail: "resets in 1d 0h"),
            Row(label: "Weekly (Opus)", percent: 0, detail: "resets in 1d 0h"),
        ])
        let grown = QuotaBlock.labelWidth(for: long)
        precondition(grown > QuotaBlock.minLabelWidth, "a long label must widen its own block's column")
        precondition(grown <= QuotaBlock.maxLabelWidth, "the bar keeps a usable minimum width")
        let widest = ("Weekly (Fable)" as NSString)
            .size(withAttributes: [.font: QuotaBlock.labelFont]).width
        precondition(grown >= widest, "the widest label in the block must fit without truncation")

        // Absurd labels clamp rather than eating the bar entirely.
        let absurd = makeCard(rows: [Row(label: String(repeating: "x", count: 200), percent: 1, detail: "")])
        precondition(QuotaBlock.labelWidth(for: absurd) == QuotaBlock.maxLabelWidth)

        // A block with no rows at all still reports a sane column.
        precondition(QuotaBlock.labelWidth(for: makeCard(rows: [])) == QuotaBlock.minLabelWidth)
    }

    private static func testAccessibilityLabel() {
        let label = QuotaBlock.accessibilityLabel(for: makeCard(
            rows: [Row(label: "5-hour", percent: 42, detail: "resets in 4h 53m")],
            badge: Badge(text: "stale — rate limited", kind: .amber)
        ))
        precondition(label.contains("Claude"))
        precondition(label.contains("42 percent"), "the percent survives in the accessibility text")
        precondition(label.contains("stale"))

        let keyless = QuotaBlock.accessibilityLabel(
            for: makeCard(provider: "OpenRouter", rows: [], missingKey: true)
        )
        precondition(keyless.contains(QuotaBlock.missingKeyText))
    }
}
