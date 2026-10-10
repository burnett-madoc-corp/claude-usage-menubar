import Foundation

// MARK: - Provider identity

/// Stable identifiers for the fixed provider registry (`Providers.all`).
/// `displayName` matches each Provider's `name` string exactly — this is the
/// one place that mapping lives, so the registry filter in Providers.all()
/// never risks drifting from what's on screen.
enum ProviderID: String, CaseIterable {
    case claude, codex, openrouter, antigravity

    /// A provider is title-capable if it owns at least one TitleMetric in the registry.
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

/// Configurable metric registry for the menu bar title.
struct TitleMetric: Hashable {
    let id: String
    let provider: ProviderID
    /// Shown in Settings, where there is room to be unambiguous.
    let label: String
    /// Shown in the menu bar title; Antigravity Gemini metrics omit family prefix.
    let shortLabel: String
    /// Default visibility in the menu bar title.
    let defaultOn: Bool

    /// Registry order determines display order in the title.
    static let all: [TitleMetric] = [
        TitleMetric(id: "claude.session", provider: .claude,
                    label: "5-hour", shortLabel: "5h", defaultOn: true),
        TitleMetric(id: "claude.weekly", provider: .claude,
                    label: "Weekly", shortLabel: "wk", defaultOn: true),
        TitleMetric(id: "codex.weekly", provider: .codex,
                    label: "Weekly", shortLabel: "wk", defaultOn: true),
        TitleMetric(id: "openrouter.credit", provider: .openrouter,
                    label: "Credit remaining", shortLabel: "cr", defaultOn: false),
        TitleMetric(id: "antigravity.gemini-5h", provider: .antigravity,
                    label: "Gemini · 5-hour", shortLabel: "5h", defaultOn: false),
        TitleMetric(id: "antigravity.gemini-weekly", provider: .antigravity,
                    label: "Gemini · Weekly", shortLabel: "wk", defaultOn: false),
        TitleMetric(id: "antigravity.3p-5h", provider: .antigravity,
                    label: "Claude/GPT · 5-hour", shortLabel: "3p 5h", defaultOn: false),
        TitleMetric(id: "antigravity.3p-weekly", provider: .antigravity,
                    label: "Claude/GPT · Weekly", shortLabel: "3p wk", defaultOn: false),
    ]

    static func metric(id: String) -> TitleMetric? { all.first { $0.id == id } }
}

// MARK: - Sessions row style

/// Supported rendering styles for sessions rows.
enum SessionRowStyle: String {
    case compact, detailed
}

// MARK: - Preferences

/// Non-secret preferences stored in UserDefaults.
enum Prefs {
    static var defaults: UserDefaults = .standard

    /// Prior bundle identifier for migrating existing user defaults.
    static let legacyDomain = "local.claude-usage-menubar"

    /// Swapped by --self-test to isolate domain migration tests.
    static var legacyDomainNameForTesting = legacyDomain

    /// Invoked whenever any preference changes.
    static var onChange: (() -> Void)?

    static let refreshIntervalRange: ClosedRange<TimeInterval> = 60...900
    static let defaultRefreshInterval: TimeInterval = 120

    static func showInDropdown(_ id: ProviderID) -> Bool { flag("dropdown.\(id.rawValue)") }
    static func setShowInDropdown(_ id: ProviderID, _ value: Bool) { setFlag("dropdown.\(id.rawValue)", value) }

    /// Reads metric's defaultOn when unset instead of defaulting to true.
    static func showMetricInTitle(_ metric: TitleMetric) -> Bool {
        let key = "title.metric.\(metric.id)"
        return defaults.object(forKey: key) == nil ? metric.defaultOn : defaults.bool(forKey: key)
    }

    static func setShowMetricInTitle(_ metric: TitleMetric, _ value: Bool) {
        setFlag("title.metric.\(metric.id)", value)
    }

    /// Copies app-owned settings from the prior bundle identifier domain once.
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

    /// Migrates legacy per-provider title flags to title.metric keys once.
    static func migrateTitleMetricsIfNeeded() {
        guard defaults.object(forKey: "title.metricsMigrated") == nil else { return }
        for metric in TitleMetric.all {
            let legacyKey = "title.\(metric.provider.rawValue)"
            guard defaults.object(forKey: legacyKey) != nil else { continue }
            defaults.set(defaults.bool(forKey: legacyKey), forKey: "title.metric.\(metric.id)")
        }
        defaults.set(true, forKey: "title.metricsMigrated")
    }

    // Unset defaults to true ("show everything").
    static func showSessions() -> Bool { flag("sessions.enabled") }
    static func setShowSessions(_ value: Bool) { setFlag("sessions.enabled", value) }

    /// Returns stored row style, defaulting to .detailed.
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

    /// Returns whether the specified style renders using the compact layout.
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

    /// Clamps interval to safe bounds on read and write.
    nonisolated static func clampRefreshInterval(_ value: TimeInterval) -> TimeInterval {
        min(max(value, refreshIntervalRange.lowerBound), refreshIntervalRange.upperBound)
    }

    // Absent key defaults to true to show all items before explicit configuration.
    private static func flag(_ key: String) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    private static func setFlag(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}
