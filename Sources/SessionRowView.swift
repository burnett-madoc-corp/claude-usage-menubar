import AppKit

// MARK: - Sessions table geometry

enum SessionGrid {
    static let dotColumn: CGFloat = 14
    /// Fixed width for the model and context window column.
    static let modelWidth: CGFloat = 124
    /// Fixed width for the agent harness identifier column.
    static let harnessWidth: CGFloat = 44
    static let contextWidth: CGFloat = 76
    static let bloatWidth: CGFloat = 44
    static let turnsWidth: CGFloat = 34
    static let inOutWidth: CGFloat = 72
    static let spentWidth: CGFloat = 44

    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 16
    static let barHeight: CGFloat = 5
    static let dotDiameter: CGFloat = 8
    static let expandedLineHeight: CGFloat = 13

    /// Smaller font sized to ensure context fallback text fits within 76pt.
    static let fallbackFont = PanelFont.text(9)

    struct Columns {
        var dot: NSRect
        var name: NSRect
        var harness: NSRect
        var model: NSRect
        var context: NSRect
        var bloat: NSRect
        var turns: NSRect
        var inOut: NSRect
        var spent: NSRect

        /// Spans context and bloat columns to fit longer status text when no usage exists.
        var contextSpanningBloat: NSRect {
            NSRect(x: context.minX, y: context.minY,
                   width: bloat.maxX - context.minX, height: context.height)
        }

        /// Expands header cell into the inter-column gap to prevent title truncation.
        func headerCell(_ cell: NSRect) -> NSRect {
            NSRect(x: cell.minX - Panel.columnGap, y: cell.minY,
                   width: cell.width + Panel.columnGap, height: cell.height)
        }
    }

    static func columns(width: CGFloat, y: CGFloat, height: CGFloat) -> Columns {
        let right = width - Panel.inset
        let spentX = right - spentWidth
        let inOutX = spentX - Panel.columnGap - inOutWidth
        let turnsX = inOutX - Panel.columnGap - turnsWidth
        let bloatX = turnsX - Panel.columnGap - bloatWidth
        let contextX = bloatX - Panel.columnGap - contextWidth
        let nameX = Panel.inset + dotColumn
        let modelX = contextX - Panel.columnGap - modelWidth
        let harnessX = modelX - Panel.columnGap - harnessWidth
        return Columns(
            dot: NSRect(x: Panel.inset, y: y, width: dotColumn, height: height),
            name: NSRect(x: nameX, y: y, width: max(0, harnessX - Panel.columnGap - nameX), height: height),
            harness: NSRect(x: harnessX, y: y, width: harnessWidth, height: height),
            model: NSRect(x: modelX, y: y, width: modelWidth, height: height),
            context: NSRect(x: contextX, y: y, width: contextWidth, height: height),
            bloat: NSRect(x: bloatX, y: y, width: bloatWidth, height: height),
            turns: NSRect(x: turnsX, y: y, width: turnsWidth, height: height),
            inOut: NSRect(x: inOutX, y: y, width: inOutWidth, height: height),
            spent: NSRect(x: spentX, y: y, width: spentWidth, height: height)
        )
    }
}

// MARK: - Detailed session row: pure composition helpers

enum DetailedSessionRow {
    /// Returns task title if present, otherwise falls back to session working directory label.
    nonisolated static func displayName(for session: AgentSession) -> String {
        guard let title = session.taskTitle, !title.isEmpty else { return session.label }
        return title
    }

    /// Combined session name, model, and context window for accessibility and test matching.
    nonisolated static func nameAndModel(for session: AgentSession) -> String {
        let name = displayName(for: session)
        guard let model = session.model else { return name }
        return "\(name)  \(Display.modelWithWindow(model, window: session.contextWindow))"
    }

    /// Formatted context bloat multiple over starting context.
    nonisolated static func bloat(for session: AgentSession) -> String {
        Display.bloat(session.xFloorMultiple)
    }

    /// Fallback string when context bar cannot be drawn, or nil if percentage bar should be drawn.
    nonisolated static func contextFallback(for session: AgentSession) -> String? {
        if !session.hasUsage { return "starting — no usage yet" }
        if session.contextPercent != nil { return nil }
        if session.contextTokens != nil { return "window unknown" }
        return "context —"
    }

    /// Formatted turn count, or empty string when no usage has occurred.
    nonisolated static func turnsText(for session: AgentSession) -> String {
        session.hasUsage ? "\(session.turns)" : ""
    }

    nonisolated static func inOutText(for session: AgentSession) -> String {
        session.hasUsage ? Display.inOut(input: session.inputTokens, output: session.outputTokens) : ""
    }

    /// Multi-line details rendered when expanding a session row.
    nonisolated static func expandedText(for session: AgentSession) -> String {
        var lines: [String] = [session.cwd]
        if session.compactionCount > 0 {
            let when = session.lastCompactionAt.map(Format.ago) ?? "—"
            let pre = session.lastCompactionPreCtx
            let post = session.lastCompactionPostCtx
            let preText = pre.map { Format.tokens($0) } ?? "—"
            if let pre, let post {
                let reclaimedPercent = pre > 0 ? Int((Double(pre - post) / Double(pre) * 100).rounded()) : 0
                lines.append("last compaction \(when): \(preText) -> \(Format.tokens(post)) (-\(reclaimedPercent)%)")
            } else {
                lines.append("last compaction \(when): \(preText) -> reclaim —")
            }
        }
        if let subagent = session.subagentTokens {
            lines.append("subagents: \(Format.tokens(subagent)) tokens")
        }
        if !session.matched {
            lines.append("(?) matched heuristically — the PID<->transcript link is a best guess, not exact")
        }
        return lines.joined(separator: "\n")
    }

    /// Full accessibility label describing session state and metrics.
    nonisolated static func accessibilityLabel(for session: AgentSession) -> String {
        var parts: [String] = [session.busy ? "busy" : "idle", session.kind.displayName,
                                displayName(for: session)]
        if let model = session.model {
            parts.append(Display.modelWithWindow(model, window: session.contextWindow))
        }
        if let percent = session.contextPercent {
            parts.append("context bar \(percent) percent")
        } else if let fallback = contextFallback(for: session) {
            parts.append(fallback)
        }
        parts.append("bloat " + bloat(for: session))
        if session.hasUsage {
            parts.append("\(session.turns) turns")
            parts.append(inOutText(for: session) + " in and out")
        }
        if session.compactionCount > 0 { parts.append("\(session.compactionCount) compactions") }
        return parts.joined(separator: ", ")
    }

    /// Column header titles for the sessions table.
    nonisolated static let columnHeaders =
        (name: "SESSION", harness: "HARNESS", model: "MODEL", context: "CONTEXT",
         bloat: "BLOAT", turns: "TURNS", inOut: "IN/OUT", spent: "$ SPENT")
}

// MARK: - Column-header line

@MainActor
final class SessionHeaderView: NSView {
    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: SessionGrid.headerHeight))
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("SessionHeaderView does not support NSCoding")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let columns = SessionGrid.columns(width: bounds.width, y: 0, height: bounds.height)
        let font = PanelFont.text(10, .medium)
        let color = NSColor.tertiaryLabelColor
        let headers = DetailedSessionRow.columnHeaders
        Draw.text(headers.name, font: font, color: color, in: columns.name)
        Draw.text(headers.harness, font: font, color: color, in: columns.harness)
        Draw.text(headers.model, font: font, color: color, in: columns.model)
        Draw.text(headers.context, font: font, color: color, in: columns.context)
        Draw.text(headers.bloat, font: font, color: color,
                  in: columns.headerCell(columns.bloat), alignment: .right)
        Draw.text(headers.turns, font: font, color: color,
                  in: columns.headerCell(columns.turns), alignment: .right)
        Draw.text(headers.inOut, font: font, color: color,
                  in: columns.headerCell(columns.inOut), alignment: .right)
        Draw.text(headers.spent, font: font, color: color,
                  in: columns.headerCell(columns.spent), alignment: .right)
    }
}

// MARK: - Detailed session row view
//
// A custom NSMenuItem.view. Everything attributedTitle rows get for free —
// highlight, sizing, dark-mode colour resolution, accessibility, and the fact
// that a click just works — has to be hand-rolled here. Each subsection below
// is one of the plan's five numbered Detailed-mode obligations; the redesign
// changed what is drawn inside draw(_:), not any of those five mechanisms.
@MainActor
final class SessionRowView: NSView {
    private static let expandedPadding: CGFloat = 8

    private(set) var session: AgentSession
    private(set) var isExpanded: Bool
    private var rowWidth: CGFloat
    private var dotTimer: Timer?
    private var dotPhaseOn = true

    /// Lets the owner (UsageMenuBar) persist expanded state per session key
    /// across a full menu rebuild, not just an in-place update — a session
    /// reordering (severity changing while the menu is open) forces a rebuild
    /// that recreates this view from scratch, and the obligation is that
    /// expansion survives that too, not only the common in-place path.
    var onToggleExpanded: ((Bool) -> Void)?

    init(session: AgentSession, width: CGFloat, expanded: Bool, animate: Bool) {
        self.session = session
        self.rowWidth = width
        self.isExpanded = expanded
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: SessionGrid.rowHeight))
        updateAccessibilityLabel()
        toolTip = UsageMenuBar.sessionTooltip(for: session)
        applySize()
        if animate { startAnimatingIfNeeded() }
    }

    required init?(coder: NSCoder) {
        fatalError("SessionRowView does not support NSCoding")
    }

    override var isFlipped: Bool { true }

    // MARK: - Update in place

    func update(session: AgentSession, animate: Bool) {
        self.session = session
        updateAccessibilityLabel()
        toolTip = UsageMenuBar.sessionTooltip(for: session)
        if session.busy, animate {
            startAnimatingIfNeeded()
        } else {
            stopAnimating()
        }
        applySize()
        needsDisplay = true
    }

    private func updateAccessibilityLabel() {
        setAccessibilityElement(true)
        setAccessibilityLabel(DetailedSessionRow.accessibilityLabel(for: session))
    }

    // MARK: - Sizing

    private func applySize() {
        var height = SessionGrid.rowHeight
        if isExpanded {
            let lineCount = max(1, DetailedSessionRow.expandedText(for: session).split(separator: "\n").count)
            height += CGFloat(lineCount) * SessionGrid.expandedLineHeight + Self.expandedPadding
        }
        if frame.width != rowWidth || frame.height != height {
            setFrameSize(NSSize(width: rowWidth, height: height))
        }
    }

    // MARK: - Animation

    func startAnimatingIfNeeded() {
        guard dotTimer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.dotPhaseOn.toggle()
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(t, forMode: .common)
        dotTimer = t
    }

    /// Stops pulsing animation and releases the timer.
    func stopAnimating() {
        dotTimer?.invalidate()
        dotTimer = nil
    }

    // MARK: - Tracking & selection

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }

    // MARK: - Expansion

    override func mouseDown(with event: NSEvent) {
        // Consumed to prevent menu item selection handling.
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isExpanded.toggle()
        onToggleExpanded?(isExpanded)
        applySize()
        needsDisplay = true
        requestMenuRelayout()
    }

    /// Workaround: removes and reinserts menu item to force NSMenu to re-measure open menu layout.
    private func requestMenuRelayout() {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        let index = menu.index(of: item)
        guard index >= 0 else { return }
        menu.removeItem(at: index)
        menu.insertItem(item, at: index)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        (highlighted ? NSColor.selectedContentBackgroundColor : NSColor.clear).setFill()
        bounds.fill()

        let columns = SessionGrid.columns(width: rowWidth, y: 0, height: SessionGrid.rowHeight)
        // Highlighted rows use selected text color for contrast against selection fill.
        let accent = highlighted ? NSColor.selectedMenuItemTextColor : ProviderAccent.forSession(session.kind).color
        let label = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let secondary = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.secondaryLabelColor
        let severity = highlighted ? NSColor.selectedMenuItemTextColor : session.severity.color

        drawDot(in: columns.dot, accent: accent)
        drawName(in: columns.name, modelRect: columns.model, label: label, accent: accent)
        drawHarness(in: columns.harness, secondary: secondary)
        drawContext(columns: columns, severity: severity, secondary: secondary)
        drawBloat(in: columns.bloat, severity: severity)
        drawTurns(in: columns.turns, highlighted: highlighted)
        drawInOut(in: columns.inOut, highlighted: highlighted, secondary: secondary)
        drawSpent(in: columns.spent, highlighted: highlighted, secondary: secondary)

        guard isExpanded else { return }
        let text = DetailedSessionRow.expandedText(for: session)
        let x = columns.name.minX
        let rect = NSRect(x: x, y: SessionGrid.rowHeight,
                          width: max(0, rowWidth - Panel.inset - x),
                          height: max(0, frame.height - SessionGrid.rowHeight))
        (text as NSString).draw(in: rect, withAttributes: [
            .font: PanelFont.text(10), .foregroundColor: secondary,
        ])
    }

    /// Draws provider dot with accent color; filled indicates busy, pulsing modulates alpha.
    private func drawDot(in rect: NSRect, accent: NSColor) {
        let pulsing = session.busy && dotTimer != nil && !dotPhaseOn
        Draw.dot(centeredIn: rect, diameter: SessionGrid.dotDiameter,
                 color: pulsing ? accent.withAlphaComponent(0.45) : accent,
                 filled: session.busy)
    }

    /// Draws session title and model with context window in separate fixed columns.
    private func drawName(in nameRect: NSRect, modelRect: NSRect, label: NSColor, accent: NSColor) {
        var runs: [(String, NSFont, NSColor)] =
            [(DetailedSessionRow.displayName(for: session), PanelFont.text(11, .semibold), label)]
        if !session.matched { runs.append(("(?)", PanelFont.text(10), label)) }
        Draw.runs(runs, in: nameRect)

        guard let model = session.model else { return }
        Draw.text(Display.modelWithWindow(model, window: session.contextWindow),
                  font: PanelFont.text(10), color: accent, in: modelRect)
    }

    private func drawHarness(in rect: NSRect, secondary: NSColor) {
        Draw.text(session.kind.displayName, font: PanelFont.text(10), color: secondary, in: rect)
    }

    private func drawContext(columns: SessionGrid.Columns, severity: NSColor, secondary: NSColor) {
        guard let fallback = DetailedSessionRow.contextFallback(for: session) else {
            let percent = session.contextPercent ?? 0
            let rect = columns.context
            Draw.track(in: NSRect(x: rect.minX, y: rect.midY - SessionGrid.barHeight / 2,
                                  width: rect.width, height: SessionGrid.barHeight),
                       fraction: Double(percent) / 100, fill: severity)
            return
        }
        let cell = session.hasUsage ? columns.context : columns.contextSpanningBloat
        Draw.text(fallback, font: SessionGrid.fallbackFont, color: secondary, in: cell)
    }

    private func drawBloat(in rect: NSRect, severity: NSColor) {
        // Suppressed when the spanning no-usage status occupies the cell.
        guard session.hasUsage else { return }
        Draw.text(DetailedSessionRow.bloat(for: session),
                  font: PanelFont.number(11, .bold), color: severity, in: rect, alignment: .right)
    }

    private func drawTurns(in rect: NSRect, highlighted: Bool) {
        let text = DetailedSessionRow.turnsText(for: session)
        guard !text.isEmpty else { return }
        let color = highlighted ? NSColor.selectedMenuItemTextColor : Grade.turnsColor(session.turns)
        Draw.text(text, font: PanelFont.number(11), color: color, in: rect, alignment: .right)
    }

    private func drawInOut(in rect: NSRect, highlighted: Bool, secondary: NSColor) {
        guard session.hasUsage else { return }
        let font = PanelFont.number(10)
        let inputColor = highlighted ? NSColor.selectedMenuItemTextColor : Grade.inputColor(session.inputTokens)
        let outputColor = highlighted ? NSColor.selectedMenuItemTextColor : Grade.outputColor(session.outputTokens)
        Draw.runs([
            (Format.tokens(session.inputTokens), font, inputColor),
            (Display.inOutSeparator, font, secondary),
            (Format.tokens(session.outputTokens), font, outputColor),
        ], in: rect, alignment: .right)
    }

    private func drawSpent(in rect: NSRect, highlighted: Bool, secondary: NSColor) {
        guard session.hasUsage else { return }
        let text: String
        if let spent = session.exactSpent {
            text = String(format: "$%.3f", spent)
        } else if session.kind != .pi {
            // For now, only pi is fully implemented
            text = "—"
        } else {
            text = "—"
        }
        let color = highlighted ? NSColor.selectedMenuItemTextColor : secondary
        Draw.text(text, font: PanelFont.number(11), color: color, in: rect, alignment: .right)
    }
}

// MARK: - Self-tests
//
// Data-side only, per the phase brief ("do not attempt to unit-test
// drawing"): every pure composition helper in DetailedSessionRow gets fixture
// coverage mirroring testCompactSessionRendering's fixtures, using the same
// makeSession(...) builder main.swift's Compact self-tests already define.

enum DetailedSessionRowSelfTests {
    static func run() {
        testDisplayName()
        testNameAndModel()
        testCells()
        testContextFallbacksFit()
        testNameCellBudget()
        testExpandedText()
        testAccessibilityLabel()
        testGrid()
    }

    private static func testDisplayName() {
        // A titled session is named by what it is doing…
        let titled = makeSession(label: "worktree-ee",
                                 taskTitle: "Redesign dropdown menu layout")
        precondition(DetailedSessionRow.displayName(for: titled) == "Redesign dropdown menu layout")
        precondition(DetailedSessionRow.accessibilityLabel(for: titled).contains("Redesign"))

        // …and an untitled one falls back to where it is running, never blank.
        let untitled = makeSession(label: "worktree-a7", taskTitle: nil)
        precondition(DetailedSessionRow.displayName(for: untitled) == "worktree-a7")

        // An empty title is a missing title, not a blank row.
        precondition(DetailedSessionRow.displayName(for: makeSession(label: "fallback", taskTitle: ""))
                     == "fallback")

        // Compact and --once still key off `label` — the title is Detailed-only.
        precondition(UsageMenuBar.compactLine(for: titled).contains("worktree-ee"))
        precondition(!UsageMenuBar.compactLine(for: titled).contains("Redesign"))
    }

    private static func testNameAndModel() {
        let named = DetailedSessionRow.nameAndModel(for: makeSession(label: "sqlmesh-be"))
        precondition(named.contains("sqlmesh-be"))
        precondition(named.contains("opus-5"), "the model is shortened for the row")
        precondition(!named.contains("claude-opus-5"), "the vendor prefix is dropped")
        precondition(named.contains("(200k)"), "the model carries its context window")

        var wide = makeSession(label: "wide")
        wide.contextWindow = 1_000_000
        precondition(DetailedSessionRow.nameAndModel(for: wide).contains("(1m)"))

        var unknownWindow = makeSession(label: "unknown")
        unknownWindow.contextWindow = nil
        precondition(DetailedSessionRow.nameAndModel(for: unknownWindow).hasSuffix("opus-5"),
                     "an unknown window adds no suffix at all")
    }

    private static func testCells() {
        // Nil bloat multiple renders as a dash.
        precondition(DetailedSessionRow.bloat(for: makeSession(xFloorMultiple: 4.5)) == "4.5×")
        precondition(DetailedSessionRow.bloat(for: makeSession(xFloorMultiple: nil)) == "—")
        precondition(!DetailedSessionRow.bloat(for: makeSession(xFloorMultiple: 4.5)).contains("x"))

        // Known window renders as a progress bar without percentage text.
        let normal = makeSession(contextTokens: 84_000, contextWindow: 200_000)
        precondition(DetailedSessionRow.contextFallback(for: normal) == nil,
                     "a known context window draws a bar, not text")
        precondition(!DetailedSessionRow.nameAndModel(for: normal).contains("%"))
        precondition(!DetailedSessionRow.turnsText(for: normal).contains("%"))
        precondition(!DetailedSessionRow.inOutText(for: normal).contains("%"),
                     "no cell on the row carries a context percentage any more")

        // Unknown window: text, never a 0% bar standing in for unknown.
        let unknownWindow = makeSession(contextTokens: 488_000, contextWindow: nil)
        precondition(DetailedSessionRow.contextFallback(for: unknownWindow) == "window unknown")

        // No usage yet: the state text, and no turns or totals at all.
        let noUsage = makeSession(turns: 0, contextTokens: nil, contextWindow: nil, hasUsage: false)
        precondition(DetailedSessionRow.contextFallback(for: noUsage) == "starting — no usage yet")
        precondition(DetailedSessionRow.turnsText(for: noUsage).isEmpty,
                     "turns must not render for a session with no usage yet")
        precondition(DetailedSessionRow.inOutText(for: noUsage).isEmpty)

        precondition(DetailedSessionRow.turnsText(for: makeSession(turns: 137)) == "137")
        precondition(DetailedSessionRow.inOutText(for: normal).contains(" / "))
    }

    /// Verifies that context fallback strings fit within designated column widths.
    private static func testContextFallbacksFit() {
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: SessionGrid.fallbackFont]).width
        }
        let columns = SessionGrid.columns(width: Panel.width, y: 0, height: SessionGrid.rowHeight)

        // States that stay inside the context cell.
        for session in [makeSession(contextTokens: 488_000, contextWindow: nil),
                        makeSession(contextTokens: nil, contextWindow: nil)] {
            guard let fallback = DetailedSessionRow.contextFallback(for: session) else { continue }
            precondition(width(fallback) <= columns.context.width,
                         "context fallback '\(fallback)' must fit its own cell without truncating")
        }

        // The no-usage state is the one that borrows the ×start cell.
        let noUsage = makeSession(turns: 0, contextTokens: nil, contextWindow: nil, hasUsage: false)
        let spanning = DetailedSessionRow.contextFallback(for: noUsage)!
        precondition(width(spanning) > columns.context.width,
                     "if this ever fits alone, drop the cell merge instead of keeping it")
        precondition(width(spanning) <= columns.contextSpanningBloat.width)
    }

    /// Validates that widest model and task title strings fit within their column widths.
    private static func testNameCellBudget() {
        let columns = SessionGrid.columns(width: Panel.width, y: 0, height: SessionGrid.rowHeight)
        let font = PanelFont.text(10)
        let widest = Display.modelWithWindow("gpt-5.2-codex", window: 200_000)
        precondition((widest as NSString).size(withAttributes: [.font: font]).width <= columns.model.width,
                     "the widest model+window must fit its own column without truncating")
        precondition((DetailedSessionRow.columnHeaders.model as NSString)
                     .size(withAttributes: [.font: PanelFont.text(10, .medium)]).width <= columns.model.width)
        // Measures character budget for variable-width session title column.
        let nameFont = PanelFont.text(11, .semibold)
        let title = "Redesign dropdown menu layout and provider color coding"
        var fitted = 0
        for end in 1...title.count {
            let candidate = String(title.prefix(end))
            if (candidate as NSString).size(withAttributes: [.font: nameFont]).width > columns.name.width {
                break
            }
            fitted = end
        }
        precondition((18...26).contains(fitted),
                     "the name column should afford ~22 characters of a task title, fits \(fitted)")
    }

    private static func testExpandedText() {
        let noCompaction = makeSession(compactionCount: 0)
        let noCompactionText = DetailedSessionRow.expandedText(for: noCompaction)
        precondition(!noCompactionText.contains("compaction"),
                     "zero compactions must render no compaction line at all")
        precondition(noCompactionText.hasPrefix("/Users/dev/"), "cwd is always the first expanded line")

        var pending = makeSession(compactionCount: 1)
        pending.lastCompactionPreCtx = 140_000
        pending.lastCompactionPostCtx = nil
        precondition(DetailedSessionRow.expandedText(for: pending).contains("reclaim —"),
                     "pending reclaim (marker is the newest record) must render as —, never 0 or 100%")

        var reclaimed = makeSession(compactionCount: 1)
        reclaimed.lastCompactionPreCtx = 140_000
        reclaimed.lastCompactionPostCtx = 52_000
        let reclaimedText = DetailedSessionRow.expandedText(for: reclaimed)
        precondition(reclaimedText.contains("52k"))
        precondition(reclaimedText.contains("%"))

        var withSubagent = makeSession()
        withSubagent.subagentTokens = 412_000
        precondition(DetailedSessionRow.expandedText(for: withSubagent).contains("subagents:"))

        let unmatched = makeSession(matched: false)
        precondition(DetailedSessionRow.expandedText(for: unmatched).contains("heuristically"))
    }

    private static func testAccessibilityLabel() {
        let busyLabel = DetailedSessionRow.accessibilityLabel(for: makeSession(label: "sqlmesh-be", busy: true))
        precondition(busyLabel.contains("busy"))
        precondition(busyLabel.contains("sqlmesh-be"))
        precondition(busyLabel.contains("bloat"))

        let idleLabel = DetailedSessionRow.accessibilityLabel(for: makeSession(busy: false))
        precondition(idleLabel.contains("idle"))

        // Accessibility text states the context percentage represented by the bar.
        let normal = DetailedSessionRow.accessibilityLabel(
            for: makeSession(contextTokens: 84_000, contextWindow: 200_000)
        )
        precondition(normal.contains("context bar 42 percent"))

        let noUsageLabel = DetailedSessionRow.accessibilityLabel(
            for: makeSession(turns: 0, contextTokens: nil, contextWindow: nil, hasUsage: false)
        )
        precondition(noUsageLabel.contains("no usage yet"))
    }

    private static func testGrid() {
        let columns = SessionGrid.columns(width: Panel.width, y: 0, height: SessionGrid.rowHeight)
        // Verifies columns do not overlap and right-align with panel margin.
        precondition(columns.dot.maxX <= columns.name.minX)
        precondition(columns.name.maxX <= columns.harness.minX)
        precondition(columns.harness.maxX <= columns.model.minX)
        precondition(columns.model.maxX <= columns.context.minX)
        precondition(columns.context.maxX <= columns.bloat.minX)
        precondition(columns.bloat.maxX <= columns.turns.minX)
        precondition(columns.turns.maxX <= columns.inOut.minX)
        precondition(columns.inOut.maxX <= columns.spent.minX)
        precondition(columns.spent.maxX == Panel.width - Panel.inset)
        precondition(columns.name.width > 0, "the flexible name column must survive the fixed ones")

        // The merged no-usage cell covers both columns it borrows, and only those.
        let merged = columns.contextSpanningBloat
        precondition(merged.minX == columns.context.minX)
        precondition(merged.maxX == columns.bloat.maxX)
        precondition(merged.width > columns.context.width)

        // Header cells expand into gap without moving right alignment.
        let headerFont = PanelFont.text(10, .medium)
        for (title, cell) in [
            (DetailedSessionRow.columnHeaders.harness, columns.harness),
            (DetailedSessionRow.columnHeaders.bloat, columns.bloat),
            (DetailedSessionRow.columnHeaders.turns, columns.turns),
            (DetailedSessionRow.columnHeaders.inOut, columns.inOut),
            (DetailedSessionRow.columnHeaders.spent, columns.spent),
        ] {
            let header = columns.headerCell(cell)
            precondition(header.maxX == cell.maxX, "the header must stay aligned to its column's right edge")
            precondition(header.width > cell.width)
            precondition((title as NSString).size(withAttributes: [.font: headerFont]).width <= header.width,
                         "column header \(title) must fit without truncating")
        }
    }
}
