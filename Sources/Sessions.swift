import Darwin
import Foundation

// MARK: - JSON helpers

private extension Dictionary where Key == String, Value == Any {
    func int64(_ key: String) -> Int64? { (self[key] as? NSNumber)?.int64Value }
    func string(_ key: String) -> String? { self[key] as? String }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
}

// MARK: - Process time parsing
//
// `ps -o lstart=` renders the machine's LOCAL time zone; the registry's
// `procStart` string is UTC. On this machine (BST, UTC+1) the two differ by
// exactly one hour for every live session — a naive string compare silently
// discards every one of them. Parse both into `Date` with explicit,
// deliberate time zones and compare instants.

enum ProcessTime {
    private static func formatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        f.timeZone = timeZone
        f.isLenient = true
        return f
    }

    /// `ps lstart` pads a single-digit day with a leading space
    /// ("Sat Aug  9 …"); collapse that down so the formatter's non-padded
    /// `d` pattern lines up regardless of day width.
    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " ")
    }

    static func parseLocal(_ raw: String) -> Date? {
        formatter(timeZone: .current).date(from: normalize(raw))
    }

    static func parseUTC(_ raw: String) -> Date? {
        formatter(timeZone: TimeZone(identifier: "UTC")!).date(from: normalize(raw))
    }

    /// Inverse of the two parsers above — self-tests use this to build exact
    /// fixture strings from a known instant instead of hand-writing
    /// timestamps that could drift from the real `ps`/registry formats.
    static func format(_ date: Date, timeZone: TimeZone) -> String {
        formatter(timeZone: timeZone).string(from: date)
    }
}

// MARK: - Live process discovery

struct ProcInfo: Sendable, Equatable {
    var pid: pid_t
    var state: String
    var startedLocal: Date
    var comm: String

    /// macOS `ps` state codes: the leading letter is the scheduler state and
    /// `T` means stopped (SIGSTOP/SIGTSTP). Trailing flags (`+`, `s`, `<`, …)
    /// carry no bearing on suspension.
    var isStopped: Bool { state.hasPrefix("T") }
}

enum ProcessScanner {
    // pid, then the state code, then a fixed 24-char `lstart` (ctime-style,
    // day space-padded), then whatever's left as comm — which can itself
    // contain spaces ("Claude Helper (Renderer)"), so it must be the final
    // greedy group.
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^\s*(\d+)\s+([A-Za-z][\w+<>]*)\s+(\w{3}\s+\w{3}\s+[\d ]\d\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.+)$"#
    )

    /// Pure parser for `ps -axo pid=,state=,lstart=,comm=` output — self-testable
    /// without a subprocess.
    static func parse(psOutput: String) -> [ProcInfo] {
        var result: [ProcInfo] = []
        for substring in psOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(substring)
            let full = NSRange(line.startIndex..., in: line)
            guard let match = lineRegex.firstMatch(in: line, range: full),
                  let pidRange = Range(match.range(at: 1), in: line),
                  let stateRange = Range(match.range(at: 2), in: line),
                  let lstartRange = Range(match.range(at: 3), in: line),
                  let commRange = Range(match.range(at: 4), in: line),
                  let pid = pid_t(line[pidRange]),
                  let started = ProcessTime.parseLocal(String(line[lstartRange]))
            else { continue }
            result.append(ProcInfo(pid: pid, state: String(line[stateRange]),
                                   startedLocal: started, comm: String(line[commRange])))
        }
        return result
    }

    static func run() -> [ProcInfo] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,state=,lstart=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parse(psOutput: String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Liveness / suspension

/// A stale registry file whose PID is dead, or whose claimed start time
/// doesn't match the real process (PID reuse), is discarded rather than
/// shown as a session.
enum Liveness {
    /// Registration lag observed on this machine's 5 live sessions: 2–11s
    /// between the OS process start and the registry writing its own
    /// `startedAt`. 20s gives headroom without coming close to plausible
    /// PID-reuse gaps (minutes to days).
    static let startedAtTolerance: TimeInterval = 20
    /// `procStart` and `ps lstart` both describe the same OS-reported start
    /// instant at 1s resolution — near-exact once time zones are normalized.
    static let procStartTolerance: TimeInterval = 5

    static func isAlive(pid: pid_t, startedAtMs: Int64?, procStart: String?, process: ProcInfo?) -> Bool {
        guard let process, process.pid == pid else { return false }
        // ESRCH = no such process (dead / reused). EPERM = alive, owned by
        // someone else — still alive for our purposes.
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }

        // startedAt (epoch ms) is unambiguous — prefer it (correction 2).
        if let startedAtMs {
            let started = Date(timeIntervalSince1970: Double(startedAtMs) / 1000)
            return abs(started.timeIntervalSince(process.startedLocal)) <= startedAtTolerance
        }
        // Fallback: procStart (UTC) vs ps lstart (local) — correction 1.
        if let procStart, let utc = ProcessTime.parseUTC(procStart) {
            return abs(utc.timeIntervalSince(process.startedLocal)) <= procStartTolerance
        }
        return false
    }
}

/// A SIGSTOPed `claude` stops updating its registry file. The plan's first
/// line of defence was to treat a stale `statusUpdatedAt` as suspended, with
/// a direct process-state check as the documented escalation "if that proves
/// too coarse in practice".
///
/// It proved too coarse on the first real run: Claude Code rewrites the
/// registry on status *transitions*, not on a heartbeat, so a session sitting
/// in one long turn is byte-for-byte indistinguishable from a suspended one.
/// A genuinely-busy session was demoted to idle after 25 minutes of a single
/// turn — wrong exactly when the row is most worth looking at.
///
/// So the escalation is what ships: the `ps` scan already runs once per
/// refresh, and adding its `state=` column costs nothing. Suspension is now
/// read from the process itself (`T` = stopped) and the registry's `status`
/// is trusted at face value regardless of age.
enum Suspension {
    static func isBusy(status: String?, processStopped: Bool) -> Bool {
        guard status == "busy" else { return false }
        return !processStopped
    }
}

// MARK: - cwd <-> project-directory encoding

enum PathEncoding {
    /// Both `/` and `.` map to `-` (verified) — note the resulting `--`
    /// wherever a path segment starts with a dot, e.g. a `.ade` worktree.
    static func encode(cwd: String) -> String {
        String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    static func label(cwd: String) -> String {
        (cwd as NSString).lastPathComponent
    }
}

// MARK: - Registry file (~/.claude/sessions/<pid>.json)

struct RegistryEntry: Decodable, Sendable {
    var pid: pid_t
    var sessionId: String
    var cwd: String
    var startedAt: Int64?
    var procStart: String?
    var status: String?
    var statusUpdatedAt: Int64?
    var name: String?
}

// MARK: - Session model

enum AgentKind: String, Sendable { case claude, codex }

struct AgentSession: Sendable {
    var kind: AgentKind
    var pid: pid_t
    var label: String
    var cwd: String
    var model: String?
    var busy: Bool
    var turns: Int
    var inputTokens: Int64
    var outputTokens: Int64
    var subagentTokens: Int64?
    var contextTokens: Int64?
    var contextWindow: Int64?
    var xFloorMultiple: Double?
    var compactionCount: Int
    var lastCompactionAt: Date?
    var lastCompactionPreCtx: Int64?
    var lastCompactionPostCtx: Int64?   // nil = reclaim pending, never 0 or 100%
    var hasUsage: Bool
    // Newest non-sidechain usage-record timestamp. Purely additive bookkeeping
    // (populated in claudeFold alongside lastCompactionAt, same parsing) added
    // for Phase 4b's "sort by most-recent transcript activity" requirement —
    // this file's existing scan/metric logic is otherwise untouched.
    var lastActivityAt: Date?
    // False only via a heuristic PID<->transcript fallback. liveSessions()
    // today matches exclusively through the deterministic registry file, so
    // this is always true in practice until that fallback is implemented;
    // the field exists so the renderer's "(?)" handling is ready for it.
    var matched: Bool = true

    var contextPercent: Int? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return Int((Double(contextTokens) / Double(contextWindow) * 100).rounded())
    }

    var severity: SessionScanner.Severity {
        SessionScanner.severity(multiple: xFloorMultiple, contextPercent: contextPercent)
    }
}

// MARK: - Incremental transcript reader

/// Byte-offset incremental reader keyed by path. On re-scan: size/mtime
/// unchanged → reuse; grown → fold only the newly-appended, complete lines;
/// shrunk → discard and re-read from zero. All file I/O here is synchronous
/// (no `await` inside `scan`), so calls to the same actor instance serialize
/// with no interleaving — two overlapping requests for the same path can
/// never both perform a full re-read; the second simply observes the first's
/// already-updated state.
actor TranscriptReader {
    static let shared = TranscriptReader()

    struct Acc: Sendable {
        var byteOffset: UInt64 = 0
        var fileSize: UInt64 = 0

        var seenMessageIds: Set<String> = []
        var rawInputTokens: Int64 = 0      // input+cacheRead+cacheCreation, incl. sidechains (they bill)
        var rawOutputTokens: Int64 = 0
        var subagentTokens: Int64 = 0
        var hasSubagentTokens: Bool = false

        var turnCosts: [Int64] = []        // deduped, non-sidechain, since last compaction boundary
        var contextTokens: Int64?          // newest non-sidechain per-turn quantity
        var lastActivityAt: Date?          // newest usage-record timestamp, main or sidechain
        var lastModel: String?
        var resolvedModels: [String] = []  // resolvedModel corroboration votes, in order seen

        var compactionCount: Int = 0
        var lastCompactionAt: Date?
        var lastCompactionPreCtx: Int64?
        var lastCompactionPostCtx: Int64?  // nil while pending
        var awaitingPostCompaction: Bool = false
        var lastNonSidechainCtx: Int64?    // running "pre" candidate for the next boundary

        // Bytes read past the last complete line's terminating newline. Kept
        // (never dropped) so a line straddling two scans is folded exactly
        // once, whole, on whichever scan completes it.
        var partialTail: Data = Data()
    }

    private var accumulators: [String: Acc] = [:]

    @discardableResult
    func scan(_ url: URL) -> Acc {
        let key = url.path
        var acc = accumulators[key] ?? Acc()

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attrs?[.size] as? NSNumber)?.uint64Value else {
            // Not on disk yet — brand-new session, pre-first-message.
            accumulators[key] = acc
            return acc
        }

        if size < acc.byteOffset {
            acc = Acc()   // shrink: discard and re-read from zero
        }
        if size == acc.byteOffset {
            accumulators[key] = acc
            return acc
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            accumulators[key] = acc
            return acc
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: acc.byteOffset)
        guard let newBytes = try? handle.readToEnd(), !newBytes.isEmpty else {
            accumulators[key] = acc
            return acc
        }

        var combined = acc.partialTail
        combined.append(newBytes)

        let newline: UInt8 = 0x0A
        var searchStart = combined.startIndex
        while let nlIndex = combined[searchStart...].firstIndex(of: newline) {
            let lineData = combined[searchStart..<nlIndex]
            SessionScanner.claudeFold(line: String(decoding: lineData, as: UTF8.self), into: &acc)
            searchStart = combined.index(after: nlIndex)
        }
        // byteOffset tracks raw bytes already read off disk — including any
        // trailing partial line, which is kept (not re-read) in
        // `partialTail`. Setting it to anything less than `size` would make
        // the next scan re-read the partial bytes from disk *and* still
        // carry them in `partialTail`, duplicating them.
        acc.partialTail = Data(combined[searchStart...])
        acc.byteOffset = size
        acc.fileSize = size

        accumulators[key] = acc
        return acc
    }
}

// MARK: - Parsing / fold rules / metrics

enum SessionScanner {
    /// Folds one JSONL transcript line into the running accumulator. Pure
    /// and synchronous so self-tests can drive it directly with literal
    /// fixture lines — no actor, no file I/O.
    static func claudeFold(line: String, into acc: inout TranscriptReader.Acc) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        // Compaction marker: `type: "user"`, `isCompactSummary: true`, and
        // NO sibling `compactMetadata` key at all (it's absent, not null) —
        // key off the boolean flag alone. Carries no usage of its own.
        if obj.bool("isCompactSummary") == true {
            acc.compactionCount += 1
            acc.lastCompactionAt = obj.string("timestamp").flatMap {
                Format.iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
            } ?? acc.lastCompactionAt
            acc.lastCompactionPreCtx = acc.lastNonSidechainCtx
            acc.lastCompactionPostCtx = nil
            acc.awaitingPostCompaction = true
            acc.turnCosts = []   // xFloor baseline/live window reset at the boundary
            return
        }

        // Agent/Task tool results carry subagent burn (`totalTokens`) and a
        // resolvedModel corroboration vote — not a usage record.
        if let toolResult = obj.dict("toolUseResult") {
            if let tokens = toolResult.int64("totalTokens") {
                acc.subagentTokens += tokens
                acc.hasSubagentTokens = true
            }
            if let resolved = toolResult.string("resolvedModel") {
                acc.resolvedModels.append(resolved)
            }
            return
        }

        guard obj.string("type") == "assistant",
              let message = obj.dict("message"),
              let usage = message.dict("usage")
        else { return }

        // Dedup key is `message.id` specifically — `requestId` is off by one
        // from it in real data, not an equivalent key.
        let dedupKey = message.string("id") ?? obj.string("uuid") ?? UUID().uuidString
        guard !acc.seenMessageIds.contains(dedupKey) else { return }
        acc.seenMessageIds.insert(dedupKey)

        // `input_tokens` alone is flat noise (observed 0/1/2, no signal) —
        // the real per-turn cost lives in cache_read + cache_creation.
        let input = usage.int64("input_tokens") ?? 0
        let cacheRead = usage.int64("cache_read_input_tokens") ?? 0
        let cacheCreation = usage.int64("cache_creation_input_tokens") ?? 0
        let output = usage.int64("output_tokens") ?? 0
        let quantity = input + cacheRead + cacheCreation

        // Raw totals include sidechains — they bill — but only the main
        // chain feeds turn counts, both xFloor windows, and contextPercent.
        acc.rawInputTokens += quantity
        acc.rawOutputTokens += output

        // Activity recency counts any usage record, sidechain included — a
        // subagent turn still means the file was touched just now.
        if let ts = obj.string("timestamp") {
            acc.lastActivityAt = (Format.iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)) ?? acc.lastActivityAt
        }

        guard obj.bool("isSidechain") != true else { return }

        acc.turnCosts.append(quantity)
        acc.contextTokens = quantity
        acc.lastNonSidechainCtx = quantity
        if let model = message.string("model") { acc.lastModel = model }
        if acc.awaitingPostCompaction {
            acc.lastCompactionPostCtx = quantity
            acc.awaitingPostCompaction = false
        }
    }

    static func median(_ values: [Int64]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0
            ? Double(sorted[mid - 1] + sorted[mid]) / 2
            : Double(sorted[mid])
    }

    /// nil under 5 deduped turns since the last compaction boundary — never
    /// a fabricated 1.0x.
    static func xFloor(turnCosts: [Int64]) -> Double? {
        guard turnCosts.count >= 5 else { return nil }
        let baseline = median(Array(turnCosts.prefix(5)))
        guard baseline > 0 else { return nil }
        let live = median(Array(turnCosts.suffix(5)))
        return live / baseline
    }

    enum Severity: Int, Comparable, Sendable {
        case green, dimGreen, yellow, orange, red
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static func xFloorSeverity(_ multiple: Double) -> Severity {
        switch multiple {
        case ..<1.5: return .green
        case ..<2.5: return .dimGreen
        case ..<4.0: return .yellow
        case ..<7.0: return .orange
        default: return .red
        }
    }

    /// Mirrors `Format.color`'s 80/95 thresholds so the two signals agree.
    static func contextSeverity(_ percent: Int) -> Severity {
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        return .green
    }

    /// Row colour = worse of the two — catches a heavy-start session (a huge
    /// baseline pins the multiple near 1.0x forever) that the multiple alone
    /// would miss.
    static func severity(multiple: Double?, contextPercent: Int?) -> Severity {
        max(multiple.map(xFloorSeverity) ?? .green, contextPercent.map(contextSeverity) ?? .green)
    }

    // MARK: Model / window resolution

    static let baseWindows: [String: Int64] = [
        "opus": 200_000, "claude-opus-5": 200_000,
        "sonnet": 200_000, "claude-sonnet-5": 200_000,
        "haiku": 200_000, "claude-haiku-4-5-20251001": 200_000,
        "fable": 200_000, "claude-fable-5": 200_000,
    ]
    static let suffixWindows: [String: Int64] = ["1m": 1_000_000]

    /// Handles both the alias form from settings (`opus[1m]`) and the
    /// full-id form from `resolvedModel` (`claude-opus-5[1m]`). Unknown
    /// suffix falls through to the base default; unknown base yields no
    /// window. Never crashes, never invents a number.
    static func modelVariant(parsing raw: String) -> (base: String, window: Int64?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ("", nil) }

        var base = trimmed
        var suffix: String?
        if let open = trimmed.firstIndex(of: "["), trimmed.hasSuffix("]") {
            base = String(trimmed[trimmed.startIndex..<open])
            let afterOpen = trimmed.index(after: open)
            let beforeClose = trimmed.index(before: trimmed.endIndex)
            if afterOpen <= beforeClose {
                suffix = String(trimmed[afterOpen..<beforeClose])
            }
        }
        guard let baseWindow = baseWindows[base] else { return (base, nil) }
        guard let suffix else { return (base, baseWindow) }
        return (base, suffixWindows[suffix] ?? baseWindow)
    }

    /// Tiered resolution: session-start settings > resolvedModel
    /// corroboration > bare model-name default, then an observed-usage
    /// upgrade to 1M that self-corrects tier 1's blind spot (a mid-session
    /// `/model` switch is recorded nowhere in the transcript).
    static func contextWindow(settingsModel: String?, resolvedModel: String?,
                               base: String?, observedCtx: Int64?) -> Int64? {
        var window: Int64?
        if let settingsModel { window = modelVariant(parsing: settingsModel).window }
        if window == nil, let resolvedModel { window = modelVariant(parsing: resolvedModel).window }
        if window == nil, let base { window = modelVariant(parsing: base).window }
        if let observedCtx, observedCtx > 200_000, window == nil || window! < 1_000_000 {
            window = 1_000_000
        }
        return window
    }

    // MARK: Settings chain (project → user)

    static func resolveSettingsModel(cwd: String, userSettingsPath: URL) -> String? {
        let cwdURL = URL(fileURLWithPath: cwd)
        for name in ["settings.local.json", "settings.json"] {
            let path = cwdURL.appendingPathComponent(".claude").appendingPathComponent(name)
            if let model = modelKey(inSettingsAt: path) { return model }
        }
        return modelKey(inSettingsAt: userSettingsPath)
    }

    private static func modelKey(inSettingsAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["model"] as? String
    }

    // MARK: Live-session enumeration

    /// Injected inputs so self-tests can point this at fixture directories
    /// under `NSTemporaryDirectory()` instead of the real `~/.claude`.
    static func liveSessions(
        processList: [ProcInfo],
        mappingDir: URL,
        projectsDir: URL,
        userSettingsPath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"),
        reader: TranscriptReader = .shared
    ) async -> [AgentSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: mappingDir, includingPropertiesForKeys: nil)
        else { return [] }
        let processByPid = Dictionary(processList.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        var sessions: [AgentSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let registry = try? JSONDecoder().decode(RegistryEntry.self, from: data)
            else { continue }

            guard Liveness.isAlive(pid: registry.pid, startedAtMs: registry.startedAt,
                                    procStart: registry.procStart, process: processByPid[registry.pid])
            else { continue }

            let encoded = PathEncoding.encode(cwd: registry.cwd)
            let transcript = projectsDir.appendingPathComponent(encoded)
                .appendingPathComponent("\(registry.sessionId).jsonl")
            let acc = await reader.scan(transcript)

            let settingsModel = resolveSettingsModel(cwd: registry.cwd, userSettingsPath: userSettingsPath)
            let window = contextWindow(settingsModel: settingsModel, resolvedModel: acc.resolvedModels.last,
                                        base: acc.lastModel, observedCtx: acc.contextTokens)

            sessions.append(AgentSession(
                kind: .claude,
                pid: registry.pid,
                label: registry.name ?? PathEncoding.label(cwd: registry.cwd),
                cwd: registry.cwd,
                model: acc.lastModel,
                busy: Suspension.isBusy(status: registry.status,
                                        processStopped: processByPid[registry.pid]?.isStopped ?? false),
                turns: acc.turnCosts.count,
                inputTokens: acc.rawInputTokens,
                outputTokens: acc.rawOutputTokens,
                subagentTokens: acc.hasSubagentTokens ? acc.subagentTokens : nil,
                contextTokens: acc.contextTokens,
                contextWindow: window,
                xFloorMultiple: xFloor(turnCosts: acc.turnCosts),
                compactionCount: acc.compactionCount,
                lastCompactionAt: acc.lastCompactionAt,
                lastCompactionPreCtx: acc.lastCompactionPreCtx,
                lastCompactionPostCtx: acc.lastCompactionPostCtx,
                hasUsage: acc.contextTokens != nil,
                lastActivityAt: acc.lastActivityAt
            ))
        }
        return sessions.sorted { $0.label < $1.label }
    }
}

// MARK: - Entry point for main.swift

enum Sessions {
    static func snapshot() async -> [AgentSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return await SessionScanner.liveSessions(
            processList: ProcessScanner.run(),
            mappingDir: home.appendingPathComponent(".claude/sessions"),
            projectsDir: home.appendingPathComponent(".claude/projects")
        )
    }
}

// MARK: - Self-tests
//
// One fixture per verified data trap, named after the trap it guards. Pure
// `claudeFold`/`SessionScanner` calls need no actor; the incremental-read and
// end-to-end tests bridge `TranscriptReader`'s actor calls with the same
// semaphore+Task pattern `--once` already uses in main.swift.

enum SessionSelfTests {
    static func run() {
        testCacheReadFieldChoice()
        testMessageIdDedup()
        testCompaction()
        testSidechainExclusion()
        testWindowResolution()
        testPathEncoding()
        testProcessScannerParsing()
        testLiveness()
        testSuspension()
        testSeverityAndNoUsage()
        testLastActivityAt()
        testIncrementalRead()
        testLiveSessionsEndToEnd()
    }

    // MARK: lastActivityAt — Phase 4b's recency signal, threaded through the
    // same per-record timestamp parsing lastCompactionAt already uses.

    private static func testLastActivityAt() {
        var acc = TranscriptReader.Acc()
        precondition(acc.lastActivityAt == nil, "no records seen yet must read as no activity, not epoch zero")

        SessionScanner.claudeFold(line: usageLine(id: "t1", timestamp: "2026-08-11T12:00:00.000Z"), into: &acc)
        let first = acc.lastActivityAt
        precondition(first != nil)

        SessionScanner.claudeFold(line: usageLine(id: "t2", timestamp: "2026-08-11T13:00:00.000Z"), into: &acc)
        precondition(acc.lastActivityAt! > first!, "a later record must advance the recency timestamp")

        // A sidechain record still counts as activity — the subagent touched
        // the file just now, even though it's excluded from turns/xFloor/ctx.
        SessionScanner.claudeFold(line: usageLine(id: "t3", sidechain: true, timestamp: "2026-08-11T14:00:00.000Z"), into: &acc)
        precondition(acc.lastActivityAt! > first!, "sidechain records must still move the recency signal")
    }

    // MARK: Fixture builders

    private static func usageLine(id: String, input: Int64 = 2, cacheRead: Int64 = 0, cacheCreation: Int64 = 0,
                                   output: Int64 = 100, model: String = "claude-opus-5",
                                   sidechain: Bool = false, timestamp: String = "2026-08-11T12:00:00.000Z") -> String {
        """
        {"type":"assistant","isSidechain":\(sidechain),"timestamp":"\(timestamp)","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreation),"output_tokens":\(output)}}}
        """
    }

    private static func compactionMarker(timestamp: String = "2026-08-11T13:00:00.000Z") -> String {
        """
        {"type":"user","isCompactSummary":true,"isSidechain":false,"timestamp":"\(timestamp)","message":{"role":"user","content":"compacted"}}
        """
    }

    // MARK: cache_read field choice — trap 1 (input_tokens carries no signal)

    private static func testCacheReadFieldChoice() {
        var acc = TranscriptReader.Acc()
        let reads: [Int64] = [100_000, 150_000, 200_000, 250_000, 300_000, 350_000]
        for (i, r) in reads.enumerated() {
            SessionScanner.claudeFold(line: usageLine(id: "cr\(i)", cacheRead: r), into: &acc)
        }
        precondition(acc.turnCosts == reads.map { $0 + 2 },
                     "quantity must track cache_read, not the flat input_tokens=2")
        let multiple = SessionScanner.xFloor(turnCosts: acc.turnCosts)
        precondition(multiple != nil && multiple! > 1.2,
                     "cache_read growth must move xFloor upward — regressing to input_tokens alone pins this at 1.0x")
    }

    // MARK: message.id dedup — trap 2

    private static func testMessageIdDedup() {
        var acc = TranscriptReader.Acc()
        let dup = usageLine(id: "m1", cacheRead: 52_295)
        SessionScanner.claudeFold(line: dup, into: &acc)
        SessionScanner.claudeFold(line: dup, into: &acc)
        SessionScanner.claudeFold(line: dup, into: &acc)
        precondition(acc.turnCosts.count == 1, "triplicated records must dedup to one turn")
        precondition(acc.rawInputTokens == 52_295 + 2, "raw totals must dedup too, not just turn counts")
    }

    // MARK: compaction — trap 3/4, reclaim pairing, pending case

    private static func testCompaction() {
        var acc = TranscriptReader.Acc()
        for i in 0..<3 {
            SessionScanner.claudeFold(line: usageLine(id: "pre\(i)", cacheRead: Int64(140_000 + i * 100)), into: &acc)
        }
        let preCtx = acc.turnCosts.last!

        // Compaction is the newest record: reclaim must render pending.
        SessionScanner.claudeFold(line: compactionMarker(), into: &acc)
        precondition(acc.compactionCount == 1)
        precondition(acc.lastCompactionPreCtx == preCtx, "pre must be the last non-sidechain record before the marker")
        precondition(acc.lastCompactionPostCtx == nil, "reclaim must be pending — never 0, never 100% — with no post record yet")
        precondition(acc.turnCosts.isEmpty, "isCompactSummary must reset the xFloor baseline/live window")

        // Post-compaction usage arrives: reclaim pairs off, baseline restarts.
        SessionScanner.claudeFold(line: usageLine(id: "post0", cacheRead: 52_295), into: &acc)
        precondition(acc.lastCompactionPostCtx == 52_295 + 2)
        precondition(acc.turnCosts.count == 1, "the post-compaction turn must (re)start the window")
    }

    // MARK: sidechain exclusion — least-verified path, now abundant in practice

    private static func testSidechainExclusion() {
        var acc = TranscriptReader.Acc()
        SessionScanner.claudeFold(line: usageLine(id: "main1", cacheRead: 10_000), into: &acc)
        let rawBefore = acc.rawInputTokens
        let turnsBefore = acc.turnCosts.count
        let ctxBefore = acc.contextTokens

        SessionScanner.claudeFold(line: usageLine(id: "side1", cacheRead: 500_000, sidechain: true), into: &acc)
        precondition(acc.rawInputTokens == rawBefore + 500_000 + 2, "sidechain usage bills into raw totals")
        precondition(acc.turnCosts.count == turnsBefore, "sidechain must not enter turn counts / xFloor windows")
        precondition(acc.contextTokens == ctxBefore, "sidechain must not leak into contextPercent")
    }

    // MARK: window resolution — both suffix forms, fall-through, observed upgrade

    private static func testWindowResolution() {
        precondition(SessionScanner.modelVariant(parsing: "opus[1m]").window == 1_000_000)
        precondition(SessionScanner.modelVariant(parsing: "claude-opus-5[1m]").window == 1_000_000)
        precondition(SessionScanner.modelVariant(parsing: "opus").window == 200_000)
        precondition(SessionScanner.modelVariant(parsing: "opus[2m]").window == 200_000,
                     "unknown suffix must fall through to the base default, not crash or invent a number")
        precondition(SessionScanner.modelVariant(parsing: "banana[1m]").window == nil,
                     "unknown base must yield no window")
        precondition(SessionScanner.modelVariant(parsing: "claude-haiku-4-5-20251001").window == 200_000)

        precondition(SessionScanner.contextWindow(settingsModel: "opus[1m]", resolvedModel: nil, base: nil, observedCtx: nil) == 1_000_000)
        precondition(SessionScanner.contextWindow(settingsModel: nil, resolvedModel: "claude-opus-5[1m]", base: nil, observedCtx: nil) == 1_000_000)
        precondition(SessionScanner.contextWindow(settingsModel: nil, resolvedModel: nil, base: nil, observedCtx: 419_190) == 1_000_000,
                     "observed-usage upgrade must self-correct an otherwise-unresolved window")
        precondition(SessionScanner.contextWindow(settingsModel: nil, resolvedModel: nil, base: "unknownmodel", observedCtx: 50_000) == nil,
                     "no bar beats a fabricated denominator")
    }

    // MARK: cwd encoding

    private static func testPathEncoding() {
        precondition(PathEncoding.encode(cwd: "/Users/alex/.ade/agents/X/worktree")
                     == "-Users-alex--ade-agents-X-worktree")
        precondition(PathEncoding.encode(cwd: "/Users/git/sqlmesh") == "-Users-git-sqlmesh")
    }

    // MARK: `ps` line parsing

    private static func testProcessScannerParsing() {
        // Real `ps -axo pid=,state=,lstart=,comm=` shapes: a stopped process,
        // a running one, and a comm containing spaces and parentheses.
        let sample = " 9123 T    Sat Aug  8 10:32:27 2026     /Users/alex/.local/bin/claude\n"
                   + "45210 S+   Tue Aug 11 07:57:58 2026     claude\n"
                   + "  777 R    Tue Aug 11 07:57:58 2026     Claude Helper (Renderer)"
        let parsed = ProcessScanner.parse(psOutput: sample)
        precondition(parsed.count == 3)
        precondition(parsed[0].pid == 9123)
        precondition(parsed[0].isStopped, "state T must read as stopped")
        precondition(parsed[1].pid == 45210)
        precondition(!parsed[1].isStopped)
        precondition(parsed[2].comm == "Claude Helper (Renderer)",
                     "comm is the greedy final group — spaces and parens must survive")
        precondition(parsed[1].comm == "claude")
    }

    // MARK: liveness — kill(pid,0), start-time match, correction 1 (UTC vs local)

    private static func testLiveness() {
        let now = Date()
        let ownPid = getpid()
        let selfProc = ProcInfo(pid: ownPid, state: "S+", startedLocal: now, comm: "claude")

        precondition(Liveness.isAlive(pid: ownPid, startedAtMs: Int64(now.timeIntervalSince1970 * 1000),
                                       procStart: nil, process: selfProc),
                     "a genuinely live PID with a matching startedAt must pass")

        let farPastMs = Int64(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        precondition(!Liveness.isAlive(pid: ownPid, startedAtMs: farPastMs, procStart: nil, process: selfProc),
                     "a start-time mismatch (PID reuse) must discard the mapping even for a live PID")

        let deadTask = Process()
        deadTask.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try! deadTask.run()
        deadTask.waitUntilExit()
        let deadPid = deadTask.processIdentifier
        precondition(!Liveness.isAlive(pid: deadPid, startedAtMs: Int64(now.timeIntervalSince1970 * 1000),
                                        procStart: nil, process: ProcInfo(pid: deadPid, state: "S+", startedLocal: now, comm: "claude")),
                     "a dead PID must be filtered even if the claimed start time lines up")

        // Correction 1: procStart is UTC, ps lstart is local. Build both
        // strings from the *same* instant so this test is machine-agnostic —
        // on this dev box (BST) the raw strings genuinely differ by an hour.
        let instant = Date()
        let utcString = ProcessTime.format(instant, timeZone: TimeZone(identifier: "UTC")!)
        let localString = ProcessTime.format(instant, timeZone: .current)
        let proc = ProcInfo(pid: ownPid, state: "S+", startedLocal: ProcessTime.parseLocal(localString)!, comm: "claude")
        precondition(Liveness.isAlive(pid: ownPid, startedAtMs: nil, procStart: utcString, process: proc),
                     "correction 1: a naive string compare of UTC procStart vs local lstart would reject every " +
                     "live session — the parsed-instant compare must still match")
    }

    private static func testSuspension() {
        precondition(Suspension.isBusy(status: "busy", processStopped: false))
        precondition(!Suspension.isBusy(status: "busy", processStopped: true),
                     "a SIGSTOPed process is not busy however recent its registry status")
        precondition(!Suspension.isBusy(status: "idle", processStopped: false))

        // The regression this replaced: a session on one long turn stops
        // rewriting its registry file, so age alone cannot distinguish it
        // from a suspended process. Registry age must not enter into it.
        precondition(Suspension.isBusy(status: "busy", processStopped: false),
                     "a busy session mid-long-turn stays busy no matter how stale its registry file is")

        // ps state codes: the leading letter decides, trailing flags don't.
        precondition(ProcInfo(pid: 1, state: "T", startedLocal: Date(), comm: "claude").isStopped)
        precondition(!ProcInfo(pid: 1, state: "S+", startedLocal: Date(), comm: "claude").isStopped)
        precondition(!ProcInfo(pid: 1, state: "R", startedLocal: Date(), comm: "claude").isStopped)
    }

    // MARK: worse-of-two severity, no-usage state

    private static func testSeverityAndNoUsage() {
        precondition(SessionScanner.severity(multiple: nil, contextPercent: nil) == .green)
        precondition(SessionScanner.severity(multiple: 1.0, contextPercent: nil) == .green)
        precondition(SessionScanner.severity(multiple: 6.0, contextPercent: 10) == .orange)
        // Heavy-start blind spot: a huge baseline pins the multiple near
        // 1.0x forever, but a near-full context must still win — aligned
        // with the app's existing 80/95 RAG mapping (Format.color).
        precondition(SessionScanner.severity(multiple: 1.0, contextPercent: 96) == .red,
                     "worse-of-two must catch a heavy-start session the multiple alone would miss")

        var acc = TranscriptReader.Acc()
        SessionScanner.claudeFold(line: #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"hi"}}"#,
                                   into: &acc)
        precondition(acc.contextTokens == nil, "no assistant usage yet must read as no-usage, not zero")
        precondition(acc.turnCosts.isEmpty)
    }

    // MARK: incremental read — append, mid-line truncation, shrink

    private static func testIncrementalRead() {
        let sem = DispatchSemaphore(value: 0)
        Task {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sessions-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("t.jsonl")
            let reader = TranscriptReader()

            let l1 = usageLine(id: "a", cacheRead: 10_000)
            let l2 = usageLine(id: "b", cacheRead: 20_000)
            let l3 = usageLine(id: "c", cacheRead: 30_000)
            try? (l1 + "\n" + l2 + "\n").write(to: file, atomically: true, encoding: .utf8)

            var acc = await reader.scan(file)
            precondition(acc.turnCosts.count == 2)

            // Re-scanning an unchanged file must be a no-op reuse.
            let unchanged = await reader.scan(file)
            precondition(unchanged.byteOffset == acc.byteOffset && unchanged.turnCosts.count == acc.turnCosts.count)

            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write((l3 + "\n").data(using: .utf8)!)
                try? handle.close()
            }
            acc = await reader.scan(file)
            precondition(acc.turnCosts.count == 3, "growth must fold only the appended bytes")
            precondition(acc.turnCosts == [10_000 + 2, 20_000 + 2, 30_000 + 2])

            var fresh = TranscriptReader.Acc()
            for l in [l1, l2, l3] { SessionScanner.claudeFold(line: l, into: &fresh) }
            precondition(fresh.turnCosts == acc.turnCosts, "incremental result must equal a from-scratch parse")
            precondition(fresh.rawInputTokens == acc.rawInputTokens)
            precondition(SessionScanner.xFloor(turnCosts: fresh.turnCosts) == SessionScanner.xFloor(turnCosts: acc.turnCosts))

            // Mid-line truncation: a trailing partial line (built at runtime
            // by slicing a complete fixture, so the source text itself stays
            // balanced) must not be folded until its newline lands.
            let full4 = usageLine(id: "d", cacheRead: 40_000)
            let partial = String(full4.prefix(20))
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(partial.data(using: .utf8)!)
                try? handle.close()
            }
            acc = await reader.scan(file)
            precondition(acc.turnCosts.count == 3, "a partial line without its newline must not be folded yet")

            let rest = String(full4.dropFirst(20))
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write((rest + "\n").data(using: .utf8)!)
                try? handle.close()
            }
            acc = await reader.scan(file)
            precondition(acc.turnCosts.count == 4, "completing the line must fold it exactly once")

            // Shrink: discard and re-read from zero.
            try? (l1 + "\n").write(to: file, atomically: true, encoding: .utf8)
            acc = await reader.scan(file)
            precondition(acc.turnCosts.count == 1, "a shrunk file must be discarded and re-read from zero")

            try? FileManager.default.removeItem(at: dir)
            sem.signal()
        }
        sem.wait()
    }

    // MARK: liveSessions end-to-end with injected fixture directories

    private static func testLiveSessionsEndToEnd() {
        let sem = DispatchSemaphore(value: 0)
        Task {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sessions-e2e-\(UUID().uuidString)")
            let mappingDir = root.appendingPathComponent("sessions")
            let projectsDir = root.appendingPathComponent("projects")
            try? FileManager.default.createDirectory(at: mappingDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

            let cwd = root.appendingPathComponent("proj").path
            let sessionId = "e2e-session"
            let encoded = PathEncoding.encode(cwd: cwd)
            let projectDir = projectsDir.appendingPathComponent(encoded)
            try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let transcript = projectDir.appendingPathComponent("\(sessionId).jsonl")

            var lines: [String] = []
            for i in 0..<6 { lines.append(usageLine(id: "e2e\(i)", cacheRead: Int64(100_000 + i * 5_000))) }
            try? (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

            let ownPid = getpid()
            let now = Date()
            let registry: [String: Any] = [
                "pid": Int(ownPid), "sessionId": sessionId, "cwd": cwd,
                "startedAt": Int(now.timeIntervalSince1970 * 1000),
                "status": "busy", "statusUpdatedAt": Int(now.timeIntervalSince1970 * 1000),
                "name": "e2e-test",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: registry) {
                try? data.write(to: mappingDir.appendingPathComponent("\(ownPid).json"))
            }

            // A dead-PID registry file must be filtered, not crash the scan.
            let deadTask = Process()
            deadTask.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try! deadTask.run()
            deadTask.waitUntilExit()
            let deadPid = deadTask.processIdentifier
            var deadRegistry = registry
            deadRegistry["pid"] = Int(deadPid)
            deadRegistry["sessionId"] = "dead-session"
            if let deadData = try? JSONSerialization.data(withJSONObject: deadRegistry) {
                try? deadData.write(to: mappingDir.appendingPathComponent("\(deadPid).json"))
            }

            let processList = [ProcInfo(pid: ownPid, state: "S+", startedLocal: now, comm: "claude")]
            let sessions = await SessionScanner.liveSessions(
                processList: processList, mappingDir: mappingDir, projectsDir: projectsDir,
                userSettingsPath: root.appendingPathComponent("nonexistent-settings.json"),
                reader: TranscriptReader()
            )
            precondition(sessions.count == 1, "only the live PID's session must survive — got \(sessions.count)")
            precondition(sessions[0].pid == ownPid)
            precondition(sessions[0].label == "e2e-test")
            precondition(sessions[0].turns == 6)
            precondition(sessions[0].xFloorMultiple != nil)
            precondition(sessions[0].busy == true)

            try? FileManager.default.removeItem(at: root)
            sem.signal()
        }
        sem.wait()
    }
}
