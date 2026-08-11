import AppKit

// MARK: - Detailed session row: pure composition helpers
//
// Fixture-tested the same way `UsageMenuBar.compactLine` is (see
// `testCompactSessionRendering` in main.swift) — busy/idle, the ⌁N hint
// absent at count 0, nil xFloor -> "—", unknown window, no-usage, and
// pending reclaim. These are the ONLY parts of Detailed mode that get
// self-tests: the view itself is a thin draw-time layer over these
// strings and its own AgentSession, and drawing is not unit-tested (see
// SessionRowView below, and the phase brief's note on that).
enum DetailedSessionRow {
    /// Line 1: busy dot (the *view* animates it; this plain-text form
    /// always renders the static glyph), session name, xFloor multiple,
    /// and the `⌁N` compaction hint (absent at count 0 — never "⌁0").
    nonisolated static func line1(for session: AgentSession) -> String {
        let dot = session.busy ? "●" : "○"
        let multiple = UsageMenuBar.sessionMultiple(for: session)
        let hint = UsageMenuBar.sessionCompactHint(for: session)
        return "\(dot) \(session.label)   \(multiple)\(hint)"
    }

    /// Line 2: model, context bar + %, turns, raw in/out totals. Turns and
    /// totals are omitted entirely while `hasUsage` is false — the gauge's
    /// own "starting — no usage yet" text already carries that state.
    nonisolated static func line2(for session: AgentSession) -> String {
        let model = session.model ?? "unknown model"
        let gauge = UsageMenuBar.sessionGauge(for: session)
        guard session.hasUsage else { return "\(model)   \(gauge)" }
        let totals = "\(Format.tokens(session.inputTokens)) in / \(Format.tokens(session.outputTokens)) out"
        return "\(model)   \(gauge)   \(session.turns) turns   \(totals)"
    }

    /// Click-to-expand detail: cwd, last-compaction reclaim (pre -> post,
    /// %; "reclaim —" while pending, never 0 or 100%), and subagent burn
    /// when present. Zero compactions renders no compaction line at all —
    /// absence of the marker is the display, matching the Compact tooltip's
    /// rule (`UsageMenuBar.sessionTooltip`).
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

    /// Full-content accessibility label — name, model, context %, multiple,
    /// turns — the same idea as `button.setAccessibilityLabel` already
    /// carries for the menu-bar title (main.swift's renderTitle).
    nonisolated static func accessibilityLabel(for session: AgentSession) -> String {
        var parts: [String] = [session.busy ? "busy" : "idle", session.label]
        if let model = session.model { parts.append(model) }
        if let percent = session.contextPercent {
            parts.append("\(percent) percent context")
        } else if !session.hasUsage {
            parts.append("no usage yet")
        }
        parts.append("multiple " + UsageMenuBar.sessionMultiple(for: session))
        if session.hasUsage { parts.append("\(session.turns) turns") }
        if session.compactionCount > 0 { parts.append("\(session.compactionCount) compactions") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Detailed session row view (Phase 4c)
//
// The first custom-view NSMenuItem surface in this app. Everything
// attributedTitle rows get for free — highlight, sizing, dark-mode colour
// resolution, accessibility, and the fact that a click just works — has to
// be hand-rolled here. Each subsection below is one of the plan's five
// numbered Detailed-mode obligations.
@MainActor
final class SessionRowView: NSView {
    private static let collapsedHeight: CGFloat = 34
    private static let expandedLineHeight: CGFloat = 13

    private(set) var session: AgentSession
    private(set) var isExpanded: Bool
    private var rowWidth: CGFloat
    private var dotTimer: Timer?
    private var dotPhaseOn = true

    /// Lets the owner (UsageMenuBar) persist expanded state per session key
    /// across a full menu rebuild, not just an in-place update — a session
    /// reordering (new usage landing while the menu is open) forces a
    /// rebuild that recreates this view from scratch, and the obligation is
    /// that expansion survives that too, not only the common in-place path.
    var onToggleExpanded: ((Bool) -> Void)?

    init(session: AgentSession, width: CGFloat, expanded: Bool, animate: Bool) {
        self.session = session
        self.rowWidth = width
        self.isExpanded = expanded
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.collapsedHeight))
        updateAccessibilityLabel()
        applySize()
        if animate { startAnimatingIfNeeded() }
    }

    required init?(coder: NSCoder) {
        fatalError("SessionRowView does not support NSCoding")
    }

    /// Top-left origin: line layout below reads far more naturally top-down
    /// than in AppKit's default bottom-left coordinate system.
    override var isFlipped: Bool { true }

    // MARK: - Update in place
    //
    // main.swift's applySessionUpdates() calls this on the SAME view
    // instance instead of recreating it, for exactly the reason addRow's
    // Compact patch-in-place already exists: rebuilding a visible menu
    // destroys the item under the cursor. Detailed raises the stakes — a
    // rebuild would also collapse an expanded row and restart the dot
    // animation — so both isExpanded and dotTimer are left untouched here
    // except where the new data itself demands a change (busy -> idle).
    func update(session: AgentSession, animate: Bool) {
        self.session = session
        updateAccessibilityLabel()
        if session.busy, animate {
            startAnimatingIfNeeded()
        } else {
            stopAnimating()
        }
        applySize()
        needsDisplay = true
    }

    /// Obligation 2 (explicit sizing) also covers width: it is computed
    /// once per rebuild by the owner (see UsageMenuBar.computeDetailedRowWidth)
    /// and pushed down here, never recomputed per frame.
    func setWidth(_ width: CGFloat) {
        guard width != rowWidth else { return }
        rowWidth = width
        applySize()
    }

    private func updateAccessibilityLabel() {
        setAccessibilityElement(true)
        setAccessibilityLabel(DetailedSessionRow.accessibilityLabel(for: session))
    }

    // MARK: - Obligation 2: explicit sizing
    //
    // NSMenu auto-measures attributed-title rows but does nothing of the
    // kind for a custom view — the frame set here IS the row's size as far
    // as NSMenu is concerned. Recomputed only when content that affects it
    // actually changes (construction, an update, or a click), never inside
    // draw(_:).
    private func applySize() {
        var height = Self.collapsedHeight
        if isExpanded {
            let lineCount = max(1, DetailedSessionRow.expandedText(for: session).split(separator: "\n").count)
            height += CGFloat(lineCount) * Self.expandedLineHeight + 10
        }
        if frame.width != rowWidth || frame.height != height {
            setFrameSize(NSSize(width: rowWidth, height: height))
        }
    }

    // MARK: - Obligation 3: the pulsing-dot run-loop trap
    //
    // NSMenu runs a modal event-tracking loop while open, so a timer added
    // on the default run-loop mode would freeze the instant the dot is
    // visible. `.common` mode is the fix, mirroring the exact precedent
    // already in this file's sibling (main.swift's refresh timer and
    // sessions tick both do the same, for the same reason).
    //
    // Idempotent by design (guarded on dotTimer == nil): a tick's repeated
    // calls into update() must never restart the animation or reset its
    // phase, only keep it running.
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

    /// Called from main.swift's menuDidClose for every live detailed row —
    /// an animation timer running while the menu is shut is pure waste.
    /// Also called from update() the moment a session stops being busy,
    /// even while the menu stays open.
    func stopAnimating() {
        dotTimer?.invalidate()
        dotTimer = nil
    }

    // MARK: - Obligation 1: hand-drawn highlight/selection
    //
    // A custom view inherits no hover/selection rendering at all. NSMenu
    // still tracks NSMenuItem.isHighlighted for a view-based item as the
    // mouse moves over it, but it never redraws the view on its own — a
    // tracking area's only job here is to trigger needsDisplay at the right
    // moments. The highlight state actually drawn always comes straight
    // from enclosingMenuItem?.isHighlighted at draw time (see draw(_:)
    // below), never a locally tracked flag, so it can never drift from
    // what NSMenu itself believes is highlighted.
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
    // UsageMenuBar.addDetailedSessionRow), so NSMenu never treats a click
    // here as a selection that should close the menu. mouseDown is
    // consumed (not forwarded to super) purely so nothing above this view
    // mistakes the press for anything else; the actual toggle happens on
    // mouseUp.
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
    /// still-open menu without closing it. The item and this view are the
    /// same objects throughout, so session data, isExpanded, and the
    /// animation timer all survive untouched.
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
    // dynamic system colours — never baked into a stored value — so a live
    // light/dark switch, or an accessibility contrast change, is picked up
    // on the very next redraw with no extra plumbing. The accessibility
    // label itself is kept current by updateAccessibilityLabel(), called
    // from both init and update(session:).
    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false

        (highlighted ? NSColor.selectedContentBackgroundColor : NSColor.clear).setFill()
        bounds.fill()

        let labelColor: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let secondaryColor: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        let severityColor: NSColor = highlighted ? .selectedMenuItemTextColor : session.severity.color
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let smallFont = NSFont.systemFont(ofSize: 10)

        drawLine1(labelColor: labelColor, severityColor: severityColor, secondaryColor: secondaryColor, font: monoFont, y: 6)
        drawLine2(secondaryColor: secondaryColor, severityColor: severityColor, font: monoFont,
                  y: 6 + Self.expandedLineHeight + 4)

        if isExpanded {
            let text = DetailedSessionRow.expandedText(for: session)
            let rect = NSRect(x: 18, y: Self.collapsedHeight,
                               width: max(0, rowWidth - 26), height: max(0, frame.height - Self.collapsedHeight))
            (text as NSString).draw(in: rect, withAttributes: [.font: smallFont, .foregroundColor: secondaryColor])
        }
    }

    private func drawLine1(labelColor: NSColor, severityColor: NSColor, secondaryColor: NSColor, font: NSFont, y: CGFloat) {
        let line = NSMutableAttributedString()
        func append(_ text: String, _ color: NSColor) {
            line.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        // The dot is the one piece of Detailed line 1 the pure DetailedSessionRow.line1(for:)
        // helper cannot express: it animates (dotPhaseOn) here, but always
        // renders statically when idle, matching the plan's "static ○ otherwise".
        append(session.busy ? (dotPhaseOn ? "●" : "○") : "○", labelColor)
        append("  \(session.label)", labelColor)
        append("   " + UsageMenuBar.sessionMultiple(for: session), severityColor)
        let hint = UsageMenuBar.sessionCompactHint(for: session)
        if !hint.isEmpty { append(" " + hint.trimmingCharacters(in: .whitespaces), secondaryColor) }
        line.draw(at: NSPoint(x: 10, y: y))
    }

    private func drawLine2(secondaryColor: NSColor, severityColor: NSColor, font: NSFont, y: CGFloat) {
        let line = NSMutableAttributedString()
        func append(_ text: String, _ color: NSColor) {
            line.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        append(session.model ?? "unknown model", secondaryColor)
        append("  " + UsageMenuBar.sessionGauge(for: session), session.contextPercent != nil ? severityColor : secondaryColor)
        if session.hasUsage {
            append("  \(session.turns)t", secondaryColor)
            append("  \(Format.tokens(session.inputTokens))in/\(Format.tokens(session.outputTokens))out", secondaryColor)
        }
        line.draw(at: NSPoint(x: 10, y: y))
    }
}

// MARK: - Self-tests
//
// Data-side only, per the phase brief ("do not attempt to unit-test
// drawing"): every pure composition helper in DetailedSessionRow gets
// fixture coverage mirroring testCompactSessionRendering's fixtures
// (busy/idle, ⌁N absent at 0, nil xFloor -> "—", unknown window, no-usage,
// pending reclaim), using the same makeSession(...) fixture builder
// main.swift's Compact self-tests already define.

enum DetailedSessionRowSelfTests {
    static func run() {
        testLine1()
        testLine2()
        testExpandedText()
        testAccessibilityLabel()
    }

    private static func testLine1() {
        precondition(DetailedSessionRow.line1(for: makeSession(busy: true)).hasPrefix("●"))
        precondition(DetailedSessionRow.line1(for: makeSession(busy: false)).hasPrefix("○"))

        precondition(!DetailedSessionRow.line1(for: makeSession(compactionCount: 0)).contains("⌁"),
                     "⌁0 must never render — absence of compactions is the display")
        precondition(DetailedSessionRow.line1(for: makeSession(compactionCount: 2)).contains("⌁2"))

        precondition(DetailedSessionRow.line1(for: makeSession(xFloorMultiple: nil)).contains("—"),
                     "nil xFloor must render as — never a fabricated 1.0x")
        precondition(DetailedSessionRow.line1(for: makeSession(xFloorMultiple: 4.5)).contains("4.5x"))
    }

    private static func testLine2() {
        let unknownWindow = makeSession(contextTokens: 488_000, contextWindow: nil)
        let unknownLine = DetailedSessionRow.line2(for: unknownWindow)
        precondition(unknownLine.contains("window unknown"))
        precondition(!unknownLine.contains("█") && !unknownLine.contains("░"),
                     "no bar beats a fabricated denominator")

        let noUsage = makeSession(turns: 0, contextTokens: nil, contextWindow: nil, hasUsage: false)
        let noUsageLine = DetailedSessionRow.line2(for: noUsage)
        precondition(noUsageLine.contains("starting — no usage yet"))
        precondition(!noUsageLine.contains("turns"), "turns must not render for a session with no usage yet")

        let normal = makeSession(contextTokens: 84_000, contextWindow: 200_000)
        let normalLine = DetailedSessionRow.line2(for: normal)
        precondition(normalLine.contains("42%"))
        precondition(normalLine.contains("in / "))
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

        let noUsageLabel = DetailedSessionRow.accessibilityLabel(
            for: makeSession(turns: 0, contextTokens: nil, contextWindow: nil, hasUsage: false)
        )
        precondition(noUsageLabel.contains("no usage yet"))
    }
}
