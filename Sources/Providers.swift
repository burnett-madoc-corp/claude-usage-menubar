import Foundation

// MARK: - Shared display model

/// One line in the dropdown; percent drives a progress bar, detail carries non-percentage text.
struct Row {
    var label: String
    var percent: Int?
    var detail: String
    var severity: String = "normal"
}

/// A provider's section in the menu: a title plus its rows, or an error.
struct Card {
    var provider: String
    var rows: [Row]
    var note: String?
    var error: String?
    var badge: Badge?
    /// Distinguishes unconfigured providers from runtime fetch failures.
    var missingKey: Bool = false
    /// Preserves 429 status across card merges to drive poll backoff.
    var rateLimited: Bool = false
}

struct HeadlineValue {
    /// Always drives color severity, even when custom display text is shown.
    let percent: Int
    let severity: String
    /// Custom text drawn instead of percent when the metric is not a percentage.
    let display: String?

    init(percent: Int, severity: String, display: String? = nil) {
        self.percent = percent
        self.severity = severity
        self.display = display
    }

    var text: String { display ?? "\(percent)%" }
}

protocol Provider: Sendable {
    var name: String { get }
    func load() async -> Card
}

// MARK: - Config

/// Resolves provider keys in precedence order: environment variables, Keychain, legacy config file.
struct Config: Sendable {
    var openRouterKey: String?

    /// Mutable to allow overriding with a fixture during self-tests.
    static var legacyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/claude-usage/config.json")

    /// Reads directly from the Keychain on each poll to avoid serving stale keys after updates.
    static let pollingStore: KeyStore = KeychainStore()

    static func load(store: KeyStore = Config.pollingStore) -> Config {
        let env = ProcessInfo.processInfo.environment

        var config = Config()
        config.openRouterKey = nonBlank(env["OPENROUTER_API_KEY"]) ?? store.get(KeyAccount.openRouter) ?? legacyOpenRouterKey()
        return config
    }

    /// Ignores empty or whitespace-only strings so empty environment variables do not mask lower-tier keys.
    static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// Reads the legacy JSON config without checking Keychain or environment variables.
    static func legacyOpenRouterKey() -> String? {
        guard let data = try? Data(contentsOf: legacyPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["openrouter_key"] as? String
    }
}

/// Subprocess runner with execution timeout.
enum BoundedProcess {
    /// Carries child exit status so callers can distinguish routine non-zero exits (e.g. item not found).
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
            // Writes fit within pipe buffer; closing signals EOF to the child process.
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // Terminates timed-out process without dismissing pending system dialogs.
            task.terminate()
            return .failure(.blocked)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return task.terminationStatus == 0 ? .success(data) : .failure(.failed(task.terminationStatus))
    }
}

/// Bounded security CLI wrapper with timeout to prevent Keychain prompt hangs from blocking refreshes.
enum KeychainCLI {
    static let timeout: TimeInterval = 8

    typealias Failure = BoundedProcess.Failure

    static func read(_ arguments: [String], timeout: TimeInterval = timeout) -> Result<Data, Failure> {
        BoundedProcess.run(executable: "/usr/bin/security", arguments: arguments, timeout: timeout)
    }

    /// Passes commands via stdin to prevent secrets from appearing in process argument lists.
    static func readStdin(_ commandLine: String, timeout: TimeInterval = timeout) -> Result<Data, Failure> {
        BoundedProcess.run(executable: "/usr/bin/security", arguments: ["-i"],
                           stdin: commandLine, timeout: timeout)
    }
}

/// Ephemeral URLSession trusting self-signed certificates strictly from 127.0.0.1 for local RPC.
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

        let note = (limits["plan_type"] as? String).map { "plan: \($0)" }
        var badge: Badge?
        if let timestamp, let date = Format.iso.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) {
            badge = Badge(text: "as of \(Format.ago(date))", kind: .gray)
        }
        return Card(provider: name, rows: rows, note: note, badge: badge)
    }

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

/// Tracks top-up cycles locally since the credits API only returns lifetime grant and spend totals.
struct OpenRouterLedger: Codable, Equatable {
    var lastTotalCredits: Double
    var topup: Cycle?

    struct Cycle: Codable, Equatable {
        var granted: Double
        var usageAtTopup: Double
        var topupAt: Date
        /// True when seeded from initial balance rather than an observed top-up transition.
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

    /// Loads persisted top-up cycle history across application restarts.
    static func loadLedger() -> OpenRouterLedger? {
        guard let data = Prefs.defaults.data(forKey: ledgerKey) else { return nil }
        return try? JSONDecoder().decode(OpenRouterLedger.self, from: data)
    }

    static func saveLedger(_ ledger: OpenRouterLedger) {
        Prefs.defaults.set(try? JSONEncoder().encode(ledger), forKey: ledgerKey)
    }

    /// Updates ledger on credit grant increases; resets cycle tracking if grant total shrinks.
    static func update(ledger: OpenRouterLedger?, granted: Double, used: Double,
                       now: Date = Date()) -> OpenRouterLedger {
        var ledger = ledger ?? OpenRouterLedger(
            lastTotalCredits: granted,
            // Seeds initial cycle from current balance when no prior ledger exists.
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

    /// Formats credits test response showing remaining balance.
    static func creditsMessage(from json: [String: Any]) -> String {
        let data = json["data"] as? [String: Any] ?? [:]
        let granted = (data["total_credits"] as? NSNumber)?.doubleValue ?? 0
        let used = (data["total_usage"] as? NSNumber)?.doubleValue ?? 0
        return "valid — \(Format.usd(granted - used)) remaining"
    }

    /// Calculates headline metrics from lifetime grant and spend totals.
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

    /// Calculates headline metrics against the active top-up cycle when available.
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
            // Clears title values to prevent stale balance readings.
            TitleValues.clear(provider: .openrouter)
            return Card(provider: name, rows: [], error: error.localizedDescription)
        }
    }
}

// MARK: - Antigravity (agy)

/// Quota provider querying the local loopback Connect server exposed by the agy CLI.
struct AntigravityProvider: Provider {
    let name = "Antigravity"

    struct Bucket {
        let id: String
        let label: String
        let percent: Int
        let resetTime: Date?
    }

    /// Normalizes group and window names to fit the dropdown row width.
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

    /// Decodes cached buckets, returning nil if the cache is expired, invalid, or missing.
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
            // Buckets without an explicit reset time expire after one week.
            let expiresAt = resetTime ?? fetchedAt.addingTimeInterval(7 * 86400)
            if expiresAt <= now { continue }
            buckets.append(Bucket(id: id, label: label, percent: percent, resetTime: resetTime))
        }
        return buckets.isEmpty ? nil : (buckets, fetchedAt)
    }

    // MARK: Transport

    /// Extracts listening ports for agy processes from lsof output.
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

    private static let rpcBody = Data(
        #"{"ideName":"antigravity","extensionName":"antigravity","locale":"en","ideVersion":"unknown"}"#.utf8)

    /// Tries HTTP and HTTPS schemes since agy port scheme assignments vary across runs.
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

    /// Publishes title metrics for recognized bucket identifiers.
    private static func publishHeadlines(_ buckets: [Bucket]) {
        for bucket in buckets where TitleMetric.metric(id: "antigravity.\(bucket.id)") != nil {
            TitleValues.set("antigravity.\(bucket.id)",
                            HeadlineValue(percent: bucket.percent,
                                          severity: severity(forPercent: bucket.percent)))
        }
    }

    /// Replays cached buckets with an age badge, clearing title metrics if stale.
    private static func cachedCard(error: String, now: Date = Date()) -> Card {
        guard let raw = Prefs.defaults.dictionary(forKey: Self.cacheKey),
              let cached = Self.decodeCache(raw, now: now)
        else {
            TitleValues.clear(provider: .antigravity)
            return Card(provider: ProviderID.antigravity.displayName, rows: [], error: error)
        }
        // Clears title values if cached data exceeds staleness threshold.
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

        if !ports.isEmpty && !rpcSucceeded {
            return Self.cachedCard(error: "agy running — quota fetch failed")
        }
        if rpcSucceeded {
            TitleValues.clear(provider: .antigravity)
            return Card(provider: name, rows: [], error: "agy responded without quota data")
        }
        return Self.cachedCard(error: "agy not running")
    }
}
