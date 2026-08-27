import Foundation

// MARK: - Provider identity

/// Stable identifiers for the fixed provider registry (`Providers.all`).
/// `displayName` matches each Provider's `name` string exactly — this is the
/// one place that mapping lives, so the registry filter in Providers.all()
/// never risks drifting from what's on screen.
enum ProviderID: String, CaseIterable {
    case claude, codex, openrouter, antigravity

    /// A provider is title-capable if it owns at least one TitleMetric. This
    /// replaced a hardcoded `self == .claude || self == .codex`: with seven
    /// tickable numbers across four providers, the registry is the only
    /// honest source for the question, and OpenRouter needs no special case —
    /// it simply owns none.
    var ownsTitleMetrics: Bool { TitleMetric.all.contains { $0.provider == self } }

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

// MARK: - Menu bar title metrics

/// One tickable number in the menu bar title.
///
/// The title used to be two hardcoded providers with a boolean each. It is a
/// registry because Antigravity alone contributes four numbers across two
/// unrelated quota groups (Gemini, and Claude/GPT), and no single one of them
/// is a fair headline for the others — so the choice of which to show has to
/// belong to the user rather than to this code.
struct TitleMetric: Hashable {
    let id: String
    let provider: ProviderID
    /// Shown in Settings, where there is room to be unambiguous.
    let label: String
    /// Shown in the menu bar itself, where every character costs width.
    /// These are exactly the strings the old hardcoded renderTitle()
    /// appended, so a default install's title is unchanged by this refactor.
    let shortLabel: String
    /// Antigravity's four are false: upgrading must not silently widen
    /// someone's menu bar.
    let defaultOn: Bool

    /// Registry order is title order. Antigravity's ids are the server's own
    /// bucketIds, so an unrecognised bucket from a future release renders in
    /// the dropdown and is simply absent from this list rather than showing
    /// up as an unlabelled checkbox.
    static let all: [TitleMetric] = [
        TitleMetric(id: "claude.session", provider: .claude,
                    label: "5-hour", shortLabel: "5h", defaultOn: true),
        TitleMetric(id: "claude.weekly", provider: .claude,
                    label: "Weekly", shortLabel: "wk", defaultOn: true),
        TitleMetric(id: "codex.weekly", provider: .codex,
                    label: "Weekly", shortLabel: "wk", defaultOn: true),
        TitleMetric(id: "antigravity.gemini-weekly", provider: .antigravity,
                    label: "Gemini · Weekly", shortLabel: "gem wk", defaultOn: false),
        TitleMetric(id: "antigravity.gemini-5h", provider: .antigravity,
                    label: "Gemini · 5-hour", shortLabel: "gem 5h", defaultOn: false),
        TitleMetric(id: "antigravity.3p-weekly", provider: .antigravity,
                    label: "Claude/GPT · Weekly", shortLabel: "3p wk", defaultOn: false),
        TitleMetric(id: "antigravity.3p-5h", provider: .antigravity,
                    label: "Claude/GPT · 5-hour", shortLabel: "3p 5h", defaultOn: false),
    ]

    static func metric(id: String) -> TitleMetric? { all.first { $0.id == id } }
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

    /// The bundle id this app shipped under until the ControlCenter allow-list
    /// forced a new one. UserDefaults.standard follows the bundle id, so
    /// without the migration below every setting would silently reset.
    static let legacyDomain = "local.claude-usage-menubar"

    /// Swapped by --self-test so the migration can be exercised against a
    /// scratch domain instead of the user's real pre-rename settings.
    static var legacyDomainNameForTesting = legacyDomain

    /// Fired by every setter below. main.swift wires this once, at launch,
    /// to reschedule the refresh timer and re-render (main.swift:187-194)
    /// whenever a checkbox or the interval popup changes.
    static var onChange: (() -> Void)?

    static let refreshIntervalRange: ClosedRange<TimeInterval> = 60...900
    static let defaultRefreshInterval: TimeInterval = 120

    static func showInDropdown(_ id: ProviderID) -> Bool { flag("dropdown.\(id.rawValue)") }
    static func setShowInDropdown(_ id: ProviderID, _ value: Bool) { setFlag("dropdown.\(id.rawValue)", value) }

    /// Unlike every other flag here, an unset key reads the metric's OWN
    /// default rather than a blanket true — "show everything" would put four
    /// new Antigravity numbers into the menu bar of everyone who upgrades.
    static func showMetricInTitle(_ metric: TitleMetric) -> Bool {
        let key = "title.metric.\(metric.id)"
        return defaults.object(forKey: key) == nil ? metric.defaultOn : defaults.bool(forKey: key)
    }

    static func setShowMetricInTitle(_ metric: TitleMetric, _ value: Bool) {
        setFlag("title.metric.\(metric.id)", value)
    }

    /// Copies settings across from the pre-rename bundle id, once.
    ///
    /// Changing CFBundleIdentifier moves UserDefaults.standard to a brand new
    /// domain, so an upgrade would otherwise look like a factory reset:
    /// hidden providers reappear, the refresh interval resets, and the
    /// Antigravity cache is lost. Only keys this app owns are copied — a
    /// blanket copy would drag in the global domain.
    static func migrateLegacyDomainIfNeeded() {
        guard defaults.object(forKey: "prefs.domainMigrated") == nil else { return }
        defer { defaults.set(true, forKey: "prefs.domainMigrated") }

        guard let legacy = defaults.persistentDomain(forName: legacyDomainNameForTesting) else { return }
        let owned = ["dropdown.", "title.", "sessions.", "refreshInterval", "antigravity."]
        for (key, value) in legacy
        where owned.contains(where: { key.hasPrefix($0) }) && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// Carries the old per-provider `title.<id>` booleans forward, once.
    ///
    /// Without this, anyone who had hidden Claude or Codex from the bar gets
    /// it back on upgrade — the one visible regression this refactor could
    /// cause. Guarded by its own marker rather than by "are any metric keys
    /// set", so a later manual change is never mistaken for an unmigrated
    /// install and overwritten.
    static func migrateTitleMetricsIfNeeded() {
        guard defaults.object(forKey: "title.metricsMigrated") == nil else { return }
        for metric in TitleMetric.all {
            let legacyKey = "title.\(metric.provider.rawValue)"
            guard defaults.object(forKey: legacyKey) != nil else { continue }
            defaults.set(defaults.bool(forKey: legacyKey), forKey: "title.metric.\(metric.id)")
        }
        defaults.set(true, forKey: "title.metricsMigrated")
    }

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
