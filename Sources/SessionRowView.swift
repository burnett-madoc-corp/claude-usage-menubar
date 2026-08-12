import AppKit

// MARK: - Sessions table geometry
//
// One fixed grid shared by the column-header line and every row, so the two
// can never drift apart. Columns are pinned from the right edge inwards —
// the numeric cells have fixed widths and the name/model cell absorbs
// whatever is left, which is what keeps the numbers in a straight line while
// project names vary wildly in length.
enum SessionGrid {
    static let dotColumn: CGFloat = 14
    /// The model+window gets its own fixed column rather than trailing the
    /// session name. Names vary from "codex-ui" to a 60-character task title,
    /// so following them left every model at a different x — the one ragged
    /// edge in an otherwise column-aligned panel. 124pt clears the widest pair
    /// the app can produce ("gpt-5.2-codex (200k)", 110.8pt).
    static let modelWidth: CGFloat = 124
    static let contextWidth: CGFloat = 76
    static let multipleWidth: CGFloat = 44
    static let turnsWidth: CGFloat = 34
    static let inOutWidth: CGFloat = 72

    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 16
    static let barHeight: CGFloat = 5
    static let dotDiameter: CGFloat = 8
    static let expandedLineHeight: CGFloat = 13

    /// The context cell's no-bar states are drawn a point smaller than the
    /// rest of the row: "window unknown" does not fit 76pt at 10pt and
    /// truncates to "window unkno…", which reads as a different, broken state
    /// rather than a known one. `testContextFallbacksFit` pins this.
    static let fallbackFont = PanelFont.text(9)

    struct Columns {
        var dot: NSRect
        var name: NSRect
        var model: NSRect
        var context: NSRect
        var multiple: NSRect
        var turns: NSRect
        var inOut: NSRect

        /// The no-usage state is the one cell content that cannot fit its own
        /// column: "starting — no usage yet" is wider than the 76pt context
        /// cell at any legible size. It is also the one state where the
        /// neighbouring ×start cell is guaranteed empty — `xFloorMultiple` is
        /// nil until there are deduped turns to divide — so those two cells
        /// merge for that state only, rather than truncating the sentence to
        /// "starting — n…" or inventing a shorter wording the rest of the app
        /// doesn't use.
        var contextSpanningMultiple: NSRect {
            NSRect(x: context.minX, y: context.minY,
                   width: multiple.maxX - context.minX, height: context.height)
        }

        /// Column headers are wider than the numbers they sit above — "TURNS"
        /// does not fit the 34pt turns column and truncates to "TUR…". The
        /// data cells keep their exact widths; only the header line is allowed
        /// to reach back across the inter-column gap into the slack its
        /// left-hand neighbour always has.
        func headerCell(_ cell: NSRect) -> NSRect {
            NSRect(x: cell.minX - Panel.columnGap, y: cell.minY,
                   width: cell.width + Panel.columnGap, height: cell.height)
        }
    }

    static func columns(width: CGFloat, y: CGFloat, height: CGFloat) -> Columns {
        let right = width - Panel.inset
        let inOutX = right - inOutWidth
        let turnsX = inOutX - Panel.columnGap - turnsWidth
        let multipleX = turnsX - Panel.columnGap - multipleWidth
        let contextX = multipleX - Panel.columnGap - contextWidth
        let nameX = Panel.inset + dotColumn
        let modelX = contextX - Panel.columnGap - modelWidth
        return Columns(
            dot: NSRect(x: Panel.inset, y: y, width: dotColumn, height: height),
            name: NSRect(x: nameX, y: y, width: max(0, modelX - Panel.columnGap - nameX), height: height),
            model: NSRect(x: modelX, y: y, width: modelWidth, height: height),
            context: NSRect(x: contextX, y: y, width: contextWidth, height: height),
            multiple: NSRect(x: multipleX, y: y, width: multipleWidth, height: height),
            turns: NSRect(x: turnsX, y: y, width: turnsWidth, height: height),
            inOut: NSRect(x: inOutX, y: y, width: inOutWidth, height: height)
        )
    }
}

// MARK: - Detailed session row: pure composition helpers
//
// Fixture-tested the same way `UsageMenuBar.compactLine` is (see
// `testCompactSessionRendering` in main.swift) — busy/idle, nil xFloor -> "—",
// unknown window, no-usage, and pending reclaim. These are the ONLY parts of
// Detailed mode that get self-tests: the view itself is a thin draw-time layer
// over these strings and its own AgentSession, and drawing is not unit-tested.
//
// Detailed no longer shares `sessionMultiple`/`sessionGauge` with Compact.
// Those two still render the ASCII `3.2x` and a text `████░░ 42%` gauge, which
// Compact mode and the `--once` printer both depend on verbatim; the table
// below uses the `×` glyph and draws its context as a bar with no percentage
// at all, so the two now compose their strings separately on purpose.
enum DetailedSessionRow {
    /// What the row calls this session: its task title when Claude Code has
    /// named one, otherwise the directory it runs in. The fallback is a plain
    /// substitution, drawn identically — a session without a title yet is not
    /// a degraded row, just a new one.
    nonisolated static func displayName(for session: AgentSession) -> String {
        guard let title = session.taskTitle, !title.isEmpty else { return session.label }
        return title
    }

    /// The whole identity cell: name, then the shortened model and its context
    /// window. Kept as one string for the accessibility text and self-tests;
    /// the view draws the two halves in different fonts and colours.
    nonisolated static func nameAndModel(for session: AgentSession) -> String {
        let name = displayName(for: session)
        guard let model = session.model else { return name }
        return "\(name)  \(Display.modelWithWindow(model, window: session.contextWindow))"
    }

    /// The ×start multiple, with the `×` glyph. `nil` still reads "—", never
    /// a fabricated 1.0.
    nonisolated static func multiple(for session: AgentSession) -> String {
        Display.multiple(session.xFloorMultiple)
    }

    /// What the context cell says when it cannot draw a bar. `nil` means the
    /// cell draws a bar instead — a 0% bar must never stand in for any of
    /// these, which would read as an empty context, the opposite of the truth.
    nonisolated static func contextFallback(for session: AgentSession) -> String? {
        if !session.hasUsage { return "starting — no usage yet" }
        if session.contextPercent != nil { return nil }
        if session.contextTokens != nil { return "window unknown" }
        return "context —"
    }

    /// Turns and in/out are omitted entirely while `hasUsage` is false — the
    /// context cell's own "starting — no usage yet" already carries that state,
    /// and "0" in a graded column would read as a real measurement.
    nonisolated static func turnsText(for session: AgentSession) -> String {
        session.hasUsage ? "\(session.turns)" : ""
    }

    nonisolated static func inOutText(for session: AgentSession) -> String {
        session.hasUsage ? Display.inOut(input: session.inputTokens, output: session.outputTokens) : ""
    }

    /// Click-to-expand detail: cwd, last-compaction reclaim (pre -> post, %;
    /// "reclaim —" while pending, never 0 or 100%), and subagent burn when
    /// present. Zero compactions renders no compaction line at all — absence
    /// of the marker is the display, matching the Compact tooltip's rule.
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

    /// Full-content accessibility label. The context percentage is no longer
    /// drawn anywhere on the row — the cell is a bare bar — so this is now the
    /// only place that value is stated, and it is stated as what it is: the
    /// bar's value.
    nonisolated static func accessibilityLabel(for session: AgentSession) -> String {
        var parts: [String] = [session.busy ? "busy" : "idle", displayName(for: session)]
        if let model = session.model {
            parts.append(Display.modelWithWindow(model, window: session.contextWindow))
        }
        if let percent = session.contextPercent {
            parts.append("context bar \(percent) percent")
        } else if let fallback = contextFallback(for: session) {
            parts.append(fallback)
        }
        parts.append("multiple " + multiple(for: session))
        if session.hasUsage {
            parts.append("\(session.turns) turns")
            parts.append(inOutText(for: session) + " in and out")
        }
        if session.compactionCount > 0 { parts.append("\(session.compactionCount) compactions") }
        return parts.joined(separator: ", ")
    }

    /// The tiny uppercase column-header line above the table. Exposed as text
    /// so the header view and the accessibility label agree on the wording.
    nonisolated static let columnHeaders =
        (name: "SESSION", model: "MODEL", context: "CONTEXT",
         multiple: "×START", turns: "TURNS", inOut: "IN/OUT")
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
        Draw.text(headers.model, font: font, color: color, in: columns.model)
        Draw.text(headers.context, font: font, color: color, in: columns.context)
        Draw.text(headers.multiple, font: font, color: color,
                  in: columns.headerCell(columns.multiple), alignment: .right)
        Draw.text(headers.turns, font: font, color: color,
                  in: columns.headerCell(columns.turns), alignment: .right)
        Draw.text(headers.inOut, font: font, color: color,
                  in: columns.headerCell(columns.inOut), alignment: .right)
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

    /// Top-left origin: the grid above reads far more naturally top-down than
    /// in AppKit's default bottom-left coordinate system.
    override var isFlipped: Bool { true }

    // MARK: - Update in place
    //
    // main.swift's applySessionUpdates() calls this on the SAME view instance
    // instead of recreating it: rebuilding a visible menu destroys the item
    // under the cursor, which would also collapse an expanded row, drop its
    // tooltip and restart the dot animation. So both isExpanded and dotTimer
    // are left untouched here except where the new data itself demands a
    // change (busy -> idle).
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

    // MARK: - Obligation 2: explicit sizing
    //
    // NSMenu auto-measures attributed-title rows but does nothing of the kind
    // for a custom view — the frame set here IS the row's size as far as
    // NSMenu is concerned. Recomputed only when content that affects it
    // actually changes (construction, an update, or a click), never inside
    // draw(_:).
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

    // MARK: - Obligation 3: the pulsing-dot run-loop trap
    //
    // NSMenu runs a modal event-tracking loop while open, so a timer added on
    // the default run-loop mode would freeze the instant the dot is visible.
    // `.common` mode is the fix, mirroring the precedent already in this
    // file's sibling (main.swift's refresh timer and sessions tick both do the
    // same, for the same reason).
    //
    // Idempotent by design (guarded on dotTimer == nil): a tick's repeated
    // calls into update() must never restart the animation or reset its phase,
    // only keep it running.
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

    /// Called from main.swift's menuDidClose for every live detailed row — an
    /// animation timer running while the menu is shut is pure waste. Also
    /// called from update() the moment a session stops being busy, even while
    /// the menu stays open.
    func stopAnimating() {
        dotTimer?.invalidate()
        dotTimer = nil
    }

    // MARK: - Obligation 1: hand-drawn highlight/selection
    //
    // A custom view inherits no hover/selection rendering at all. NSMenu still
    // tracks NSMenuItem.isHighlighted for a view-based item as the mouse
    // moves, but never redraws the view on its own — a tracking area's only
    // job here is to trigger needsDisplay at the right moments. The highlight
    // state actually drawn always comes straight from
    // enclosingMenuItem?.isHighlighted at draw time, never a locally tracked
    // flag, so it can never drift from what NSMenu believes is highlighted.
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

    // MARK: - Obligation 5: click-to-expand without dismissing the menu
    //
    // The NSMenuItem this view backs is built with action == nil (see
    // UsageMenuBar.addDetailedSessionRow), so NSMenu never treats a click here
    // as a selection that should close the menu. mouseDown is consumed (not
    // forwarded to super) purely so nothing above this view mistakes the press
    // for anything else; the actual toggle happens on mouseUp.
    override func mouseDown(with event: NSEvent) {
        // Intentionally consumed, no-op — see comment above.
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isExpanded.toggle()
        onToggleExpanded?(isExpanded)
        applySize()
        needsDisplay = true
        requestMenuRelayout()
    }

    /// NSMenu has no public "resize this item in place" API. Removing and
    /// immediately reinserting the same NSMenuItem at its own index is the
    /// standard workaround: it forces NSMenu to recompute geometry for the
    /// still-open menu without closing it. The item and this view are the same
    /// objects throughout, so session data, isExpanded, and the animation
    /// timer all survive untouched.
    private func requestMenuRelayout() {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        let index = menu.index(of: item)
        guard index >= 0 else { return }
        menu.removeItem(at: index)
        menu.insertItem(item, at: index)
    }

    // MARK: - Obligation 4: dark mode and accessibility by hand
    //
    // Every colour below is resolved right here, at draw time, from the
    // dynamic system colours and the dynamic accents in Theme.swift — never
    // baked into a stored value — so a live light/dark switch, or an
    // accessibility contrast change, is picked up on the very next redraw with
    // no extra plumbing. The accessibility label itself is kept current by
    // updateAccessibilityLabel(), called from both init and update(session:).
    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        (highlighted ? NSColor.selectedContentBackgroundColor : NSColor.clear).setFill()
        bounds.fill()

        let columns = SessionGrid.columns(width: rowWidth, y: 0, height: SessionGrid.rowHeight)
        // Under highlight the whole row collapses to the selected-text colour:
        // the accent and grading hues are tuned against the menu background,
        // not against a saturated selection fill.
        let accent = highlighted ? NSColor.selectedMenuItemTextColor : ProviderAccent.forSession(session.kind).color
        let label = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let secondary = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.secondaryLabelColor
        let severity = highlighted ? NSColor.selectedMenuItemTextColor : session.severity.color

        drawDot(in: columns.dot, accent: accent)
        drawName(in: columns.name, modelRect: columns.model, label: label, accent: accent)
        drawContext(columns: columns, severity: severity, secondary: secondary)
        drawMultiple(in: columns.multiple, severity: severity)
        drawTurns(in: columns.turns, highlighted: highlighted)
        drawInOut(in: columns.inOut, highlighted: highlighted, secondary: secondary)

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

    /// The provider dot replaces the old white ●/○ glyph pair: colour now
    /// carries which provider the session belongs to, and fill carries busy.
    /// The pulse modulates the filled dot's alpha rather than swapping it for
    /// the hollow one, so "filled means busy" holds at every phase.
    private func drawDot(in rect: NSRect, accent: NSColor) {
        let pulsing = session.busy && dotTimer != nil && !dotPhaseOn
        Draw.dot(centeredIn: rect, diameter: SessionGrid.dotDiameter,
                 color: pulsing ? accent.withAlphaComponent(0.45) : accent,
                 filled: session.busy)
    }

    /// Name and model are two fixed cells, not one run: the name is a task
    /// title of unbounded length and the model is a short bounded string, so
    /// letting the former push the latter around produced both a ragged model
    /// edge and, at narrower widths, a clipped "(200k)" — the one part of the
    /// row that cannot be inferred from anything else.
    private func drawName(in nameRect: NSRect, modelRect: NSRect, label: NSColor, accent: NSColor) {
        var runs: [(String, NSFont, NSColor)] =
            [(DetailedSessionRow.displayName(for: session), PanelFont.text(13, .semibold), label)]
        if !session.matched { runs.append(("(?)", PanelFont.text(10), label)) }
        Draw.runs(runs, in: nameRect)

        guard let model = session.model else { return }
        Draw.text(Display.modelWithWindow(model, window: session.contextWindow),
                  font: PanelFont.text(10), color: accent, in: modelRect)
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
        let cell = session.hasUsage ? columns.context : columns.contextSpanningMultiple
        Draw.text(fallback, font: SessionGrid.fallbackFont, color: secondary, in: cell)
    }

    private func drawMultiple(in rect: NSRect, severity: NSColor) {
        // Suppressed only where the no-usage text has already borrowed this
        // cell — everywhere else a nil multiple still draws its own "—".
        guard session.hasUsage else { return }
        Draw.text(DetailedSessionRow.multiple(for: session),
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
        // The multiple uses the × glyph now, and nil is still never 1.0.
        precondition(DetailedSessionRow.multiple(for: makeSession(xFloorMultiple: 4.5)) == "4.5×")
        precondition(DetailedSessionRow.multiple(for: makeSession(xFloorMultiple: nil)) == "—")
        precondition(!DetailedSessionRow.multiple(for: makeSession(xFloorMultiple: 4.5)).contains("x"))

        // A known window draws a bar and nothing else — the percentage is no
        // longer composed into any string on the row.
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

    /// Guards the one thing the fixed grid cannot express in code: that the
    /// strings actually fit the cells they are drawn into.
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
        precondition(width(spanning) <= columns.contextSpanningMultiple.width)
    }

    /// The model column is fixed, so the one thing that can silently break is
    /// the widest model+window no longer fitting it.
    private static func testNameCellBudget() {
        let columns = SessionGrid.columns(width: Panel.width, y: 0, height: SessionGrid.rowHeight)
        let font = PanelFont.text(10)
        let widest = Display.modelWithWindow("gpt-5.2-codex", window: 200_000)
        precondition((widest as NSString).size(withAttributes: [.font: font]).width <= columns.model.width,
                     "the widest model+window must fit its own column without truncating")
        precondition((DetailedSessionRow.columnHeaders.model as NSString)
                     .size(withAttributes: [.font: PanelFont.text(10, .medium)]).width <= columns.model.width)
        // The name column still has to be worth reading after the split.
        precondition(columns.name.width > 150, "a task title needs room to say what the task is")
    }

    private static func testExpandedText() {
        let noCompaction = makeSession(compactionCount: 0)
        let noCompactionText = DetailedSessionRow.expandedText(for: noCompaction)
        precondition(!noCompactionText.contains("compaction"),
                     "zero compactions must render no compaction line at all")
        precondition(noCompactionText.hasPrefix("/Users/alex/"), "cwd is always the first expanded line")

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
        precondition(busyLabel.contains("multiple"))

        let idleLabel = DetailedSessionRow.accessibilityLabel(for: makeSession(busy: false))
        precondition(idleLabel.contains("idle"))

        // The percentage is gone from the drawn row, so the accessibility text
        // is now the only place it is stated — and it states it as the bar's value.
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
        // Columns march left to right without overlapping, and the last one
        // ends exactly on the panel's right margin.
        precondition(columns.dot.maxX <= columns.name.minX)
        precondition(columns.name.maxX <= columns.model.minX)
        precondition(columns.model.maxX <= columns.context.minX)
        precondition(columns.context.maxX <= columns.multiple.minX)
        precondition(columns.multiple.maxX <= columns.turns.minX)
        precondition(columns.turns.maxX <= columns.inOut.minX)
        precondition(columns.inOut.maxX == Panel.width - Panel.inset)
        precondition(columns.name.width > 0, "the flexible name column must survive the fixed ones")

        // The merged no-usage cell covers both columns it borrows, and only those.
        let merged = columns.contextSpanningMultiple
        precondition(merged.minX == columns.context.minX)
        precondition(merged.maxX == columns.multiple.maxX)
        precondition(merged.width > columns.context.width)

        // Header cells reach back into the gap so "TURNS" fits above a 34pt
        // column, without moving the data cell's own right edge.
        let headerFont = PanelFont.text(10, .medium)
        for (title, cell) in [
            (DetailedSessionRow.columnHeaders.multiple, columns.multiple),
            (DetailedSessionRow.columnHeaders.turns, columns.turns),
            (DetailedSessionRow.columnHeaders.inOut, columns.inOut),
        ] {
            let header = columns.headerCell(cell)
            precondition(header.maxX == cell.maxX, "the header must stay aligned to its column's right edge")
            precondition(header.width > cell.width)
            precondition((title as NSString).size(withAttributes: [.font: headerFont]).width <= header.width,
                         "column header \(title) must fit without truncating")
        }
    }
}
