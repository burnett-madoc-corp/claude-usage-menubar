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
    /// Always drives the colour, even when it is not what gets drawn.
    let percent: Int
    let severity: String
    /// Drawn instead of "\(percent)%" when the number this metric is about
    /// is not a percentage. OpenRouter's headline is a credit balance in
    /// dollars; it still has a meaningful percent (spend against the amount
    /// granted) to colour by, but "$8.42" is what belongs in the bar.
    let display: String?

    init(percent: Int, severity: String, display: String? = nil) {
        self.percent = percent
        self.severity = severity
        self.display = display
    }

    /// The one place the drawn title and the plain-text title agree on how a
    /// value reads.
    var text: String { display ?? "\(percent)%" }
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

/// URLSession that accepts a self-signed certificate from 127.0.0.1, and from
/// nowhere else.
///
/// agy's TLS port presents its own certificate. Trusting it is defensible
/// only because the connection cannot leave this machine, so the host check
/// below IS the security argument — it must not be widened to "any local
/// name" or dropped for convenience. No credential is ever sent to this
/// server; the RPC is unauthenticated.
final class LoopbackSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = LoopbackSession()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self,
                                          delegateQueue: nil)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
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

    private var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    func load() async -> Card {
        guard let newest = newestSessions(limit: 6), !newest.isEmpty else {
            TitleValues.clear(provider: .codex)
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
        TitleValues.clear(provider: .codex)
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

        TitleValues.set("codex.weekly", Self.extractWeeklyHeadline(from: limits))

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

/// `GET /api/v1/credits` exposes only LIFETIME totals to a regular key
/// (verified live: `/credits/history` 404s, `/activity` requires a
/// management key):
///
///   total_credits — every dollar ever granted; it GROWS on each top-up and
///                   is NOT the current balance
///   total_usage   — every dollar ever spent
///
/// `remaining` (grant − usage) is therefore always honest, but a "used" bar
/// computed from those two double-counts every earlier top-up the moment the
/// account is funded again. So top-ups are detected locally: the app persists
/// the last-seen lifetime grant (`OpenRouterLedger.lastTotalCredits`) and a
/// poll where it has grown IS the top-up — the delta becomes that top-up's
/// grant, and lifetime usage at that moment starts the cycle's spend counter.
/// Known cost of the method: spend between the last poll before a top-up and
/// the top-up itself is attributed to the old cycle (bounded by one refresh
/// interval).
struct OpenRouterLedger: Codable, Equatable {
    var lastTotalCredits: Double
    var topup: Cycle?

    struct Cycle: Codable, Equatable {
        var granted: Double
        var usageAtTopup: Double
        var topupAt: Date
        /// True when the cycle was seeded from the current balance rather
        /// than observed — an upgrading install has no history to say what
        /// usage was at its last real top-up, so "since install" is the
        /// honest label until the next real top-up lands.
        var seeded: Bool
    }
}

/// GET /api/v1/credits → { data: { total_credits, total_usage } } (USD).
struct OpenRouterProvider: Provider {
    let name = "OpenRouter"
    let key: String?

    static let ledgerKey = "openrouter.ledger"
    /// A grant moving by less than half a cent is float noise, not a top-up.
    static let topupEpsilon = 0.005

    /// Ledger persistence lives in the same defaults the Antigravity cache
    /// uses, so it survives restarts — the whole point: a top-up detected
    /// before a relaunch must still define the cycle after it.
    static func loadLedger() -> OpenRouterLedger? {
        guard let data = Prefs.defaults.data(forKey: ledgerKey) else { return nil }
        return try? JSONDecoder().decode(OpenRouterLedger.self, from: data)
    }

    static func saveLedger(_ ledger: OpenRouterLedger) {
        Prefs.defaults.set(try? JSONEncoder().encode(ledger), forKey: ledgerKey)
    }

    /// Pure ledger transition for one poll, self-testable without network.
    /// A grown grant is a top-up; a SHRUNK grant (adjustment/revocation)
    /// makes lifetime totals incomparable, so tracking restarts and the card
    /// falls back to lifetime display until the next top-up.
    static func update(ledger: OpenRouterLedger?, granted: Double, used: Double,
                       now: Date = Date()) -> OpenRouterLedger {
        var ledger = ledger ?? OpenRouterLedger(
            lastTotalCredits: granted,
            // Upgrade path: there is no history to say what usage was at the
            // install's last real top-up, so the current balance seeds the
            // cycle — spend from here on counts against it, not lifetime.
            topup: granted - used > 0
                ? .init(granted: granted - used, usageAtTopup: used, topupAt: now, seeded: true)
                : nil)
        if granted < ledger.lastTotalCredits - topupEpsilon {
            ledger = OpenRouterLedger(lastTotalCredits: granted, topup: nil)
        } else if granted > ledger.lastTotalCredits + topupEpsilon {
            ledger.topup = .init(granted: granted - ledger.lastTotalCredits,
                                 usageAtTopup: used, topupAt: now, seeded: false)
            ledger.lastTotalCredits = granted
        }
        return ledger
    }

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

    /// The bar shows what is left, in dollars, coloured by how much of the
    /// granted amount has gone. With nothing granted (a pure pay-as-you-go
    /// account) there is no denominator to be a percentage of, so the balance
    /// colours itself: overdrawn is critical, nearly empty is a warning.
    static func headline(granted: Double, used: Double) -> HeadlineValue {
        let remaining = granted - used
        let display = Format.usd(remaining)
        guard granted > 0 else {
            let severity = remaining <= 0 ? "critical" : (remaining < 5 ? "warning" : "normal")
            return HeadlineValue(percent: remaining <= 0 ? 100 : 0, severity: severity, display: display)
        }
        let percent = Int((used / granted * 100).rounded())
        let severity = percent >= 95 ? "critical" : (percent >= 80 ? "warning" : "normal")
        return HeadlineValue(percent: percent, severity: severity, display: display)
    }

    /// Menu-bar colour source, cycle-aware: with a known top-up cycle the
    /// percent is spend since the top-up against the top-up itself — the
    /// number a person actually funds against; without one it falls back to
    /// the lifetime ratio. The display is always the remaining balance.
    static func headline(ledger: OpenRouterLedger, granted: Double, used: Double) -> HeadlineValue {
        guard let cycle = ledger.topup, cycle.granted > 0 else {
            return headline(granted: granted, used: used)
        }
        let cycleUsed = max(0, used - cycle.usageAtTopup)
        let percent = min(100, Int((cycleUsed / cycle.granted * 100).rounded()))
        let severity = percent >= 95 ? "critical" : (percent >= 80 ? "warning" : "normal")
        return HeadlineValue(percent: percent, severity: severity,
                             display: Format.usd(granted - used))
    }

    func load() async -> Card {
        guard let key, !key.isEmpty else {
            TitleValues.clear(provider: .openrouter)
            return Card(provider: name, rows: [], error: "no API key — see README", missingKey: true)
        }
        do {
            let json = try await Net.getJSON(URL(string: "https://openrouter.ai/api/v1/credits")!, bearer: key)
            let data = json["data"] as? [String: Any] ?? [:]
            let granted = (data["total_credits"] as? NSNumber)?.doubleValue ?? 0
            let used = (data["total_usage"] as? NSNumber)?.doubleValue ?? 0
            let remaining = granted - used

            let ledger = Self.update(ledger: Self.loadLedger(), granted: granted, used: used)
            Self.saveLedger(ledger)
            let headline = Self.headline(ledger: ledger, granted: granted, used: used)
            TitleValues.set("openrouter.credit", headline)

            var rows = [Row(label: "Remaining", detail: Format.usd(remaining))]
            var badge: Badge?
            if let cycle = ledger.topup {
                let cycleUsed = max(0, used - cycle.usageAtTopup)
                rows.insert(Row(
                    label: "Top-up used",
                    percent: headline.percent,
                    detail: "\(Format.usd(cycleUsed)) of \(Format.usd(cycle.granted))",
                    severity: headline.severity
                ), at: 0)
                badge = Badge(text: cycle.seeded ? "tracking since install"
                                                 : "top-up \(Format.ago(cycle.topupAt))", kind: .gray)
            } else if granted > 0 {
                rows.insert(Row(
                    label: "Used",
                    percent: headline.percent,
                    detail: "\(Format.usd(used)) of \(Format.usd(granted))",
                    severity: headline.severity
                ), at: 0)
            } else {
                rows.append(Row(label: "Spent", detail: Format.usd(used)))
            }
            return Card(provider: name, rows: rows, badge: badge)
        } catch {
            // A failed fetch must not leave a stale balance in the bar: an
            // out-of-date dollar figure reads as current in a way an em-dash
            // does not.
            TitleValues.clear(provider: .openrouter)
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

    // MARK: Cache
    //
    // agy is a CLI, not a daemon, so its server is absent most of the time.
    // Without a cache this card would read "not running" almost always, which
    // is truthful but useless. With one, the weekly numbers — the ones you
    // actually plan around — stay on screen between agy sessions.
    //
    // The dropdown may replay the cache with its "as of" badge at any age,
    // but the title has no badge: a days-old 66% there reads as live, which
    // is exactly how a quota limit arrived unwarned. Older than
    // titleStalenessThreshold, the title is cleared to "—" instead.
    static let cacheKey = "antigravity.cache"
    static let titleStalenessThreshold: TimeInterval = 900

    static func encodeCache(buckets: [Bucket], fetchedAt: Date) -> [String: Any] {
        [
            "fetchedAt": Format.iso.string(from: fetchedAt),
            "buckets": buckets.map { bucket -> [String: Any] in
                var encoded: [String: Any] = ["id": bucket.id, "label": bucket.label,
                                              "percent": bucket.percent]
                if let resetTime = bucket.resetTime {
                    encoded["resetTime"] = Format.iso.string(from: resetTime)
                }
                return encoded
            },
        ]
    }

    /// Returns nil when the cache is absent, unreadable, or entirely past its
    /// reset times. All three mean "show no cached rows", so the caller gets
    /// one branch instead of three.
    static func decodeCache(_ raw: [String: Any], now: Date) -> (buckets: [Bucket], fetchedAt: Date)? {
        guard let stamp = raw["fetchedAt"] as? String,
              let fetchedAt = Format.iso.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        else { return nil }

        var buckets: [Bucket] = []
        for case let entry as [String: Any] in raw["buckets"] as? [Any] ?? [] {
            guard let id = entry["id"] as? String,
                  let label = entry["label"] as? String,
                  let percent = (entry["percent"] as? NSNumber)?.intValue
            else { continue }
            let resetTime = (entry["resetTime"] as? String).flatMap {
                Format.iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
            }
            // A bucket that never said when it resets is not immortal: it
            // falls back to a week from the fetch, the longest window
            // Antigravity actually uses. Keeping it forever would park a
            // stale percentage on screen with nothing to ever clear it.
            let expiresAt = resetTime ?? fetchedAt.addingTimeInterval(7 * 86400)
            if expiresAt <= now { continue }
            buckets.append(Bucket(id: id, label: label, percent: percent, resetTime: resetTime))
        }
        return buckets.isEmpty ? nil : (buckets, fetchedAt)
    }

    // MARK: Transport

    /// agy opens ephemeral ports per run and writes no port file — no
    /// lockfile carries one, and jetski_state.pbtxt does not either — so the
    /// only way to find its server is to ask the kernel who is listening.
    static func agyPorts(fromLsof output: String) -> [Int] {
        var ports: [Int] = []
        for line in output.split(separator: "\n") {
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("agy") else { continue }
            for field in line.split(separator: " ") where field.hasPrefix("127.0.0.1:") {
                let digits = field.dropFirst("127.0.0.1:".count).prefix { $0.isNumber }
                if let port = Int(digits), !ports.contains(port) { ports.append(port) }
            }
        }
        return ports
    }

    private static func listeningPorts() -> [Int] {
        guard case let .success(data) = BoundedProcess.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-c", "agy"],
            timeout: 5
        ) else { return [] }
        return agyPorts(fromLsof: String(decoding: data, as: UTF8.self))
    }

    private static let rpcPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    /// The IDE additionally requires an X-Codeium-Csrf-Token from its own
    /// state; the CLI's server does not, which is the only reason this
    /// provider can exist without shipping a token scraper.
    private static let rpcBody = Data(
        #"{"ideName":"antigravity","extensionName":"antigravity","locale":"en","ideVersion":"unknown"}"#.utf8)

    /// agy opens one plain-HTTP port and one TLS port, and which is which is
    /// not stable between runs, so both schemes are tried per port.
    private static func fetch(port: Int) async -> [String: Any]? {
        for scheme in ["http", "https"] {
            guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(rpcPath)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = rpcBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 5

            guard let (data, response) = try? await LoopbackSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return json
        }
        return nil
    }

    /// Only bucket ids that exist in the registry can reach the title; an
    /// unrecognised one from a future release still renders in the dropdown.
    private static func publishHeadlines(_ buckets: [Bucket]) {
        for bucket in buckets where TitleMetric.metric(id: "antigravity.\(bucket.id)") != nil {
            TitleValues.set("antigravity.\(bucket.id)",
                            HeadlineValue(percent: bucket.percent,
                                          severity: severity(forPercent: bucket.percent)))
        }
    }

    /// Replays the last reading (minus any bucket whose window has since
    /// reset) under the given error, the same contract CodexProvider's
    /// snapshot badge makes. Title values follow the cache: published while
    /// fresh enough to be honest, cleared once past the staleness threshold
    /// — and always cleared when there is no usable cache at all.
    private static func cachedCard(error: String, now: Date = Date()) -> Card {
        guard let raw = Prefs.defaults.dictionary(forKey: Self.cacheKey),
              let cached = Self.decodeCache(raw, now: now)
        else {
            TitleValues.clear(provider: .antigravity)
            return Card(provider: ProviderID.antigravity.displayName, rows: [], error: error)
        }
        // Publish from the cached path too: a cached number in the dropdown
        // and a blank one in the title would be incoherent — but only while
        // the cache is young. Past the threshold the title would state a
        // live-looking percentage it has no badge to qualify.
        if now.timeIntervalSince(cached.fetchedAt) > titleStalenessThreshold {
            TitleValues.clear(provider: .antigravity)
        } else {
            Self.publishHeadlines(cached.buckets)
        }
        return Card(provider: ProviderID.antigravity.displayName, rows: Self.rows(from: cached.buckets),
                    badge: Badge(text: "as of \(Format.ago(cached.fetchedAt))", kind: .gray))
    }

    func load() async -> Card {
        let ports = Self.listeningPorts()
        var rpcSucceeded = false
        for port in ports {
            guard let json = await Self.fetch(port: port) else { continue }
            rpcSucceeded = true
            let buckets = Self.buckets(from: json)
            guard !buckets.isEmpty else { continue }
            Prefs.defaults.set(Self.encodeCache(buckets: buckets, fetchedAt: Date()),
                               forKey: Self.cacheKey)
            Self.publishHeadlines(buckets)
            return Card(provider: name, rows: Self.rows(from: buckets))
        }

        // Three distinct realities, previously collapsed into one:
        // (a) agy is listening but every RPC failed — the process is alive,
        //     so "not running" would be a lie; say so and replay cache.
        if !ports.isEmpty && !rpcSucceeded {
            return Self.cachedCard(error: "agy running — quota fetch failed")
        }
        // (b) a live RPC answered but parsed to zero buckets — a server-side
        //     shape change must surface, not masquerade as days-old cache.
        if rpcSucceeded {
            TitleValues.clear(provider: .antigravity)
            return Card(provider: name, rows: [], error: "agy responded without quota data")
        }
        // (c) nothing is listening — the original "not running" + cache replay.
        return Self.cachedCard(error: "agy not running")
    }
}
