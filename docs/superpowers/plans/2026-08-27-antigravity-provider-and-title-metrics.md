# Antigravity Provider and Per-Metric Title Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Antigravity provider back, reading quota from the `agy`
CLI's loopback Connect server, and replace the per-provider menu bar title
flags with a per-metric picker covering all seven title numbers.

**Architecture:** A new `AntigravityProvider` conforms to the existing
`Provider` protocol and returns a `Card` like every other provider; it finds
`agy`'s ephemeral port with `lsof`, POSTs one Connect RPC, and falls back to a
`UserDefaults` cache whose buckets expire individually at their own
`resetTime`. Separately, `renderTitle()`'s two hardcoded providers become a
fixed seven-entry `TitleMetric` registry, with one shared headline map
replacing the two bespoke lock-boxes.

**Tech Stack:** Swift 5 / AppKit, no package manager. `swiftc -O` twice
(arm64 + x86_64) via `build.sh`, `lipo` into a universal binary. Tests are
`precondition` calls inside `runSelfTests()` in `Sources/main.swift`, run by
`build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test`. Python 3 for
`static_checks.py`, `check_charts.py`, and the one-off logo trace (PIL).

**Spec:** `docs/superpowers/specs/2026-08-27-antigravity-provider-and-title-metrics-design.md`

## Global Constraints

- **No new Swift source files.** `build.sh` hand-lists every source in two
  places and `static_checks.py` verifies that manifest. New types go in
  existing files: `TitleMetric` in `Sources/Prefs.swift`,
  `AntigravityProvider` and `BoundedProcess` in `Sources/Providers.swift`.
- **The title must not grow on upgrade.** All four Antigravity metrics
  default off.
- **Severity thresholds are 95 (critical) / 80 (warning)**, matching every
  existing provider.
- **`Format.color(for:percent:)` ignores its severity argument** and colours
  by percent alone. Do not "fix" this in passing.
- **Self-tests must never touch `UserDefaults.standard`.** Use the existing
  `local.claude-usage-menubar.self-test` suite pattern in `runSelfTests()`,
  saving and restoring `Prefs.defaults` around it.
- **Loopback TLS trust applies only to host `127.0.0.1`.** Any other host
  gets default validation.
- Commit messages follow the repo's `[type][scope] subject` convention;
  `validate_pr_title.py` enforces it on the PR title.

---

### Task 1: Extract the bounded-subprocess helper

`KeychainCLI.read` and `KeychainCLI.readStdin` contain the same
run-with-timeout body twice. Task 4 needs a third caller (`lsof`), so it comes
out first.

**Files:**
- Modify: `Sources/Providers.swift` (the `KeychainCLI` enum)

**Interfaces:**
- Produces: `BoundedProcess.run(executable:arguments:stdin:timeout:) -> Result<Data, BoundedProcess.Failure>`
  where `Failure` is `.blocked` or `.failed(Int32)`. `KeychainCLI.Failure`
  becomes a typealias so existing call sites and the keychain-timeout
  self-tests keep compiling unchanged.

- [ ] **Step 1: Add the helper next to `KeychainCLI`**

```swift
/// One bounded `Process` run, shared by every subprocess this app shells out
/// to. Extracted from KeychainCLI, which had two copies of this body; `lsof`
/// (AntigravityProvider) is the third caller, and a third copy of a timeout
/// is how timeouts drift apart.
enum BoundedProcess {
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
            // At most a few hundred bytes, so this cannot fill the pipe and
            // block; the close is what makes the child see EOF.
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // Leaves any approval dialog up — answering it makes the next
            // call succeed. Only this run is abandoned.
            task.terminate()
            return .failure(.blocked)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return task.terminationStatus == 0 ? .success(data) : .failure(.failed(task.terminationStatus))
    }
}
```

- [ ] **Step 2: Rewrite `KeychainCLI` over it**

Keep the doc comment explaining *why* the timeout exists (the Keychain
approval dialog) on `KeychainCLI` — it is not true of `lsof` and must not
migrate to `BoundedProcess`.

```swift
enum KeychainCLI {
    static let timeout: TimeInterval = 8
    typealias Failure = BoundedProcess.Failure

    static func read(_ arguments: [String], timeout: TimeInterval = timeout) -> Result<Data, Failure> {
        BoundedProcess.run(executable: "/usr/bin/security", arguments: arguments, timeout: timeout)
    }

    static func readStdin(_ commandLine: String, timeout: TimeInterval = timeout) -> Result<Data, Failure> {
        BoundedProcess.run(executable: "/usr/bin/security", arguments: ["-i"],
                           stdin: commandLine, timeout: timeout)
    }
}
```

- [ ] **Step 3: Build and run the existing self-tests**

Run: `./build.sh && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test`
Expected: PASS — including the existing "Keychain-timeout self-tests" block,
which is the regression test for this refactor. No new test is needed; this
task is behaviour-preserving by definition.

- [ ] **Step 4: Commit**

```bash
git add Sources/Providers.swift
git commit -m "[refactor][product] extract one bounded-subprocess helper from KeychainCLI"
```

---

### Task 2: Parse the quota payload

Pure function first, no networking.

**Files:**
- Modify: `Sources/Providers.swift` (new `AntigravityProvider`)
- Test: `Sources/main.swift` (`runSelfTests()`)

**Interfaces:**
- Produces:
  - `struct AntigravityProvider: Provider` with `let name = "Antigravity"`
  - `struct AntigravityProvider.Bucket { let id: String; let label: String; let percent: Int; let resetTime: Date? }`
  - `static func buckets(from json: [String: Any]) -> [Bucket]`
  - `static func label(group: String, window: String, fallback: String) -> String`
  - `static func rows(from buckets: [Bucket]) -> [Row]`

- [ ] **Step 1: Write the failing tests**

Add to `runSelfTests()` in `Sources/main.swift`, before the Prefs block. This
fixture is a trimmed copy of a real `RetrieveUserQuotaSummary` response.

```swift
    // MARK: Antigravity payload parsing
    let agyPayload: [String: Any] = [
        "response": [
            "groups": [
                [
                    "displayName": "Gemini Models",
                    "buckets": [
                        ["bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining",
                         "window": "weekly", "remainingFraction": 0.47822708,
                         "resetTime": "2026-08-30T10:12:38Z"],
                        ["bucketId": "gemini-5h", "displayName": "Five Hour Limit Remaining",
                         "window": "5h", "remainingFraction": 0.9965874,
                         "resetTime": "2026-08-27T12:59:26Z"],
                    ],
                ],
                [
                    "displayName": "Claude and GPT models",
                    "buckets": [
                        ["bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining",
                         "window": "weekly", "remainingFraction": 0.24941853,
                         "resetTime": "2026-08-29T17:12:46Z"],
                        ["bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining",
                         "window": "5h", "remainingFraction": 1,
                         "resetTime": "2026-08-27T13:28:09Z"],
                    ],
                ],
            ],
        ],
    ]
    let agyBuckets = AntigravityProvider.buckets(from: agyPayload)
    precondition(agyBuckets.count == 4, "all four buckets must survive parsing")
    precondition(agyBuckets.map(\.id) == ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"],
                 "buckets keep payload order")
    precondition(agyBuckets[0].label == "Gemini · Weekly")
    precondition(agyBuckets[3].label == "Claude/GPT · 5-hour")
    // remainingFraction is what is LEFT, so used = 1 - it.
    precondition(agyBuckets[0].percent == 52, "0.478 remaining is 52% used")
    precondition(agyBuckets[3].percent == 0, "a full bucket is 0% used")
    precondition(agyBuckets[0].resetTime != nil)

    // Label rules in isolation, including the fallbacks.
    precondition(AntigravityProvider.label(group: "Gemini Models", window: "weekly",
                                           fallback: "Weekly Limit Remaining") == "Gemini · Weekly")
    precondition(AntigravityProvider.label(group: "Claude and GPT models", window: "5h",
                                           fallback: "x") == "Claude/GPT · 5-hour")
    // An unknown window falls back to the server's own display name, so a
    // future bucket is still legible rather than labelled with a raw token.
    precondition(AntigravityProvider.label(group: "Gemini Models", window: "monthly",
                                           fallback: "Monthly Limit") == "Gemini · Monthly Limit")

    // Severity comes from percent, matching every other provider.
    let agyRows = AntigravityProvider.rows(from: agyBuckets)
    precondition(agyRows.count == 4)
    precondition(agyRows[0].severity == "normal")
    precondition(AntigravityProvider.rows(from: [
        AntigravityProvider.Bucket(id: "x", label: "X", percent: 96, resetTime: nil),
    ])[0].severity == "critical")
    precondition(AntigravityProvider.rows(from: [
        AntigravityProvider.Bucket(id: "y", label: "Y", percent: 83, resetTime: nil),
    ])[0].severity == "warning")
```

- [ ] **Step 2: Run to verify it fails**

Run: `./build.sh`
Expected: FAIL at compile time — `cannot find 'AntigravityProvider' in scope`.

- [ ] **Step 3: Implement the parser**

Add to `Sources/Providers.swift`, after `OpenRouterProvider`:

```swift
// MARK: - Antigravity (agy)

/// Antigravity's quota lives behind `RetrieveUserQuotaSummary`, served by the
/// `agy` CLI's own loopback Connect server with no authentication.
///
/// The remote form of this RPC (cloudcode-pa v1internal) returns 403
/// SUBSCRIPTION_REQUIRED for consumer accounts — see the design doc before
/// trying it again.
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
    /// The group name is the server's marketing string; trimming " Models"
    /// and folding " and " to "/" is what keeps a four-row card inside the
    /// dropdown's width without hand-maintaining a translation table that a
    /// new group would silently fall out of.
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

    static func rows(from buckets: [Bucket]) -> [Row] {
        buckets.map { bucket in
            Row(label: bucket.label, percent: bucket.percent,
                detail: "resets in \(Format.countdown(to: bucket.resetTime))",
                severity: bucket.percent >= 95 ? "critical" : (bucket.percent >= 80 ? "warning" : "normal"))
        }
    }

    func load() async -> Card {
        Card(provider: name, rows: [], error: "not implemented")
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./build.sh && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Providers.swift Sources/main.swift
git commit -m "[feat][product] parse Antigravity's RetrieveUserQuotaSummary payload"
```

---

### Task 3: Cache buckets and expire them individually

**Files:**
- Modify: `Sources/Providers.swift` (`AntigravityProvider`)
- Test: `Sources/main.swift` (`runSelfTests()`)

**Interfaces:**
- Consumes: `AntigravityProvider.Bucket` from Task 2.
- Produces:
  - `static func encodeCache(buckets:fetchedAt:) -> [String: Any]`
  - `static func decodeCache(_ raw: [String: Any], now: Date) -> (buckets: [Bucket], fetchedAt: Date)?`
    — returns `nil` when nothing survives, so the caller has one branch, not two.
  - `static var cacheKey: String { "antigravity.cache" }`

- [ ] **Step 1: Write the failing tests**

```swift
    // MARK: Antigravity cache expiry
    //
    // A cached reading outlives the agy process by design (agy is usually not
    // running). Each bucket expires at its OWN resetTime: a weekly number is
    // still true days later, a 5-hour one is not.
    let agyNow = Date(timeIntervalSince1970: 1_800_000_000)
    let agyCached = [
        AntigravityProvider.Bucket(id: "gemini-weekly", label: "Gemini · Weekly", percent: 52,
                                   resetTime: agyNow.addingTimeInterval(3600)),
        AntigravityProvider.Bucket(id: "gemini-5h", label: "Gemini · 5-hour", percent: 4,
                                   resetTime: agyNow.addingTimeInterval(-60)),
        AntigravityProvider.Bucket(id: "3p-weekly", label: "Claude/GPT · Weekly", percent: 75,
                                   resetTime: nil),
    ]
    let agyEncoded = AntigravityProvider.encodeCache(buckets: agyCached, fetchedAt: agyNow)
    let agyDecoded = AntigravityProvider.decodeCache(agyEncoded, now: agyNow)
    precondition(agyDecoded != nil)
    precondition(agyDecoded!.buckets.map(\.id) == ["gemini-weekly", "3p-weekly"],
                 "the reset 5-hour bucket must be dropped; a bucket with no resetTime is kept")
    precondition(agyDecoded!.buckets[0].percent == 52, "percentages survive the round trip")
    precondition(agyDecoded!.buckets[0].label == "Gemini · Weekly")
    precondition(agyDecoded!.fetchedAt == agyNow)

    // Every bucket past its reset means there is nothing honest left to show.
    precondition(AntigravityProvider.decodeCache(agyEncoded,
                                                 now: agyNow.addingTimeInterval(7200)) == nil,
                 "an all-expired cache must read as no cache at all")
    // A malformed or empty blob must not crash the poll.
    precondition(AntigravityProvider.decodeCache([:], now: agyNow) == nil)
```

- [ ] **Step 2: Run to verify it fails**

Run: `./build.sh`
Expected: FAIL — `type 'AntigravityProvider' has no member 'encodeCache'`.

- [ ] **Step 3: Implement**

Note the `nil` `resetTime` rule: a bucket that never told us when it resets is
kept, because dropping it would silently lose a number the server did report.

```swift
    static let cacheKey = "antigravity.cache"

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
    /// reset times — all three mean "show no cached rows", so callers get one
    /// branch instead of three.
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
            // A bucket with no resetTime is kept: the server declined to say
            // when it resets, which is not the same as it having reset.
            if let resetTime, resetTime <= now { continue }
            buckets.append(Bucket(id: id, label: label, percent: percent, resetTime: resetTime))
        }
        return buckets.isEmpty ? nil : (buckets, fetchedAt)
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `./build.sh && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Providers.swift Sources/main.swift
git commit -m "[feat][product] cache Antigravity buckets, expiring each at its own resetTime"
```

---

### Task 4: Talk to the loopback server

**Files:**
- Modify: `Sources/Providers.swift` (`AntigravityProvider.load`, new `LoopbackSession`)
- Modify: `Sources/Prefs.swift` (add `case antigravity` to `ProviderID`)
- Modify: `Sources/main.swift` (register in `Providers.all()`)

**Interfaces:**
- Consumes: `BoundedProcess.run` (Task 1), `buckets(from:)` (Task 2),
  `encodeCache`/`decodeCache` (Task 3).
- Produces: `static func agyPorts(fromLsof output: String) -> [Int]`, and a
  working `load()`.

- [ ] **Step 1: Write the failing test for port parsing**

Only the parsing is unit-testable; the socket call is exercised by the live
`--once` run in Task 8.

```swift
    // MARK: Antigravity port discovery
    //
    // Real `lsof -nP -iTCP -sTCP:LISTEN -a -c agy` output. Two ports per
    // process, and the header line must not parse as one.
    let lsofOutput = """
    COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    agy     60695 alex   10u  IPv4 0xaa8fec6e105fe8a7      0t0  TCP 127.0.0.1:58002 (LISTEN)
    agy     60695 alex   11u  IPv4 0xcfd3169d2c219c02      0t0  TCP 127.0.0.1:58003 (LISTEN)
    """
    precondition(AntigravityProvider.agyPorts(fromLsof: lsofOutput) == [58002, 58003])
    precondition(AntigravityProvider.agyPorts(fromLsof: "").isEmpty)
    precondition(AntigravityProvider.agyPorts(fromLsof: "COMMAND PID USER\n").isEmpty)
    // Anything not bound to loopback is not our server.
    precondition(AntigravityProvider.agyPorts(
        fromLsof: "agy 1 alex 10u IPv4 0x0 0t0 TCP *:9999 (LISTEN)").isEmpty)
```

- [ ] **Step 2: Run to verify it fails**

Run: `./build.sh`
Expected: FAIL — no member `agyPorts`.

- [ ] **Step 3: Implement discovery, transport and `load()`**

```swift
    /// agy opens ephemeral ports per run and writes no port file, so the only
    /// way to find its server is to ask the kernel who is listening.
    static func agyPorts(fromLsof output: String) -> [Int] {
        var ports: [Int] = []
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("agy") else { continue }
            for field in line.split(separator: " ") where field.hasPrefix("127.0.0.1:") {
                if let port = Int(field.dropFirst("127.0.0.1:".count)), !ports.contains(port) {
                    ports.append(port)
                }
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

    /// agy opens one plain-HTTP port and one TLS port with a self-signed
    /// certificate, and which is which is not stable between runs — so both
    /// schemes are tried per port.
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

    func load() async -> Card {
        for port in Self.listeningPorts() {
            guard let json = await Self.fetch(port: port) else { continue }
            let buckets = Self.buckets(from: json)
            guard !buckets.isEmpty else { continue }
            Prefs.defaults.set(Self.encodeCache(buckets: buckets, fetchedAt: Date()),
                               forKey: Self.cacheKey)
            return Card(provider: name, rows: Self.rows(from: buckets))
        }

        // agy is not running (the common case — it is a CLI, not a daemon).
        // Replay the last reading, minus any bucket whose window has since
        // reset, and say plainly how old it is.
        guard let raw = Prefs.defaults.dictionary(forKey: Self.cacheKey),
              let cached = Self.decodeCache(raw, now: Date())
        else {
            return Card(provider: name, rows: [], error: "agy not running")
        }
        return Card(provider: name, rows: Self.rows(from: cached.buckets),
                    badge: Badge(text: "as of \(Format.ago(cached.fetchedAt))", kind: .gray))
    }
```

And the session, next to `Net`:

```swift
/// URLSession that accepts a self-signed certificate from 127.0.0.1 and
/// nowhere else. agy's TLS port presents its own certificate; trusting it is
/// safe only because the connection cannot leave this machine, so the host
/// check is the whole security argument and must not be loosened.
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
```

- [ ] **Step 4: Register the provider**

In `Sources/Prefs.swift`, add the case and its display name:

```swift
    case claude, codex, openrouter, antigravity
```
```swift
        case .antigravity: return "Antigravity"
```

In `Sources/main.swift`, `Providers.all()`, append to the array:

```swift
            AntigravityProvider(),
```

Leave `supportsTitle` alone for now — Task 6 deletes it.

- [ ] **Step 5: Run the tests and a live check**

Run: `./build.sh && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test`
Expected: PASS — plus the existing `ProviderID` round-trip loop now covers
`.antigravity` for free.

Run: `build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --once`
Expected: an `Antigravity` section reading `agy not running` (no agy process
yet, no cache written).

- [ ] **Step 6: Commit**

```bash
git add Sources/Providers.swift Sources/Prefs.swift Sources/main.swift
git commit -m "[feat][product] read Antigravity quota from the agy loopback server"
```

---

### Task 5: The logo

**Files:**
- Create: `Resources/antigravity-template.svg`
- Create: `tools/trace_antigravity_logo.py`

**Interfaces:** none — an asset plus the script that produced it.

- [ ] **Step 1: Write the tracer**

Committing the script matters more than usual here: it is the only record of
where a vendor mark came from and how to regenerate it if the brand changes.

```python
#!/usr/bin/env python3
"""Trace antigravity.google's favicon into a monochrome menu bar template.

The Antigravity mark is a Google-gradient arch. Simple Icons has no entry for
it and the marketing site renders its logo in JavaScript, so the favicon is
the only vector-able source. This walks the 48x48 layer's alpha channel and
emits one path in the same shape as claude-template.svg.

Usage: python3 tools/trace_antigravity_logo.py <favicon.ico> <out.svg>
"""
import sys
from PIL import Image

ALPHA_THRESHOLD = 128


def contours(mask, w, h):
    """Marching squares over a boolean mask -> list of closed pixel loops."""
    ...
```

**This is the one step in the plan that is deliberately not pre-written.** A
tracer's threshold and simplification tolerance are tuned against the rendered
result in Step 3, so pre-committing constants here would be fiction. The shape
is fixed, though: load the .ico with PIL,
select the largest layer, threshold the alpha, march the boundary, simplify
collinear runs, scale into a `0 0 24 24` box, and emit
`<svg role="img" viewBox="0 0 24 24" xmlns="…"><title>Google Antigravity</title><path d="…"/></svg>`
with no `fill` attribute (the existing marks carry none — `logoImage()` fills
them white itself).

- [ ] **Step 2: Run it**

```bash
curl -sL --compressed https://antigravity.google/favicon.ico -o /tmp/ag.ico
python3 tools/trace_antigravity_logo.py /tmp/ag.ico Resources/antigravity-template.svg
```

- [ ] **Step 3: Review the glyph at menu-bar size**

Render it at 13×13 (the size `logoImage()` draws) and at 128×128, and look at
both. The arch must read as an arch: two legs, a rounded apex, feet flaring
outward, no filled interior.

**Do not proceed on a trace that looks wrong.** Adjust `ALPHA_THRESHOLD` or
the simplification tolerance and re-run. A hand-drawn approximation of a
vendor's mark is not acceptable.

- [ ] **Step 4: Verify the build picks it up**

Run: `./build.sh && ls build/ClaudeUsage.app/Contents/Resources/`
Expected: `antigravity-template.svg` present — `build.sh` globs
`Resources/*-template.svg`, so this needs no build change. If it is missing,
the glob is not what you think it is; fix that rather than hardcoding a copy.

Run: `python3 .github/scripts/static_checks.py`
Expected: PASS (it counts tracked text files; a new SVG and a new .py are
both fine).

- [ ] **Step 5: Commit**

```bash
git add Resources/antigravity-template.svg tools/trace_antigravity_logo.py
git commit -m "[feat][product] add the Antigravity brand mark as a menu bar template"
```

---

### Task 6: The title metric registry

**Files:**
- Modify: `Sources/Prefs.swift` (`TitleMetric`, registry, per-metric prefs, migration; delete `supportsTitle`)
- Test: `Sources/main.swift` (`runSelfTests()`)

**Interfaces:**
- Produces:
  - `struct TitleMetric: Hashable { let id: String; let provider: ProviderID; let label: String; let shortLabel: String; let defaultOn: Bool }`
  - `static let TitleMetric.all: [TitleMetric]` — seven entries in title order
  - `Prefs.showMetricInTitle(_ metric: TitleMetric) -> Bool`
  - `Prefs.setShowMetricInTitle(_ metric: TitleMetric, _ value: Bool)`
  - `Prefs.migrateTitleMetricsIfNeeded()`
  - `ProviderID.ownsTitleMetrics: Bool` (replaces `supportsTitle`)

- [ ] **Step 1: Write the failing tests**

Put these inside the existing isolated-suite block in `runSelfTests()`, where
`Prefs.defaults` already points at the self-test suite.

```swift
    // MARK: Title metric registry
    precondition(TitleMetric.all.count == 7)
    precondition(TitleMetric.all.map(\.id) == [
        "claude.session", "claude.weekly", "codex.weekly",
        "antigravity.gemini-weekly", "antigravity.gemini-5h",
        "antigravity.3p-weekly", "antigravity.3p-5h",
    ], "registry order is title order")
    // The title must not grow on upgrade: only today's three default on.
    precondition(TitleMetric.all.filter(\.defaultOn).map(\.id)
                 == ["claude.session", "claude.weekly", "codex.weekly"])
    precondition(ProviderID.claude.ownsTitleMetrics)
    precondition(ProviderID.antigravity.ownsTitleMetrics)
    precondition(!ProviderID.openrouter.ownsTitleMetrics,
                 "OpenRouter has no headline number, so it owns no metric")

    // Unset reads the metric's own default, not a blanket true — this is the
    // one place Prefs deviates from "never configured means show everything".
    for metric in TitleMetric.all {
        precondition(Prefs.showMetricInTitle(metric) == metric.defaultOn)
    }
    let geminiWeekly = TitleMetric.all.first { $0.id == "antigravity.gemini-weekly" }!
    Prefs.setShowMetricInTitle(geminiWeekly, true)
    precondition(Prefs.showMetricInTitle(geminiWeekly))

    // Migration: someone who hid Codex from the bar stays hidden.
    Prefs.defaults.removePersistentDomain(forName: selfTestSuite)
    Prefs.defaults.set(false, forKey: "title.codex")
    Prefs.defaults.set(true, forKey: "title.claude")
    Prefs.migrateTitleMetricsIfNeeded()
    precondition(!Prefs.showMetricInTitle(TitleMetric.all.first { $0.id == "codex.weekly" }!))
    precondition(Prefs.showMetricInTitle(TitleMetric.all.first { $0.id == "claude.session" }!))
    // Antigravity had no legacy flag and must not be switched on by migration.
    precondition(!Prefs.showMetricInTitle(geminiWeekly))

    // Idempotent: a second run must not undo a later manual change.
    Prefs.setShowMetricInTitle(geminiWeekly, true)
    Prefs.migrateTitleMetricsIfNeeded()
    precondition(Prefs.showMetricInTitle(geminiWeekly), "migration must run once, not every launch")
    Prefs.defaults.removePersistentDomain(forName: selfTestSuite)
```

- [ ] **Step 2: Run to verify it fails**

Run: `./build.sh`
Expected: FAIL — `cannot find 'TitleMetric' in scope`.

- [ ] **Step 3: Implement in `Sources/Prefs.swift`**

```swift
/// One tickable number in the menu bar title.
///
/// The title used to be two hardcoded providers. It is a registry because
/// Antigravity alone contributes four numbers across two unrelated quota
/// groups, and no single one of them is a fair headline for the others.
struct TitleMetric: Hashable {
    let id: String
    let provider: ProviderID
    /// Shown in Settings.
    let label: String
    /// Shown in the menu bar itself, where every character costs width. The
    /// spec requires a default title byte-identical to the old hardcoded one,
    /// so these are exactly the strings renderTitle() used to append.
    let shortLabel: String
    /// Antigravity's four are false: an upgrade must not silently widen the
    /// menu bar.
    let defaultOn: Bool

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
}
```

On `ProviderID`, replace `supportsTitle` with:

```swift
    /// A provider is title-capable if it owns at least one registry entry —
    /// so OpenRouter needs no special case, it simply owns none.
    var ownsTitleMetrics: Bool { TitleMetric.all.contains { $0.provider == self } }
```

On `Prefs`:

```swift
    static func showMetricInTitle(_ metric: TitleMetric) -> Bool {
        let key = "title.metric.\(metric.id)"
        return defaults.object(forKey: key) == nil ? metric.defaultOn : defaults.bool(forKey: key)
    }

    static func setShowMetricInTitle(_ metric: TitleMetric, _ value: Bool) {
        setFlag("title.metric.\(metric.id)", value)
    }

    /// Carries the old per-provider title.<id> booleans forward once. Without
    /// it, anyone who had hidden a provider from the bar gets it back on
    /// upgrade — the one visible regression this refactor could cause.
    static func migrateTitleMetricsIfNeeded() {
        guard defaults.object(forKey: "title.metricsMigrated") == nil else { return }
        for metric in TitleMetric.all {
            let legacyKey = "title.\(metric.provider.rawValue)"
            guard defaults.object(forKey: legacyKey) != nil else { continue }
            defaults.set(defaults.bool(forKey: legacyKey), forKey: "title.metric.\(metric.id)")
        }
        defaults.set(true, forKey: "title.metricsMigrated")
    }
```

Delete `showInTitle`/`setShowInTitle` and fix the two call sites the compiler
points at (`Providers.shouldPoll`, `SettingsWindow`). `shouldPoll` becomes:

```swift
        return Prefs.showInDropdown(id)
            || TitleMetric.all.contains { $0.provider == id && Prefs.showMetricInTitle($0) }
```

Also delete the two `supportsTitle` preconditions in `runSelfTests()` and call
`Prefs.migrateTitleMetricsIfNeeded()` once at launch in
`applicationDidFinishLaunching`, before the first render.

- [ ] **Step 4: Run to verify it passes**

Run: `./build.sh && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Prefs.swift Sources/main.swift Sources/SettingsWindow.swift
git commit -m "[refactor][product] make the menu bar title a per-metric registry"
```

---

### Task 7: Render and configure the seven metrics

**Files:**
- Modify: `Sources/main.swift` (`headlineText`, `renderTitle`, provider headline publishing)
- Modify: `Sources/Providers.swift` (Codex + Antigravity headline publishing)
- Modify: `Sources/SettingsWindow.swift` (Menu bar section)
- Test: `Sources/main.swift` (`runSelfTests()`)

**Interfaces:**
- Consumes: `TitleMetric` (Task 6).
- Produces:
  - `enum TitleValues` with `static func set(_ id: String, _ value: HeadlineValue?)`,
    `static func get(_ id: String) -> HeadlineValue?`, `static func clear(provider: ProviderID)`
  - `UsageMenuBar.headlineText(_ entries: [(TitleMetric, HeadlineValue?)]) -> String`

- [ ] **Step 1: Write the failing tests**

Replaces the existing six `headlineText` preconditions — delete those.

```swift
    // MARK: Title composition
    func metric(_ id: String) -> TitleMetric { TitleMetric.all.first { $0.id == id }! }
    let claudeSession = (metric("claude.session"), HeadlineValue(percent: 17, severity: "normal"))
    let claudeWeekly = (metric("claude.weekly"), HeadlineValue(percent: 85, severity: "warning"))
    let codexWeekly = (metric("codex.weekly"), HeadlineValue(percent: 42, severity: "normal"))
    let agyWeekly = (metric("antigravity.3p-weekly"), HeadlineValue(percent: 75, severity: "normal"))

    // REGRESSION GUARD: with default prefs the title must be byte-identical
    // to the string the old hardcoded renderTitle() produced. If this
    // assertion needs "updating", the refactor has widened the menu bar.
    precondition(UsageMenuBar.headlineText([claudeSession, claudeWeekly, codexWeekly])
                 == "Claude 5h 17% wk 85%   Codex wk 42%",
                 "consecutive metrics from one provider share a single provider name")
    precondition(UsageMenuBar.headlineText([claudeSession, claudeWeekly, codexWeekly, agyWeekly])
                 == "Claude 5h 17% wk 85%   Codex wk 42%   Antigravity 3p wk 75%")
    precondition(UsageMenuBar.headlineText([codexWeekly]) == "Codex wk 42%")
    // A metric with no value yet renders an em dash, not a stale number and
    // not a missing column.
    precondition(UsageMenuBar.headlineText([(metric("codex.weekly"), nil)]) == "Codex wk —")
    // Everything unticked must still produce a non-empty title, or the status
    // item becomes a zero-width, unclickable dead end (there is no Dock icon
    // to fall back on).
    precondition(UsageMenuBar.headlineText([]) == "AI")
```

- [ ] **Step 2: Run to verify it fails**

Run: `./build.sh`
Expected: FAIL — `extra argument`/`missing argument` at the old call sites.

- [ ] **Step 3: Implement the shared headline store**

In `Sources/main.swift`, next to `Format`:

```swift
/// Headline values for the title, keyed by TitleMetric.id and published by
/// providers as a side effect of load(). One store rather than a lock-box per
/// provider: the title now reads seven numbers from four providers, and four
/// bespoke singletons is three too many. Mirrors the @unchecked Sendable
/// lock-box pattern the two Headline classes it replaces already used.
final class TitleValues: @unchecked Sendable {
    static let shared = TitleValues()
    private let lock = NSLock()
    private var storage: [String: HeadlineValue] = [:]

    static func set(_ id: String, _ value: HeadlineValue?) {
        shared.lock.lock(); defer { shared.lock.unlock() }
        shared.storage[id] = value
    }

    static func get(_ id: String) -> HeadlineValue? {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return shared.storage[id]
    }

    /// On an auth failure a provider's numbers are wrong, not merely old.
    static func clear(provider: ProviderID) {
        shared.lock.lock(); defer { shared.lock.unlock() }
        for metric in TitleMetric.all where metric.provider == provider { shared.storage[metric.id] = nil }
    }
}
```

Then delete `ClaudeProvider.Headline` and `CodexProvider.Headline` and publish
through `TitleValues` instead:

- `ClaudeProvider.load`: replace `Self.headline.value = (session, weekly, worst)` with
  `TitleValues.set("claude.session", HeadlineValue(percent: session, severity: worst))`
  and the same for `claude.weekly`. Replace `Self.headline.value = nil` in the
  401 branch with `TitleValues.clear(provider: .claude)`.
- `CodexProvider`: `TitleValues.set("codex.weekly", Self.extractWeeklyHeadline(from: limits))`,
  and `TitleValues.clear(provider: .codex)` on the two failure returns.
- `AntigravityProvider.load`: after building `buckets`, publish each one whose
  id matches a registry metric:
  ```swift
  for bucket in buckets {
      TitleValues.set("antigravity.\(bucket.id)",
                      HeadlineValue(percent: bucket.percent,
                                    severity: bucket.percent >= 95 ? "critical"
                                            : (bucket.percent >= 80 ? "warning" : "normal")))
  }
  ```
  Publish from the cached branch too — a cached number in the dropdown and a
  blank one in the title would be incoherent.

- [ ] **Step 4: Rewrite `headlineText` and `renderTitle`**

```swift
    /// Plain-text title: the source of truth for the tooltip and the
    /// accessibility label, and the decision renderTitle() mirrors when
    /// building the attributed (logo-bearing) version, so the two never drift.
    nonisolated static func headlineText(_ entries: [(TitleMetric, HeadlineValue?)]) -> String {
        guard !entries.isEmpty else { return "AI" }
        var groups: [String] = []
        var current: (provider: ProviderID, parts: [String])?
        for (metric, value) in entries {
            let piece = "\(metric.shortLabel) \(value.map { "\($0.percent)%" } ?? "—")"
            if var open = current, open.provider == metric.provider {
                open.parts.append(piece)
                current = open
            } else {
                if let open = current {
                    groups.append(([open.provider.displayName] + open.parts).joined(separator: " "))
                }
                current = (metric.provider, [piece])
            }
        }
        if let open = current {
            groups.append(([open.provider.displayName] + open.parts).joined(separator: " "))
        }
        return groups.joined(separator: "   ")
    }
```

`renderTitle()` walks the same list, appending each provider's logo once when
the provider changes and colouring each percentage with
`Format.color(for:percent:)`. Logo resource name is
`"\(provider.rawValue)-template"`, which already matches `claude-template`,
`codex-template` and the new `antigravity-template`. Keep the `"AI"` fallback
when the visible list is empty.

- [ ] **Step 5: Rebuild the Settings section**

The Providers grid loses its "Menu bar" column (drop it from `columnTitles`,
drop the `supportsTitle` branch, one checkbox per row). Add a new section
below it:

```swift
    private func menuBarSection() -> NSView {
        let header = NSTextField(labelWithString: "Menu bar")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = NSStackView(views: [header])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for metric in TitleMetric.all {
            let check = NSButton(
                checkboxWithTitle: "\(metric.provider.displayName) · \(metric.label)",
                target: self, action: #selector(metricToggled(_:)))
            check.state = Prefs.showMetricInTitle(metric) ? .on : .off
            check.identifier = NSUserInterfaceItemIdentifier(metric.id)
            stack.addArrangedSubview(check)
        }
        return stack
    }

    @objc private func metricToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let metric = TitleMetric.all.first(where: { $0.id == raw }) else { return }
        Prefs.setShowMetricInTitle(metric, sender.state == .on)
    }
```

Add `menuBarSection()` to the window's root stack where the old Providers
section ends.

- [ ] **Step 6: Run to verify it passes**

Run: `./build.sh && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test`
Expected: PASS.

- [ ] **Step 7: Verify the title is unchanged by default**

Run: `build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --once`
Expected: the printed title line reads exactly as it did before this branch
for a default install — Claude's two numbers and Codex's one, no Antigravity.

- [ ] **Step 8: Commit**

```bash
git add Sources/main.swift Sources/Providers.swift Sources/SettingsWindow.swift
git commit -m "[feat][product] let the menu bar show any subset of the seven usage numbers"
```

---

### Task 8: Docs, full gate, PR

**Files:**
- Modify: `README.md`, `SECURITY.md`
- Modify: GitHub repo description (via `gh`, not a file)

**Interfaces:** none.

- [ ] **Step 1: README**

- Opening paragraph: four tools, not three — add **Antigravity**.
- Providers table: add
  `| Antigravity | `POST 127.0.0.1:<port>/…/RetrieveUserQuotaSummary` (agy's local server) | no |`
- Delete the Antigravity bullet from "Providers that aren't here" and add a
  short paragraph in its place explaining the local-server constraint and the
  `as of` badge — mirroring how the Codex staleness paragraph already reads.
- Record that the remote `cloudcode-pa` RPC returns 403 for consumer accounts,
  so the next reader re-tests rather than re-argues.
- Settings section: describe the Menu bar metric picker replacing the
  per-provider checkbox, and note Antigravity's four default off.
- Keep the "All three providers are visible by default" sentence accurate —
  it now says four.

- [ ] **Step 2: SECURITY.md**

Add the loopback TLS exception: the app accepts a self-signed certificate from
`127.0.0.1` only, because `agy` presents its own, and the connection cannot
leave the machine. State that no credential is sent to that server — the RPC
is unauthenticated.

- [ ] **Step 3: Run the full gate**

```bash
python3 .github/scripts/static_checks.py
python3 tools/check_charts.py
./build.sh
build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test
```
Expected: all four pass.

- [ ] **Step 4: Live verification in both states**

With agy running (start `agy -p "Say OK." &` and poll while it lives):
```bash
build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --once
```
Expected: four Antigravity rows with real percentages, no badge.

After agy exits, run `--once` again.
Expected: the same rows under an `as of Nm ago` badge, sourced from the cache.

Record both outputs in the PR body. **A PR without both is not done** — the
cache path is the one this app will spend almost all its time in.

- [ ] **Step 5: Commit and open the PR**

```bash
git add README.md SECURITY.md
git commit -m "[docs][product] document the Antigravity provider and the metric picker"
t3000-exec git push -u origin feat/antigravity-provider
t3000-exec gh pr create --title "[feat][product] bring back Antigravity, and let the menu bar show any subset of numbers" --body "…"
```

This is a `burnett-madoc-corp` repo, so the push and the PR go through
`t3000-exec` and the PR must be authored by `t-3000-agent[bot]`. Never fall
back to the user's own `gh` credentials.

- [ ] **Step 6: Update the repo description**

```bash
t3000-exec gh repo edit burnett-madoc-corp/claude-usage-menubar \
  --description "macOS menu bar app showing rate-limit and credit usage for Claude, Codex, OpenRouter and Antigravity"
```
