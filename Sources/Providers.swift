import Foundation

// MARK: - Shared display model

/// One line in the dropdown. `percent` drives a bar; `detail` carries anything
/// that is not a percentage (a dollar balance, a plan name, a reset time).
struct Row {
    var label: String
    var percent: Int?
    var detail: String
    var severity: String = "normal"
}

/// A provider's section in the menu: a title plus its rows, or an error.
///
/// `badge` is the small pill drawn beside the provider name. It is set
/// structurally at the point the condition is known — staleness in
/// `UsageMenuBar.merge`, snapshot age in `CodexProvider.card` — rather than
/// recovered later by pattern-matching `note`, which the renderer would
/// otherwise have to parse back out of a human-readable sentence.
struct Card {
    var provider: String
    var rows: [Row]
    var note: String?
    var error: String?
    var badge: Badge?
    /// Distinguishes "you have not set this provider up yet" from "the fetch
    /// failed", which read identically as an error string but call for
    /// completely different rows — a setup hint versus a diagnostic.
    var missingKey: Bool = false
    /// Set on an HTTP 429. Drives the poll backoff, so it has to survive as a
    /// flag rather than as prose in `error` — `merge` replaces a failed card
    /// with the previous good rows, and the reason for the failure would be
    /// lost with it exactly when the scheduler needs to know.
    var rateLimited: Bool = false
}

struct HeadlineValue {
    let percent: Int
    let severity: String
}

protocol Provider: Sendable {
    var name: String { get }
    func load() async -> Card
}

// MARK: - Config

/// Keys resolve highest-precedence-wins across three tiers:
///   1. The OPENROUTER_API_KEY env var (unchanged — keeps CI/scripting
///      workflows working).
///   2. The macOS Keychain (KeyStore.swift): service
///      "local.claude-usage-menubar", account "openrouter_key" — what the
///      settings window's Save button writes.
///   3. Legacy ~/.config/claude-usage/config.json — read-only, never
///      deleted automatically, kept alive forever for anyone who never
///      opens settings:
///        { "openrouter_key": "sk-or-v1-…" }
/// Providers.all() calls Config.load() on every refresh, so a key saved in
/// settings (or removed) takes effect on the next poll with no restart —
/// the same property the legacy env-var/file design already had.
struct Config: Sendable {
    var openRouterKey: String?

    /// var, not let: --self-test points this at a temp-dir fixture instead
    /// of the real file, mirroring the Prefs.defaults swap pattern.
    static var legacyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/claude-usage/config.json")

    /// The polling path reads straight through to the Keychain on every
    /// refresh. There is no cache and no timeout wrapper in front of it any
    /// more: those existed to survive an approval dialog that this app's own
    /// items no longer raise (see KeychainStore), and a cache that outlives
    /// the dialog it was built for is just a way to serve a stale key after
    /// the user changes one.
    static let pollingStore: KeyStore = KeychainStore()

    static func load(store: KeyStore = Config.pollingStore) -> Config {
        let env = ProcessInfo.processInfo.environment

        var config = Config()
        config.openRouterKey = nonBlank(env["OPENROUTER_API_KEY"]) ?? store.get(KeyAccount.openRouter) ?? legacyOpenRouterKey()
        return config
    }

    /// L15: `OPENROUTER_API_KEY=` (set but empty, or whitespace-only) must
    /// not win tier 1 over a perfectly good Keychain key — without this,
    /// `env["…"] ?? …` treats `""` as present and the provider reports "no
    /// API key" while a valid Keychain entry sits unused underneath it.
    static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// Exposed separately (not folded into load()) so SettingsWindow's
    /// migration banner can ask "does the legacy file hold a key?" without
    /// touching the Keychain or env vars at all.
    static func legacyOpenRouterKey() -> String? {
        guard let data = try? Data(contentsOf: legacyPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["openrouter_key"] as? String
    }
}

/// One bounded `Process` run, shared by every subprocess this app shells out
/// to.
///
/// Extracted from KeychainCLI, which carried two copies of this body.
/// AntigravityProvider's `lsof` call is the third caller, and a third
/// hand-written copy of a subprocess timeout is how timeouts drift apart.
enum BoundedProcess {
    /// `failed` carries the child's exit status so callers can tell the
    /// routine outcomes apart from the real ones — security(1)'s 44 is "no
    /// such item", which for a key that was never configured is not an error
    /// at all.
    enum Failure: Error { case blocked, failed(Int32) }

    static func run(executable: String, arguments: [String],
                    stdin: String? = nil,
                    timeout: TimeInterval) -> Result<Data, Failure> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        let input = stdin != nil ? Pipe() : nil
        if let input { task.standardInput = input }

        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        guard (try? task.run()) != nil else { return .failure(.failed(-1)) }

        if let input, let stdin {
            // At most a few hundred bytes, so this write cannot fill the pipe
            // and block; closing afterwards is what makes the child see EOF
            // and act on the one command it was given.
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // Leaves any approval dialog up — answering it makes the next call
            // succeed. Only this run is abandoned, not the user's decision.
            task.terminate()
            return .failure(.blocked)
        }
        // Safe to read after exit only because these payloads are a few KB;
        // a larger one could fill the pipe buffer and stall the child, which
        // the timeout above would then catch as .blocked rather than hang.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return task.terminationStatus == 0 ? .success(data) : .failure(.failed(task.terminationStatus))
    }
}

/// Bounded wrapper around `security(1)`.
///
/// A Keychain read can block indefinitely: if macOS decides the caller needs
/// approval it puts a dialog on screen and `security` waits for it — forever,
/// if nobody clicks it. Unbounded, one such dialog blanked the entire usage
/// section, because `loadAll` awaits every provider and one that never returns
/// takes down the others with it, including those that touch no Keychain at
/// all.
///
/// This app's own key no longer triggers that dialog (see KeychainStore), but
/// the item it reads from *another* app — Claude Code's OAuth token — is
/// written under that app's own access rules, so the timeout stays. That
/// reasoning is specific to the Keychain and deliberately does not live on
/// BoundedProcess, which `lsof` also uses.
enum KeychainCLI {
    /// Long enough that a genuinely slow read succeeds, short enough that the
    /// menu is not held hostage to a dialog nobody is looking at.
    static let timeout: TimeInterval = 8

    typealias Failure = BoundedProcess.Failure

    static func read(_ arguments: [String], timeout: TimeInterval = timeout) -> Result<Data, Failure> {
        BoundedProcess.run(executable: "/usr/bin/security", arguments: arguments, timeout: timeout)
    }

    /// Same shape as read(), for the one call site (KeychainStore.set) that
    /// cannot use argv: `security -i` reads one command line off stdin
    /// instead, so a secret value never becomes a `ps`-visible argument.
    static func readStdin(_ commandLine: String, timeout: TimeInterval = timeout) -> Result<Data, Failure> {
        BoundedProcess.run(executable: "/usr/bin/security", arguments: ["-i"],
                           stdin: commandLine, timeout: timeout)
    }
}

enum Net {
    static func getJSON(_ url: URL, bearer: String,
                        extraHeaders: [String: String] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "http", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: http.statusCode == 401 ? "unauthorized (bad or expired key)"
                                                                  : "HTTP \(http.statusCode)",
            ])
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Cheap read of a file's tail — session logs run to tens of MB and we only
    /// ever need the most recent entries.
    static func tail(of url: URL, bytes: Int = 512 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Codex (OpenAI)

/// Codex has no pollable usage endpoint, but it records the server's
/// `rate_limits` payload into its session rollout logs on every turn. Reading
/// the newest entry is free, local, and costs no model call — at the price of
/// being only as fresh as your last Codex turn, which we label in the UI.
struct CodexProvider: Provider {
    let name = "Codex"

    static let headline = Headline()

    final class Headline: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: HeadlineValue?
        var value: HeadlineValue? {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    private var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    func load() async -> Card {
        guard let newest = newestSessions(limit: 6), !newest.isEmpty else {
            Self.headline.value = nil
            return Card(provider: name, rows: [], error: "no Codex sessions found")
        }

        for file in newest {
            guard let text = Net.tail(of: file) else { continue }
            for line in text.split(separator: "\n").reversed() {
                guard line.contains("\"rate_limits\"") ,
                      let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = json["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] as? [String: Any]
                else { continue }

                if let card = card(from: limits, timestamp: json["timestamp"] as? String) {
                    return card
                }
            }
        }
        Self.headline.value = nil
        return Card(provider: name, rows: [], error: "no rate-limit data in recent sessions")
    }

    static func extractWeeklyHeadline(from limits: [String: Any]) -> HeadlineValue? {
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  (window["window_minutes"] as? NSNumber)?.intValue == 10080,
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue
            else { continue }
            let percent = Int(used.rounded())
            let severity = percent >= 95 ? "critical" : (percent >= 80 ? "warning" : "normal")
            return HeadlineValue(percent: percent, severity: severity)
        }
        return nil
    }

    private func card(from limits: [String: Any], timestamp: String?) -> Card? {
        var rows: [Row] = []

        Self.headline.value = Self.extractWeeklyHeadline(from: limits)

        for (key, label) in [("primary", "Primary"), ("secondary", "Secondary")] {
            guard let window = limits[key] as? [String: Any],
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
            let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let percent = Int(used.rounded())
            rows.append(Row(
                label: windowName(minutes: minutes, fallback: label),
                percent: percent,
                detail: "resets in \(Format.countdown(to: resets))",
                severity: percent >= 95 ? "critical" : (percent >= 80 ? "warning" : "normal")
            ))
        }

        if let credits = limits["credits"] as? [String: Any] {
            if credits["unlimited"] as? Bool == true {
                rows.append(Row(label: "Credits", detail: "unlimited"))
            } else if let balance = credits["balance"] as? String, balance != "0" {
                rows.append(Row(label: "Credits", detail: balance))
            }
        }

        guard !rows.isEmpty else { return nil }

        // Snapshot age and plan are two different things and now render in two
        // different places — the age as the header badge, since "how old is
        // this reading" qualifies every row in the block, and the plan as the
        // block's own note. They used to be joined into one note string.
        let note = (limits["plan_type"] as? String).map { "plan: \($0)" }
        var badge: Badge?
        if let timestamp, let date = Format.iso.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) {
            badge = Badge(text: "as of \(Format.ago(date))", kind: .gray)
        }
        return Card(provider: name, rows: rows, note: note, badge: badge)
    }

    /// 10080 minutes is the weekly window, 300 the 5-hour one.
    private func windowName(minutes: Int, fallback: String) -> String {
        switch minutes {
        case 0: return fallback
        case ..<60: return "\(minutes)m"
        case ..<1440: return "\(minutes / 60)-hour"
        case 10080: return "Weekly"
        default: return "\(minutes / 1440)-day"
        }
    }

    private func newestSessions(limit: Int) -> [URL]? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: sessionsDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            files.append((url, date))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

// MARK: - OpenRouter

/// GET /api/v1/credits → { data: { total_credits, total_usage } } (USD).
struct OpenRouterProvider: Provider {
    let name = "OpenRouter"
    let key: String?

    /// Turns a /v1/credits response into the "valid — $X.XX remaining"
    /// message SettingsWindow's Test button shows — the same arithmetic
    /// load() uses for its Row, pulled out so both call sites (and
    /// --self-test) share one source of truth instead of two copies drifting.
    static func creditsMessage(from json: [String: Any]) -> String {
        let data = json["data"] as? [String: Any] ?? [:]
        let granted = (data["total_credits"] as? NSNumber)?.doubleValue ?? 0
        let used = (data["total_usage"] as? NSNumber)?.doubleValue ?? 0
        return "valid — \(Format.usd(granted - used)) remaining"
    }

    func load() async -> Card {
        guard let key, !key.isEmpty else {
            return Card(provider: name, rows: [], error: "no API key — see README", missingKey: true)
        }
        do {
            let json = try await Net.getJSON(URL(string: "https://openrouter.ai/api/v1/credits")!, bearer: key)
            let data = json["data"] as? [String: Any] ?? [:]
            let granted = (data["total_credits"] as? NSNumber)?.doubleValue ?? 0
            let used = (data["total_usage"] as? NSNumber)?.doubleValue ?? 0
            let remaining = granted - used

            var rows = [Row(label: "Remaining", detail: Format.usd(remaining))]
            if granted > 0 {
                let percent = Int((used / granted * 100).rounded())
                rows.insert(Row(
                    label: "Used",
                    percent: percent,
                    detail: "\(Format.usd(used)) of \(Format.usd(granted))",
                    severity: percent >= 95 ? "critical" : (percent >= 80 ? "warning" : "normal")
                ), at: 0)
            } else {
                rows.append(Row(label: "Spent", detail: Format.usd(used)))
            }
            return Card(provider: name, rows: rows)
        } catch {
            return Card(provider: name, rows: [], error: error.localizedDescription)
        }
    }
}

// MARK: - Antigravity (agy)

/// Antigravity's quota lives behind `RetrieveUserQuotaSummary`, served by the
/// `agy` CLI's own loopback Connect server with no authentication.
///
/// This provider shipped once before and was removed in #33, because the RPC
/// available then (`v1internal:retrieveUserQuota`) returned raw per-modelId
/// buckets covering only some of the models Antigravity serves — so the card
/// could read 0% while you were throttled on a model it never mentioned.
/// `RetrieveUserQuotaSummary` returns two named groups spanning the whole
/// product, which is what makes the card honest enough to ship again.
///
/// The *remote* form of this RPC (cloudcode-pa v1internal) returns 403
/// SUBSCRIPTION_REQUIRED for consumer accounts on both the prod and daily
/// hosts. See docs/superpowers/specs/2026-08-27-… before trying it again:
/// re-test against a live token rather than re-arguing from documentation.
///
/// `remainingFraction` is what is LEFT (1.0 = untouched), so used = 1 - it.
struct AntigravityProvider: Provider {
    let name = "Antigravity"

    struct Bucket {
        let id: String
        let label: String
        let percent: Int
        let resetTime: Date?
    }

    /// "Gemini Models" + "weekly" -> "Gemini · Weekly".
    ///
    /// The group name is the server's own marketing string. Trimming
    /// " Models" and folding " and " to "/" is what keeps four rows inside
    /// the dropdown's width without a hand-maintained translation table that
    /// a newly-added group would silently fall out of.
    static func label(group: String, window: String, fallback: String) -> String {
        var name = group
        for suffix in [" Models", " models"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        name = name.replacingOccurrences(of: " and ", with: "/")

        let windowName: String
        switch window {
        case "weekly": windowName = "Weekly"
        case "5h": windowName = "5-hour"
        default: windowName = fallback
        }
        return "\(name) · \(windowName)"
    }

    /// Accepts either the Connect envelope (`{"response": {...}}`) or a bare
    /// body, so a future server that drops the wrapper does not silently
    /// yield zero buckets.
    static func buckets(from json: [String: Any]) -> [Bucket] {
        let response = json["response"] as? [String: Any] ?? json
        var result: [Bucket] = []
        for case let group as [String: Any] in response["groups"] as? [Any] ?? [] {
            let groupName = group["displayName"] as? String ?? "Antigravity"
            for case let bucket as [String: Any] in group["buckets"] as? [Any] ?? [] {
                guard let id = bucket["bucketId"] as? String,
                      let remaining = (bucket["remainingFraction"] as? NSNumber)?.doubleValue
                else { continue }
                let resetTime = (bucket["resetTime"] as? String).flatMap {
                    Format.iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
                }
                result.append(Bucket(
                    id: id,
                    label: label(group: groupName,
                                 window: bucket["window"] as? String ?? "",
                                 fallback: bucket["displayName"] as? String ?? "Limit"),
                    percent: Int(((1 - remaining) * 100).rounded()),
                    resetTime: resetTime
                ))
            }
        }
        return result
    }

    static func severity(forPercent percent: Int) -> String {
        percent >= 95 ? "critical" : (percent >= 80 ? "warning" : "normal")
    }

    static func rows(from buckets: [Bucket]) -> [Row] {
        buckets.map { bucket in
            Row(label: bucket.label, percent: bucket.percent,
                detail: "resets in \(Format.countdown(to: bucket.resetTime))",
                severity: severity(forPercent: bucket.percent))
        }
    }

    func load() async -> Card {
        Card(provider: name, rows: [], error: "not implemented")
    }
}
