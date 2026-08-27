import Foundation

// MARK: - Provider identity

/// Stable identifiers for the fixed provider registry (`Providers.all`).
/// `displayName` matches each Provider's `name` string exactly — this is the
/// one place that mapping lives, so the registry filter in Providers.all()
/// never risks drifting from what's on screen.
enum ProviderID: String, CaseIterable {
    case claude, codex, openrouter, antigravity

    /// Only Claude and Codex publish a headline value (main.swift:103,
    /// Providers.swift:103) — OpenRouter has nothing to put in the title, so
    /// its "Menu bar" checkbox doesn't exist rather than being
    /// disabled-but-visible.
    var supportsTitle: Bool { self == .claude || self == .codex }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .openrouter: return "OpenRouter"
        case .antigravity: return "Antigravity"
        }
    }

    init?(displayName: String) {
        guard let match = Self.allCases.first(where: { $0.displayName == displayName }) else { return nil }
        self = match
    }
}

// MARK: - Sessions row style

/// Two shipped values, per the plan's "both options ship visible now, the
/// pref plumbing is exercised once" decision. The stored default is
/// deliberately Detailed — see `Prefs.rendersCompact(_:)` for how the two
/// styles now map onto real, independent renderers (Phase 4c).
enum SessionRowStyle: String {
    case compact, detailed
}

// MARK: - Preferences

/// Non-secret prefs, namespaced over UserDefaults. `defaults` is swappable so
/// --self-test can point it at an isolated suite instead of the user's real
/// UserDefaults.standard — see the self-test setup in main.swift, which
/// saves/restores this and removes its scratch suite afterward.
enum Prefs {
    static var defaults: UserDefaults = .standard

    /// Fired by every setter below. main.swift wires this once, at launch,
    /// to reschedule the refresh timer and re-render (main.swift:187-194)
    /// whenever a checkbox or the interval popup changes.
    static var onChange: (() -> Void)?

    static let refreshIntervalRange: ClosedRange<TimeInterval> = 60...900
    static let defaultRefreshInterval: TimeInterval = 120

    static func showInDropdown(_ id: ProviderID) -> Bool { flag("dropdown.\(id.rawValue)") }
    static func setShowInDropdown(_ id: ProviderID, _ value: Bool) { setFlag("dropdown.\(id.rawValue)", value) }

    static func showInTitle(_ id: ProviderID) -> Bool { flag("title.\(id.rawValue)") }
    static func setShowInTitle(_ id: ProviderID, _ value: Bool) { setFlag("title.\(id.rawValue)", value) }

    // Unset reads true, matching the provider-visibility flags above: "never
    // configured" means "show everything".
    static func showSessions() -> Bool { flag("sessions.enabled") }
    static func setShowSessions(_ value: Bool) { setFlag("sessions.enabled", value) }

    /// The stored default is Detailed *deliberately* (per the plan): a user
    /// who never opens Settings gets the rich rows automatically the moment
    /// Phase 4c ships a Detailed renderer, with no migration step needed.
    static func sessionRowStyle() -> SessionRowStyle {
        guard let raw = defaults.string(forKey: "sessions.rowStyle"), let style = SessionRowStyle(rawValue: raw) else {
            return .detailed
        }
        return style
    }

    static func setSessionRowStyle(_ value: SessionRowStyle) {
        defaults.set(value.rawValue, forKey: "sessions.rowStyle")
        onChange?()
    }

    /// Phase 4c ships a real Detailed renderer (Sources/SessionRowView.swift),
    /// so Detailed no longer falls back to Compact — this is the one place
    /// that fallback used to live, flipped here rather than adding a second
    /// fallback path anywhere else (per the Phase 4b comment that predicted
    /// exactly this change).
    nonisolated static func rendersCompact(_ style: SessionRowStyle) -> Bool {
        switch style {
        case .compact: return true
        case .detailed: return false
        }
    }

    static func refreshInterval() -> TimeInterval {
        let stored = defaults.object(forKey: "refreshInterval") as? Double ?? defaultRefreshInterval
        return clampRefreshInterval(stored)
    }

    static func setRefreshInterval(_ value: TimeInterval) {
        defaults.set(clampRefreshInterval(value), forKey: "refreshInterval")
        onChange?()
    }

    /// Applies on read as well as write — a hand-edited plist (or a stray
    /// value from an older build) must not produce a 5-second poll against
    /// an API that rate-limits aggressively.
    nonisolated static func clampRefreshInterval(_ value: TimeInterval) -> TimeInterval {
        min(max(value, refreshIntervalRange.lowerBound), refreshIntervalRange.upperBound)
    }

    // Absent key reads true: "never configured" means "show everything",
    // not "hidden". Explicit object(forKey:) check rather than
    // UserDefaults.register(defaults:) because keys are built per
    // ProviderID.rawValue and this avoids maintaining a parallel
    // registration dictionary in step with ProviderID.allCases.
    private static func flag(_ key: String) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    private static func setFlag(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}
