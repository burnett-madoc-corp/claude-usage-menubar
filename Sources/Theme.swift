import AppKit

// MARK: - Panel geometry
//
// The dropdown is one column of fixed width. Every custom view in the panel
// (quota blocks, session rows, the inset dividers between them) measures
// itself against these constants rather than against whatever NSMenu happens
// to have auto-sized the rows above it — that older approach made the panel
// visibly breathe in and out as provider labels changed length.
enum Panel {
    static let width: CGFloat = 470
    /// Left/right text margin. Intra-quota dividers are inset by this much on
    /// each side; the dividers before Sessions and before the footer are
    /// NSMenu's own full-width separators.
    static let inset: CGFloat = 16
    static let columnGap: CGFloat = 8
}

// MARK: - Colour primitives

enum Palette {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }

    /// A colour that resolves per appearance at draw time. The spec's fixed
    /// values are tuned for the dark menu background; on a light one the same
    /// hue needs to be darker to clear contrast, so each fixed value carries a
    /// deeper light-mode sibling. Nothing here is ever resolved and stored —
    /// a live appearance switch is picked up on the next redraw.
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func dynamicHex(dark: UInt32, light: UInt32) -> NSColor {
        dynamic(dark: hex(dark), light: hex(light))
    }

    /// The unfilled part of every track bar in the panel.
    static let track = NSColor.quaternaryLabelColor
}

// MARK: - Provider identity accent
//
// Identity only, never severity. A row's accent says *which* provider it
// belongs to; green/orange/red on the bars and the xStart multiple say how
// close to a limit it is. Keeping the two channels separate is why a healthy
// Claude row is coral rather than green.
enum ProviderAccent: Sendable {
    case claude, codex, neutral

    nonisolated static func forProvider(_ displayName: String) -> ProviderAccent {
        switch ProviderID(displayName: displayName) {
        case .claude: return .claude
        case .codex: return .codex
        default: return .neutral
        }
    }

    nonisolated static func forSession(_ kind: AgentKind) -> ProviderAccent {
        switch kind {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    var color: NSColor {
        switch self {
        case .claude: return Palette.dynamicHex(dark: 0xE08B6D, light: 0xC4694A)
        case .codex: return Palette.dynamicHex(dark: 0x4EC9A4, light: 0x2E9377)
        case .neutral: return Palette.dynamicHex(dark: 0x8A8C93, light: 0x6B6D73)
        }
    }
}

// MARK: - Magnitude grading ramp
//
// A muted four-stop ramp used for "how big is this number" cells — turns and
// the in/out token totals. Deliberately *not* the severity palette: these are
// magnitudes, not limits, and a session with a lot of turns is not in trouble.
enum Grade {
    static let stops: [NSColor] = [
        Palette.dynamicHex(dark: 0x8FBF94, light: 0x4E7D55),
        Palette.dynamicHex(dark: 0xD9CF7A, light: 0x7E742A),
        Palette.dynamicHex(dark: 0xE6B566, light: 0x8F6318),
        Palette.dynamicHex(dark: 0xF28B82, light: 0xB3453C),
    ]

    /// Index into `stops` for a value against ascending thresholds. Pure and
    /// integer-valued so the whole ramp is fixture-testable without drawing.
    nonisolated static func index(for value: Double, thresholds: [Double]) -> Int {
        var index = 0
        for threshold in thresholds where value >= threshold { index += 1 }
        return min(index, stops.count - 1)
    }

    static func color(for value: Double, thresholds: [Double]) -> NSColor {
        stops[index(for: value, thresholds: thresholds)]
    }

    static let turnsThresholds: [Double] = [80, 180, 300]
    /// Input is graded in millions, output in thousands — the two run orders
    /// of magnitude apart, so one shared threshold set would peg input at the
    /// top stop permanently.
    static let inputMillionsThresholds: [Double] = [10, 40, 70]
    static let outputThousandsThresholds: [Double] = [60, 140, 220]

    nonisolated static func turnsIndex(_ turns: Int) -> Int {
        index(for: Double(turns), thresholds: turnsThresholds)
    }

    nonisolated static func inputIndex(_ tokens: Int64) -> Int {
        index(for: Double(tokens) / 1_000_000, thresholds: inputMillionsThresholds)
    }

    nonisolated static func outputIndex(_ tokens: Int64) -> Int {
        index(for: Double(tokens) / 1_000, thresholds: outputThousandsThresholds)
    }

    static func turnsColor(_ turns: Int) -> NSColor { stops[turnsIndex(turns)] }
    static func inputColor(_ tokens: Int64) -> NSColor { stops[inputIndex(tokens)] }
    static func outputColor(_ tokens: Int64) -> NSColor { stops[outputIndex(tokens)] }
}

// MARK: - Status badge

/// The small pill beside a provider name in the quota section. Carries text
/// and intent only — no NSColor — so `Card` stays a plain value type that can
/// cross actor boundaries with the rest of the provider payload.
struct Badge: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case amber, gray }
    var text: String
    var kind: Kind

    var textColor: NSColor {
        switch kind {
        case .amber: return Palette.dynamicHex(dark: 0xE6B566, light: 0x8F6318)
        case .gray: return .secondaryLabelColor
        }
    }

    var fillColor: NSColor {
        switch kind {
        case .amber: return Palette.dynamicHex(dark: 0xE6B566, light: 0x8F6318).withAlphaComponent(0.16)
        case .gray: return Palette.dynamicHex(dark: 0x8A8C93, light: 0x6B6D73).withAlphaComponent(0.16)
        }
    }
}

// MARK: - Fonts
//
// System font throughout, with monospaced *digits* on every numeric cell so a
// column of numbers doesn't shimmy as values change width. The old
// full-monospace panel is gone; only the digits needed fixing.
enum PanelFont {
    static func text(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func number(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

// MARK: - Display formatting
//
// Detailed-mode string composition. Deliberately separate from
// `UsageMenuBar.sessionMultiple` / `sessionGauge`, which Compact mode and the
// `--once` printer still use verbatim and which this redesign leaves alone.
enum Display {
    /// "5.6×" — the multiple over the session's starting context. `nil` reads
    /// as "—", never a fabricated 1.0×, matching Sessions.swift's contract.
    nonisolated static func multiple(_ value: Double?) -> String {
        value.map { String(format: "%.1f×", $0) } ?? "—"
    }

    /// "78.5M / 244k". The two halves are graded independently at draw time;
    /// this is the plain-text form used by tooltips and self-tests.
    nonisolated static func inOut(input: Int64, output: Int64) -> String {
        "\(Format.tokens(input)) / \(Format.tokens(output))"
    }

    static let inOutSeparator = " / "

    /// Trims a model id down to what actually distinguishes it in a 10pt cell:
    /// "claude-opus-5" -> "opus-5", "gpt-5.2-codex" unchanged. Drops a vendor
    /// prefix path, a leading "claude-", and a trailing -YYYYMMDD build stamp.
    nonisolated static func shortModel(_ raw: String) -> String {
        var name = raw
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        for prefix in ["claude-", "anthropic."] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        if let stamp = name.range(of: "-[0-9]{8}$", options: .regularExpression) {
            name.removeSubrange(stamp)
        }
        return name.isEmpty ? raw : name
    }
}

// MARK: - Drawing primitives
//
// Every colour reaching these helpers is a dynamic NSColor resolved by AppKit
// at the moment of the fill, so light/dark and contrast changes need no
// plumbing beyond a redraw.
enum Draw {
    /// Vertically centres a single line in `rect` and clips it to that column,
    /// tail-truncating rather than spilling into the neighbouring cell.
    static func text(_ string: String, font: NSFont, color: NSColor,
                     in rect: NSRect, alignment: NSTextAlignment = .left) {
        guard !string.isEmpty, rect.width > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        let height = attributed.size().height
        let box = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        attributed.draw(with: box, options: [.usesLineFragmentOrigin])
    }

    /// Draws pre-composed runs as one line, so a row can mix colours inside a
    /// single cell without hand-computing each run's x offset.
    static func runs(_ runs: [(String, NSFont, NSColor)], in rect: NSRect, alignment: NSTextAlignment = .left) {
        guard rect.width > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let line = NSMutableAttributedString()
        for run in runs {
            line.append(NSAttributedString(string: run.0, attributes: [
                .font: run.1, .foregroundColor: run.2, .paragraphStyle: paragraph,
            ]))
        }
        let height = line.size().height
        let box = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        line.draw(with: box, options: [.usesLineFragmentOrigin])
    }

    /// A rounded track with a severity-coloured fill. `opacity` below 1 marks
    /// data that is not live — Codex quota is only as fresh as the last turn
    /// it was recorded on, and the bar says so without a second label.
    static func track(in rect: NSRect, fraction: Double, fill: NSColor, opacity: CGFloat = 1) {
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = rect.height / 2

        // The clip must be saved and restored around this call. Without it the
        // rounded track becomes the clip region for every later draw in the
        // same pass — the percentage and reset columns to the right of this
        // bar would simply vanish.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).setClip()

        Palette.track.setFill()
        rect.fill()

        let clamped = max(0, min(1, fraction))
        guard clamped > 0 else { return }
        // Never let a non-zero value round down to an invisible sliver — a
        // 1% bar has to read as "some", not as the empty track of a 0%.
        let width = min(rect.width, max(rect.height, rect.width * CGFloat(clamped)))
        fill.withAlphaComponent(opacity).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height).fill()
    }

    /// The provider dot: filled for "on", stroke-only for "off".
    static func dot(centeredIn rect: NSRect, diameter: CGFloat, color: NSColor, filled: Bool) {
        let box = NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                         width: diameter, height: diameter)
        let path = NSBezierPath(ovalIn: filled ? box : box.insetBy(dx: 0.5, dy: 0.5))
        if filled {
            color.setFill()
            path.fill()
        } else {
            color.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    static func badge(_ badge: Badge, at origin: NSPoint, font: NSFont) -> NSRect {
        let size = (badge.text as NSString).size(withAttributes: [.font: font])
        let box = NSRect(x: origin.x, y: origin.y, width: size.width + 12, height: 15)
        badge.fillColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: 7.5, yRadius: 7.5).fill()
        text(badge.text, font: font, color: badge.textColor, in: box, alignment: .center)
        return box
    }

    /// The hairline between two quota blocks — inset on both sides so it reads
    /// as an intra-section rule rather than a full section break.
    static func divider(in bounds: NSRect, inset: CGFloat) {
        NSColor.separatorColor.setFill()
        NSRect(x: inset, y: bounds.midY - 0.5, width: max(0, bounds.width - inset * 2), height: 1).fill()
    }
}

// MARK: - Self-tests
//
// Pure composition and threshold logic only — drawing stays untested, the
// same rule the Detailed row self-tests already follow.
enum ThemeSelfTests {
    static func run() {
        testGradeThresholds()
        testDisplayComposition()
    }

    private static func testGradeThresholds() {
        // Turns: 80 / 180 / 300, each boundary landing on the *upper* stop.
        precondition(Grade.turnsIndex(0) == 0)
        precondition(Grade.turnsIndex(79) == 0)
        precondition(Grade.turnsIndex(80) == 1)
        precondition(Grade.turnsIndex(179) == 1)
        precondition(Grade.turnsIndex(180) == 2)
        precondition(Grade.turnsIndex(299) == 2)
        precondition(Grade.turnsIndex(300) == 3)
        precondition(Grade.turnsIndex(100_000) == 3, "the ramp must clamp, never index past its last stop")

        // Input graded in millions.
        precondition(Grade.inputIndex(9_999_999) == 0)
        precondition(Grade.inputIndex(10_000_000) == 1)
        precondition(Grade.inputIndex(40_000_000) == 2)
        precondition(Grade.inputIndex(70_000_000) == 3)

        // Output graded in thousands.
        precondition(Grade.outputIndex(59_999) == 0)
        precondition(Grade.outputIndex(60_000) == 1)
        precondition(Grade.outputIndex(140_000) == 2)
        precondition(Grade.outputIndex(220_000) == 3)

        precondition(Grade.stops.count == 4)
        precondition(Grade.turnsThresholds.count == Grade.stops.count - 1)
    }

    private static func testDisplayComposition() {
        // The multiple uses the × glyph, and nil is still never a fabricated 1.0.
        precondition(Display.multiple(5.6) == "5.6×")
        precondition(Display.multiple(nil) == "—")
        precondition(!Display.multiple(3.2).contains("x"), "the ASCII x must not survive the redesign")

        precondition(Display.inOut(input: 78_500_000, output: 244_000) == "78.5M / 244k")

        precondition(Display.shortModel("claude-opus-5") == "opus-5")
        precondition(Display.shortModel("gpt-5.2-codex") == "gpt-5.2-codex")
        precondition(Display.shortModel("claude-sonnet-5-20260115") == "sonnet-5")
        precondition(Display.shortModel("anthropic/claude-opus-5") == "opus-5")
        precondition(Display.shortModel("opus-5") == "opus-5")

        // Identity, never severity: the accent depends only on which provider.
        precondition(ProviderAccent.forProvider("Claude") == .claude)
        precondition(ProviderAccent.forProvider("Codex") == .codex)
        precondition(ProviderAccent.forProvider("OpenRouter") == .neutral)
        precondition(ProviderAccent.forProvider("Grok (xAI)") == .neutral)
        precondition(ProviderAccent.forProvider("Antigravity") == .neutral)
        precondition(ProviderAccent.forSession(.claude) == .claude)
        precondition(ProviderAccent.forSession(.codex) == .codex)
    }
}
