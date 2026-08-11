import Foundation

// MARK: - Provider identity

/// Stable identifiers for the fixed provider registry (main.swift:367-377).
/// `displayName` matches each Provider's `name` string exactly — this is the
/// one place that mapping lives, so the registry filter in Providers.all()
/// never risks drifting from what's on screen.
enum ProviderID: String, CaseIterable {
    case claude, codex, antigravity, openrouter, grok

    /// Only Claude and Codex publish a headline value (main.swift:103,
    /// Providers.swift:103) — the other three have nothing to put in the
    /// title, so their "Menu bar" checkbox doesn't exist rather than being
    /// disabled-but-visible.
    var supportsTitle: Bool { self == .claude || self == .codex }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .openrouter: return "OpenRouter"
        case .grok: return "Grok (xAI)"
        }
    }

    init?(displayName: String) {
        guard let match = Self.allCases.first(where: { $0.displayName == displayName }) else { return nil }
        self = match
    }
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
