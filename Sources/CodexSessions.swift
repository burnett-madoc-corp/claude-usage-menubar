import Darwin
import Foundation
import SQLite3

// MARK: - JSON helpers
//
// Sessions.swift declares an equivalent extension, but `private` on a
// top-level extension is file-scoped in Swift — it is not visible here even
// though both files compile into the same target. Redeclared rather than
// widening the other file's access, to keep this phase's diff isolated.

private extension Dictionary where Key == String, Value == Any {
    func int64(_ key: String) -> Int64? { (self[key] as? NSNumber)?.int64Value }
    func string(_ key: String) -> String? { self[key] as? String }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
}

// MARK: - state_*.sqlite discovery and read-only access
//
// Read-only, non-negotiable: `state_N.sqlite` is a live WAL-mode database
// owned a running `codex` process. We open it with SQLITE_OPEN_READONLY
// only, never touch -wal/-shm directly, and treat any open/prepare failure
// (locked mid-checkpoint, missing table, schema drift after a codex
// upgrade) as "codex sessions unavailable this cycle" rather than crashing
// or blocking Claude session rendering.

struct CodexThread: Sendable, Equatable {
    var id: String
    var rolloutPath: String
    var cwd: String?
    var model: String?
    var createdAtMs: Int64?
    var updatedAtMs: Int64?
    var archived: Bool
    var hasUserEvent: Bool
    var tokensUsed: Int64?
    var agentNickname: String?
}

enum CodexDB {
    private static let filenameRegex = try! NSRegularExpression(pattern: #"^state_(\d+)\.sqlite$"#)

    /// The state DB filename is versioned across codex releases (verified
    /// siblings: logs_2, goals_1, queue_1) — glob for the newest, never
    /// hardcode a version number.
    static func newestStateDB(in dir: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }

        var best: (url: URL, version: Int)?
        for file in files {
            let name = file.lastPathComponent
            let full = NSRange(name.startIndex..., in: name)
            guard let match = filenameRegex.firstMatch(in: name, range: full),
                  let versionRange = Range(match.range(at: 1), in: name),
                  let version = Int(name[versionRange])
            else { continue }
            if best == nil || version > best!.version { best = (file, version) }
        }
        return best?.url
    }

    /// Only the columns this feature needs. A missing table or column
    /// (schema drift) makes `sqlite3_prepare_v2` fail — surfaced as `nil`
    /// ("unavailable"), not a crash.
    static func threads(dbPath: URL) -> [CodexThread]? {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, rollout_path, cwd, model, created_at_ms, updated_at_ms, archived, has_user_event, tokens_used, agent_nickname
        FROM threads WHERE archived = 0
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var results: [CodexThread] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = columnText(stmt, 0), let rolloutPath = columnText(stmt, 1) else { continue }
            results.append(CodexThread(
                id: id,
                rolloutPath: rolloutPath,
                cwd: columnText(stmt, 2),
                model: columnText(stmt, 3),
                createdAtMs: columnInt64(stmt, 4),
                updatedAtMs: columnInt64(stmt, 5),
                archived: (columnInt64(stmt, 6) ?? 0) != 0,
                hasUserEvent: (columnInt64(stmt, 7) ?? 0) != 0,
                tokensUsed: columnInt64(stmt, 8),
                agentNickname: columnText(stmt, 9)
            ))
        }
        return results
    }

    private static func columnText(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL, let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private static func columnInt64(_ stmt: OpaquePointer, _ idx: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, idx)
    }
}

// MARK: - Live codex process discovery
//
// The fd-open approach is dead (rollouts are append-and-close, verified —
// see the plan). A live codex runs as two processes: a `node` wrapper and
// the real binary under `.../codex-darwin-arm64/.../codex`. Neither `ps`
// nor the registry files Claude has exist for codex, so cwd comes from
// `lsof` — bounded to the handful of live codex PIDs found.

struct CodexProcess: Sendable, Equatable {
    var pid: pid_t
    var startedLocal: Date
    var cwd: String
    var isRealBinary: Bool
}

struct RawProcCandidate: Sendable, Equatable {
    var pid: pid_t
    var startedLocal: Date
    var command: String
}

enum CwdLookup {
    /// Pure parser for `lsof -a -p <pid> -d cwd -Fn` field output: a line
    /// beginning `n` carries the path.
    static func parse(lsofOutput: String) -> String? {
        for line in lsofOutput.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    static func cwd(pid: pid_t) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parse(lsofOutput: String(decoding: data, as: UTF8.self))
    }
}

enum CodexProcessScanner {
    // pid, then a fixed 24-char `lstart` (ctime-style, day space-padded),
    // then the full command (greedy final group — the real binary's path is
    // long and the node wrapper's argv contains spaces).
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^\s*(\d+)\s+(\w{3}\s+\w{3}\s+[\d ]\d\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.+)$"#
    )

    /// Pure parser for `ps -axo pid=,lstart=,command=` output.
    static func parse(psOutput: String) -> [RawProcCandidate] {
        var result: [RawProcCandidate] = []
        for substring in psOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(substring)
            let full = NSRange(line.startIndex..., in: line)
            guard let match = lineRegex.firstMatch(in: line, range: full),
                  let pidRange = Range(match.range(at: 1), in: line),
                  let lstartRange = Range(match.range(at: 2), in: line),
                  let commandRange = Range(match.range(at: 3), in: line),
                  let pid = pid_t(line[pidRange]),
                  let started = ProcessTime.parseLocal(String(line[lstartRange]))
            else { continue }
            result.append(RawProcCandidate(pid: pid, startedLocal: started, command: String(line[commandRange])))
        }
        return result
    }

    static func isCodexCommand(_ command: String) -> Bool { command.contains("codex") }
    static func isRealBinary(_ command: String) -> Bool { command.contains("codex-darwin-arm64") }

    /// A live codex is two processes sharing the same start second and cwd
    /// (the node wrapper's fork/exec of the real binary) — dedupe to one,
    /// preferring the real binary's pid.
    static func dedupe(_ processes: [CodexProcess]) -> [CodexProcess] {
        var seen: [String: CodexProcess] = [:]
        for p in processes {
            let key = "\(p.cwd)|\(p.startedLocal.timeIntervalSince1970)"
            if let existing = seen[key] {
                if p.isRealBinary && !existing.isRealBinary { seen[key] = p }
            } else {
                seen[key] = p
            }
        }
        return Array(seen.values)
    }

    /// Real IO: `ps` for candidates, `lsof` for each candidate's cwd
    /// (bounded — usually zero or one live codex). UNVERIFIED against a
    /// live codex process on this machine (none was running while this was
    /// built) — exercised only by injected fixtures in self-tests.
    static func run() -> [CodexProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,lstart=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let candidates = parse(psOutput: String(decoding: data, as: UTF8.self))
            .filter { isCodexCommand($0.command) }

        let withCwd: [CodexProcess] = candidates.compactMap { c in
            guard let cwd = CwdLookup.cwd(pid: c.pid) else { return nil }
            return CodexProcess(pid: c.pid, startedLocal: c.startedLocal, cwd: cwd, isRealBinary: isRealBinary(c.command))
        }
        return dedupe(withCwd)
    }
}

// MARK: - PID -> thread matching

enum CodexMatcher {
    /// Verified: process start vs `threads.created_at_ms` observed ~1s
    /// apart; ±5s gives headroom without reaching into plausible
    /// distinct-session gaps.
    static let tolerance: TimeInterval = 5

    struct Match: Sendable {
        var process: CodexProcess
        var thread: CodexThread?
        /// Two-or-more threads matched the same process within tolerance,
        /// same cwd — genuinely ambiguous. Both are rendered, both flagged,
        /// rather than silently guessing.
        var ambiguous: Bool = false
        /// No thread matched within the time tolerance, but a non-archived
        /// thread with the same cwd exists (most likely `codex resume`) —
        /// shown with its data as a labelled best guess, not silently.
        var viaFallback: Bool = false
    }

    static func match(processes: [CodexProcess], threads: [CodexThread]) -> [Match] {
        var results: [Match] = []
        for proc in CodexProcessScanner.dedupe(processes) {
            let sameCwd = threads.filter { !$0.archived && $0.cwd == proc.cwd }
            let withinTolerance = sameCwd.filter { thread in
                guard let ms = thread.createdAtMs else { return false }
                let created = Date(timeIntervalSince1970: Double(ms) / 1000)
                return abs(created.timeIntervalSince(proc.startedLocal)) <= tolerance
            }

            if withinTolerance.count == 1 {
                results.append(Match(process: proc, thread: withinTolerance[0]))
            } else if withinTolerance.count > 1 {
                // Tie-break by preferring larger updated_at_ms for ordering,
                // but mark every candidate ambiguous rather than guessing.
                let sorted = withinTolerance.sorted { ($0.updatedAtMs ?? 0) > ($1.updatedAtMs ?? 0) }
                for thread in sorted {
                    results.append(Match(process: proc, thread: thread, ambiguous: true))
                }
            } else if let newest = sameCwd.sorted(by: { ($0.updatedAtMs ?? 0) > ($1.updatedAtMs ?? 0) }).first {
                results.append(Match(process: proc, thread: newest, viaFallback: true))
            } else {
                // No threads row at all for this cwd yet — lazy row
                // creation (verified: no row before the first user turn).
                results.append(Match(process: proc, thread: nil))
            }
        }
        return results
    }
}

// MARK: - Incremental rollout reader
//
// Mirrors TranscriptReader's byte-offset/accumulator/shrink-discard design
// (Sessions.swift) rather than sharing its type — the accumulated fields are
// Codex-specific (token_count/session_meta/turn_context, not Claude's
// usage/compaction shape) and Claude's reader must not change shape for this
// phase. Rollouts run to ~5MB; re-scans while the menu is open fold only
// appended bytes.

actor CodexRolloutReader {
    static let shared = CodexRolloutReader()

    struct Acc: Sendable {
        var byteOffset: UInt64 = 0
        var partialTail: Data = Data()

        var cwd: String?
        var model: String?              // newest turn_context.payload.model
        var agentNickname: String?      // session_meta subagent labelling
        var sessionContextWindow: Int64? // session_meta.payload.context_window fallback, when numeric

        var lastTokenCount: (total: Int64, window: Int64?)?
        var totalUsage: (input: Int64, output: Int64)?
        var hasTokenCountEvent: Bool = false
    }

    private var accumulators: [String: Acc] = [:]

    /// Same unbounded-growth trap as TranscriptReader's, in a sibling file:
    /// without this, every rollout ever scanned keeps its accumulator for the
    /// life of the process, and this is a menu-bar app expected to run for
    /// weeks. Called once per scan cycle with the paths still live.
    func evictAccumulators(keeping livePaths: Set<String>) {
        accumulators = accumulators.filter { livePaths.contains($0.key) }
    }

    /// Test-only visibility, mirroring TranscriptReader.accumulatorCount.
    var accumulatorCount: Int { accumulators.count }

    @discardableResult
    func scan(_ url: URL) -> Acc {
        let key = url.path
        var acc = accumulators[key] ?? Acc()

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attrs?[.size] as? NSNumber)?.uint64Value else {
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
            CodexRolloutParsing.fold(line: String(decoding: lineData, as: UTF8.self), into: &acc)
            searchStart = combined.index(after: nlIndex)
        }
        acc.partialTail = Data(combined[searchStart...])
        acc.byteOffset = size

        accumulators[key] = acc
        return acc
    }
}

// MARK: - Rollout line parsing

enum CodexRolloutParsing {
    /// Correction: the nickname lives one level deeper than the plan
    /// documents — `payload.source.subagent.thread_spawn.agent_nickname` —
    /// with a convenience duplicate at top-level `payload.agent_nickname`.
    /// Verified live on this machine (both present, identical values); the
    /// top-level one is simpler and preferred.
    static func subagentNickname(payload: [String: Any]) -> String? {
        if let nickname = payload.string("agent_nickname") { return nickname }
        if let nickname = payload.dict("source")?.dict("subagent")?.dict("thread_spawn")?.string("agent_nickname") {
            return nickname
        }
        return nil
    }

    /// Folds one rollout JSONL line into the running accumulator. Pure and
    /// synchronous so self-tests can drive it directly with literal fixture
    /// lines. `compacted` is a top-level record type (verified — NOT an
    /// event_msg subtype as the plan implies) and is explicitly a no-op
    /// here: Codex's own `token_count` self-corrects across a compaction,
    /// so there is no Codex-side compaction metric in v1.
    static func fold(line: String, into acc: inout CodexRolloutReader.Acc) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj.string("type")
        else { return }

        switch type {
        case "session_meta":
            guard let payload = obj.dict("payload") else { return }
            if let cwd = payload.string("cwd") { acc.cwd = cwd }
            // Verified live on this machine: `context_window` here is an
            // object (`{"window_id": "…"}`), not the numeric fallback the
            // task's corrections describe — so this only ever fires if a
            // future codex build changes the shape. Harmless either way:
            // `.int64` returns nil on a non-numeric value, never crashes.
            if let window = payload.int64("context_window") { acc.sessionContextWindow = window }
            if let nickname = subagentNickname(payload: payload) { acc.agentNickname = nickname }

        case "turn_context":
            if let model = obj.dict("payload")?.string("model") { acc.model = model }

        case "event_msg":
            guard let payload = obj.dict("payload"), payload.string("type") == "token_count",
                  let info = payload.dict("info")
            else { return }
            acc.hasTokenCountEvent = true
            if let last = info.dict("last_token_usage"), let total = last.int64("total_tokens") {
                acc.lastTokenCount = (total: total, window: info.int64("model_context_window"))
            }
            if let usage = info.dict("total_token_usage") {
                acc.totalUsage = (input: usage.int64("input_tokens") ?? 0, output: usage.int64("output_tokens") ?? 0)
            }

        default:
            return   // includes "compacted" — explicitly ignored, see doc comment
        }
    }
}

// MARK: - Assembling AgentSession

enum CodexSessionScanner {
    static func liveSessions(
        processes: [CodexProcess],
        threads: [CodexThread],
        reader: CodexRolloutReader = .shared
    ) async -> [AgentSession] {
        var sessions: [AgentSession] = []
        var scannedPaths: Set<String> = []
        for match in CodexMatcher.match(processes: processes, threads: threads) {
            guard let thread = match.thread else {
                // Live PID, no threads row yet — lazy row creation, verified
                // to persist even after a completed turn. Must still
                // render: unknown usage, never dropped, never 0%.
                sessions.append(AgentSession(
                    kind: .codex, pid: match.process.pid,
                    label: PathEncoding.label(cwd: match.process.cwd),
                    cwd: match.process.cwd, model: nil, busy: true,
                    turns: 0, inputTokens: 0, outputTokens: 0,
                    subagentTokens: nil, contextTokens: nil, contextWindow: nil,
                    xFloorMultiple: nil, compactionCount: 0,
                    lastCompactionAt: nil, lastCompactionPreCtx: nil, lastCompactionPostCtx: nil,
                    hasUsage: false
                ))
                continue
            }

            scannedPaths.insert(thread.rolloutPath)
            let acc = await reader.scan(URL(fileURLWithPath: thread.rolloutPath))
            let cwd = thread.cwd ?? acc.cwd ?? match.process.cwd
            var label = thread.agentNickname ?? acc.agentNickname ?? PathEncoding.label(cwd: cwd)
            if match.ambiguous { label += " (?)" }
            else if match.viaFallback { label += " (unmatched)" }

            sessions.append(AgentSession(
                kind: .codex,
                pid: match.process.pid,
                label: label,
                cwd: cwd,
                model: acc.model ?? thread.model,
                busy: true,
                turns: 0,   // Codex has no per-turn/xFloor metric in v1 — see plan
                inputTokens: acc.totalUsage?.input ?? 0,
                outputTokens: acc.totalUsage?.output ?? 0,
                subagentTokens: nil,
                // Pending is not zero: no token_count event yet (verified to
                // persist even after a completed turn) must read as unknown,
                // never a fabricated 0%.
                contextTokens: acc.hasTokenCountEvent ? acc.lastTokenCount?.total : nil,
                contextWindow: acc.lastTokenCount?.window ?? acc.sessionContextWindow,
                xFloorMultiple: nil,
                compactionCount: 0,
                lastCompactionAt: nil, lastCompactionPreCtx: nil, lastCompactionPostCtx: nil,
                hasUsage: acc.hasTokenCountEvent
            ))
        }
        await reader.evictAccumulators(keeping: scannedPaths)
        return sessions.sorted { $0.label < $1.label }
    }
}

// MARK: - Entry point for Sessions.swift

enum CodexSessions {
    /// Any failure here (DB missing/locked/schema-drifted) degrades to "no
    /// codex sessions this cycle" — never blocks Claude session rendering,
    /// never crashes.
    static func snapshot() async -> [AgentSession] {
        let codexDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let dbURL = CodexDB.newestStateDB(in: codexDir),
              let threads = CodexDB.threads(dbPath: dbURL)
        else { return [] }
        let processes = CodexProcessScanner.run()
        guard !processes.isEmpty else { return [] }
        return await CodexSessionScanner.liveSessions(processes: processes, threads: threads)
    }
}

// MARK: - Self-tests

enum CodexSessionSelfTests {
    static func run() {
        testNewestStateDBGlob()
        testFixtureDBParsing()
        testFixtureDBMissingColumn()
        testFixtureDBAbsentFile()
        testTokenCountExtraction()
        testTotalTokenUsageParsing()
        testSubagentNicknameCorrectedNesting()
        testPendingVsZero()
        testCompactedTopLevelIgnored()
        testProcessScannerParsing()
        testCwdLookupParsing()
        testDedupeNodeWrapperVsRealBinary()
        testMatchWithinTolerance()
        testMatchOutOfToleranceFallback()
        testMatchAmbiguousTieBreak()
        testMatchPendingNoThreadsRow()
        testCompactTokenFormatter()
        testIncrementalRolloutRead()
        testLiveSessionsEndToEndPending()
    }

    // MARK: state DB glob

    private static func testNewestStateDBGlob() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-glob-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["state_3.sqlite", "state_10.sqlite", "state_5.sqlite", "state_x.sqlite", "logs_2.sqlite"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        let newest = CodexDB.newestStateDB(in: dir)
        precondition(newest?.lastPathComponent == "state_10.sqlite",
                     "must glob for the newest state_*.sqlite, never hardcode a version — got \(String(describing: newest))")
    }

    // MARK: fixture SQLite DB — schema-drift and absent-file cases

    private static func makeFixtureDB(at url: URL, withAgentNicknameColumn: Bool) {
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        defer { sqlite3_close(db) }
        let baseColumns = "id TEXT, rollout_path TEXT, cwd TEXT, model TEXT, created_at_ms INTEGER, " +
            "updated_at_ms INTEGER, archived INTEGER, has_user_event INTEGER, tokens_used INTEGER"
        let columns = withAgentNicknameColumn ? baseColumns + ", agent_nickname TEXT" : baseColumns
        sqlite3_exec(db, "CREATE TABLE threads (\(columns))", nil, nil, nil)

        var insertCols = "id, rollout_path, cwd, model, created_at_ms, updated_at_ms, archived, has_user_event, tokens_used"
        var values = "'t1','/tmp/r1.jsonl','/Users/alex/proj','gpt-5.6-sol',1786476383923,1786477701299,0,1,500"
        if withAgentNicknameColumn {
            insertCols += ", agent_nickname"
            values += ",'Nash'"
        }
        sqlite3_exec(db, "INSERT INTO threads (\(insertCols)) VALUES (\(values))", nil, nil, nil)
    }

    private static func testFixtureDBParsing() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-db-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("state_5.sqlite")
        makeFixtureDB(at: dbURL, withAgentNicknameColumn: true)

        let threads = CodexDB.threads(dbPath: dbURL)
        precondition(threads != nil, "correct schema must parse")
        precondition(threads!.count == 1)
        precondition(threads![0].id == "t1")
        precondition(threads![0].cwd == "/Users/alex/proj")
        precondition(threads![0].model == "gpt-5.6-sol")
        precondition(threads![0].agentNickname == "Nash")
        precondition(threads![0].hasUserEvent == true)
        precondition(threads![0].archived == false)
    }

    private static func testFixtureDBMissingColumn() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-db-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("state_5.sqlite")
        makeFixtureDB(at: dbURL, withAgentNicknameColumn: false)

        precondition(CodexDB.threads(dbPath: dbURL) == nil,
                     "a threads table missing a queried column must yield unavailable (nil), not crash")
    }

    private static func testFixtureDBAbsentFile() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-db-\(UUID().uuidString)/does-not-exist.sqlite")
        precondition(CodexDB.threads(dbPath: missing) == nil, "an absent file must yield unavailable, not crash")
    }

    // MARK: rollout fixture lines

    private static func sessionMetaLine(cwd: String = "/Users/alex", nicknameTopLevel: String? = nil,
                                         nicknameNestedOnly: String? = nil) -> String {
        var payload: [String: Any] = ["session_id": "s1", "id": "s1", "cwd": cwd, "originator": "codex-tui",
                                       "cli_version": "0.147.0", "thread_source": "user",
                                       "model_provider": "openai", "history_mode": "legacy"]
        if let nicknameTopLevel {
            payload["agent_nickname"] = nicknameTopLevel
            payload["thread_source"] = "subagent"
        }
        if let nicknameNestedOnly {
            payload["source"] = ["subagent": ["thread_spawn": ["agent_nickname": nicknameNestedOnly, "depth": 1]]]
            payload["thread_source"] = "subagent"
        }
        let data = try! JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": payload])
        return String(decoding: data, as: UTF8.self)
    }

    private static func turnContextLine(model: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "turn_context", "payload": ["model": model]])
        return String(decoding: data, as: UTF8.self)
    }

    private static func tokenCountLine(lastTotal: Int64, window: Int64, cumIn: Int64, cumOut: Int64) -> String {
        let payload: [String: Any] = [
            "type": "token_count",
            "info": [
                "last_token_usage": ["total_tokens": lastTotal],
                "total_token_usage": ["input_tokens": cumIn, "output_tokens": cumOut,
                                       "cache_write_input_tokens": 0, "total_tokens": cumIn + cumOut],
                "model_context_window": window,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": payload])
        return String(decoding: data, as: UTF8.self)
    }

    private static func compactedLine() -> String {
        let payload: [String: Any] = ["message": "", "replacement_history": []]
        let data = try! JSONSerialization.data(withJSONObject: ["type": "compacted", "payload": payload])
        return String(decoding: data, as: UTF8.self)
    }

    private static func testTokenCountExtraction() {
        var acc = CodexRolloutReader.Acc()
        CodexRolloutParsing.fold(line: tokenCountLine(lastTotal: 71_797, window: 258_400, cumIn: 26_575_483, cumOut: 59_122), into: &acc)
        precondition(acc.hasTokenCountEvent)
        precondition(acc.lastTokenCount?.total == 71_797)
        precondition(acc.lastTokenCount?.window == 258_400, "model_context_window must come from the newest token_count event")
    }

    private static func testTotalTokenUsageParsing() {
        var acc = CodexRolloutReader.Acc()
        CodexRolloutParsing.fold(line: tokenCountLine(lastTotal: 1_000, window: 258_400, cumIn: 26_575_483, cumOut: 59_122), into: &acc)
        precondition(acc.totalUsage?.input == 26_575_483)
        precondition(acc.totalUsage?.output == 59_122)
        // A second, newer event_msg must overwrite (newest wins), not sum.
        CodexRolloutParsing.fold(line: tokenCountLine(lastTotal: 2_000, window: 258_400, cumIn: 26_634_605, cumOut: 60_000), into: &acc)
        precondition(acc.totalUsage?.input == 26_634_605)
        precondition(acc.lastTokenCount?.total == 2_000)
    }

    private static func testSubagentNicknameCorrectedNesting() {
        // Corrected nesting: payload.source.subagent.thread_spawn.agent_nickname,
        // with a top-level convenience duplicate at payload.agent_nickname —
        // NOT payload.source.subagent.agent_nickname as originally documented.
        var acc = CodexRolloutReader.Acc()
        CodexRolloutParsing.fold(line: sessionMetaLine(nicknameTopLevel: "Nash"), into: &acc)
        precondition(acc.agentNickname == "Nash", "top-level payload.agent_nickname must be read")

        var accNestedOnly = CodexRolloutReader.Acc()
        CodexRolloutParsing.fold(line: sessionMetaLine(nicknameNestedOnly: "Linnaeus"), into: &accNestedOnly)
        precondition(accNestedOnly.agentNickname == "Linnaeus",
                     "must fall back to the corrected nested path source.subagent.thread_spawn.agent_nickname")

        let payloadOldNesting: [String: Any] = ["subagent": ["agent_nickname": "wrong-old-path"]]
        precondition(CodexRolloutParsing.subagentNickname(payload: ["source": payloadOldNesting]) == nil,
                     "the ORIGINAL documented path (source.subagent.agent_nickname, one level too shallow) must NOT match")
    }

    private static func testPendingVsZero() {
        // Verified real state: a completed turn (task_complete) with no
        // token_count event yet — tokens_used stays 0 in the DB too. Must
        // render as unknown ("context —"), never a fabricated 0%.
        var acc = CodexRolloutReader.Acc()
        CodexRolloutParsing.fold(line: sessionMetaLine(), into: &acc)
        CodexRolloutParsing.fold(line: turnContextLine(model: "gpt-5.6-sol"), into: &acc)
        let taskComplete = try! JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": ["type": "task_complete"]])
        CodexRolloutParsing.fold(line: String(decoding: taskComplete, as: UTF8.self), into: &acc)
        precondition(!acc.hasTokenCountEvent, "a completed turn without a token_count event must stay pending")
        precondition(acc.lastTokenCount == nil)
    }

    private static func testCompactedTopLevelIgnored() {
        // Correction: `compacted` is a TOP-LEVEL record type, not an
        // event_msg subtype — must not be mistaken for a token_count event
        // or crash the fold.
        var acc = CodexRolloutReader.Acc()
        CodexRolloutParsing.fold(line: tokenCountLine(lastTotal: 5_000, window: 258_400, cumIn: 10_000, cumOut: 500), into: &acc)
        CodexRolloutParsing.fold(line: compactedLine(), into: &acc)
        precondition(acc.hasTokenCountEvent, "compacted must not clear prior token_count state")
        precondition(acc.lastTokenCount?.total == 5_000, "compacted must not be misread as a new token_count event")
    }

    // MARK: process scanning / cwd lookup — pure parsers

    private static func testProcessScannerParsing() {
        let sample = "12345 Tue Aug 11 20:26:22 2026     /opt/homebrew/Cellar/node/23/bin/node /opt/homebrew/bin/codex\n"
                   + "12346 Tue Aug 11 20:26:22 2026     /Users/alex/.codex/bin/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex\n"
                   + "  999 Tue Aug 11 07:00:00 2026     /usr/bin/unrelated-process"
        let parsed = CodexProcessScanner.parse(psOutput: sample)
        precondition(parsed.count == 3)
        precondition(CodexProcessScanner.isCodexCommand(parsed[0].command))
        precondition(!CodexProcessScanner.isRealBinary(parsed[0].command), "the node wrapper is not the real binary")
        precondition(CodexProcessScanner.isCodexCommand(parsed[1].command))
        precondition(CodexProcessScanner.isRealBinary(parsed[1].command))
        precondition(!CodexProcessScanner.isCodexCommand(parsed[2].command), "an unrelated process must not match")
    }

    private static func testCwdLookupParsing() {
        let sample = "p12345\nfcwd\na \ntVDIR\nn/Users/alex/scratch/cumb-sessions\n"
        precondition(CwdLookup.parse(lsofOutput: sample) == "/Users/alex/scratch/cumb-sessions")
        precondition(CwdLookup.parse(lsofOutput: "") == nil, "no lsof output must yield nil, not crash")
    }

    // MARK: dedupe — node wrapper + real binary

    private static func testDedupeNodeWrapperVsRealBinary() {
        let started = Date()
        let wrapper = CodexProcess(pid: 100, startedLocal: started, cwd: "/Users/alex", isRealBinary: false)
        let real = CodexProcess(pid: 101, startedLocal: started, cwd: "/Users/alex", isRealBinary: true)
        let deduped = CodexProcessScanner.dedupe([wrapper, real])
        precondition(deduped.count == 1, "same start time + cwd must dedupe to one process")
        precondition(deduped[0].pid == 101, "the real binary must be preferred over the node wrapper")

        // Distinct cwd or start time must NOT collapse into one — two
        // genuinely separate live codex instances.
        let other = CodexProcess(pid: 200, startedLocal: started.addingTimeInterval(120), cwd: "/Users/alex", isRealBinary: true)
        precondition(CodexProcessScanner.dedupe([wrapper, real, other]).count == 2)
    }

    // MARK: PID -> thread matching

    private static func thread(id: String, cwd: String, createdAt: Date, updatedAt: Date? = nil,
                                archived: Bool = false) -> CodexThread {
        CodexThread(id: id, rolloutPath: "/tmp/\(id).jsonl", cwd: cwd, model: "gpt-5.6-sol",
                    createdAtMs: Int64(createdAt.timeIntervalSince1970 * 1000),
                    updatedAtMs: Int64((updatedAt ?? createdAt).timeIntervalSince1970 * 1000),
                    archived: archived, hasUserEvent: true, tokensUsed: 100, agentNickname: nil)
    }

    private static func testMatchWithinTolerance() {
        let started = Date()
        let proc = CodexProcess(pid: 1, startedLocal: started, cwd: "/Users/alex", isRealBinary: true)

        // Just inside ±5s.
        let inTol = thread(id: "in-tol", cwd: "/Users/alex", createdAt: started.addingTimeInterval(4.9))
        let matches = CodexMatcher.match(processes: [proc], threads: [inTol])
        precondition(matches.count == 1 && matches[0].thread?.id == "in-tol" && !matches[0].ambiguous && !matches[0].viaFallback,
                     "a thread 4.9s from process start, same cwd, must match confidently")
    }

    private static func testMatchOutOfToleranceFallback() {
        let started = Date()
        let proc = CodexProcess(pid: 1, startedLocal: started, cwd: "/Users/alex", isRealBinary: true)

        // 5.1s out of tolerance — a resumed session — but the cwd matches,
        // so it must fall back to a labelled best guess, not pending.
        let resumed = thread(id: "resumed", cwd: "/Users/alex", createdAt: started.addingTimeInterval(-3600),
                              updatedAt: started.addingTimeInterval(-10))
        let matches = CodexMatcher.match(processes: [proc], threads: [resumed])
        precondition(matches.count == 1)
        precondition(matches[0].thread?.id == "resumed")
        precondition(matches[0].viaFallback, "outside the ±5s tolerance with a cwd match must be the fallback case")
        precondition(!matches[0].ambiguous)
    }

    private static func testMatchAmbiguousTieBreak() {
        let started = Date()
        let proc = CodexProcess(pid: 1, startedLocal: started, cwd: "/Users/alex", isRealBinary: true)

        // Two threads, same second, same cwd — genuinely ambiguous.
        let a = thread(id: "a", cwd: "/Users/alex", createdAt: started.addingTimeInterval(1), updatedAt: started.addingTimeInterval(100))
        let b = thread(id: "b", cwd: "/Users/alex", createdAt: started.addingTimeInterval(-1), updatedAt: started.addingTimeInterval(50))
        let matches = CodexMatcher.match(processes: [proc], threads: [a, b])
        precondition(matches.count == 2, "both ambiguous candidates must be rendered, not silently collapsed to one")
        precondition(matches.allSatisfy(\.ambiguous), "both must be flagged ambiguous, not just one")
        precondition(matches[0].thread?.id == "a", "the larger updated_at_ms must be preferred/ordered first")
    }

    private static func testMatchPendingNoThreadsRow() {
        let proc = CodexProcess(pid: 1, startedLocal: Date(), cwd: "/Users/alex/fresh-project", isRealBinary: true)
        // No thread anywhere shares this cwd — lazy row creation, pre-first-turn.
        let unrelated = thread(id: "x", cwd: "/Users/somewhere/else", createdAt: Date())
        let matches = CodexMatcher.match(processes: [proc], threads: [unrelated])
        precondition(matches.count == 1)
        precondition(matches[0].thread == nil, "no cwd-matching thread at all must render as pending, not unmatched")
        precondition(!matches[0].ambiguous && !matches[0].viaFallback)

        // Archived threads must never be offered as matches even if cwd+time line up.
        let archived = thread(id: "arch", cwd: "/Users/alex/fresh-project", createdAt: proc.startedLocal, archived: true)
        let matchesArchived = CodexMatcher.match(processes: [proc], threads: [archived])
        precondition(matchesArchived[0].thread == nil, "an archived thread must not be matched")
    }

    // MARK: compact token formatter

    private static func testCompactTokenFormatter() {
        precondition(Format.tokens(1_234_567) == "1.2M")
        precondition(Format.tokens(45_000) == "45k")
        precondition(Format.tokens(999) == "999")
        precondition(Format.tokens(0) == "0")
    }

    // MARK: incremental rollout read

    private static func testIncrementalRolloutRead() {
        let sem = DispatchSemaphore(value: 0)
        Task {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("codex-rollout-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("rollout.jsonl")
            let reader = CodexRolloutReader()

            let l1 = tokenCountLine(lastTotal: 1_000, window: 258_400, cumIn: 1_000, cumOut: 100)
            try? (l1 + "\n").write(to: file, atomically: true, encoding: .utf8)

            var acc = await reader.scan(file)
            precondition(acc.lastTokenCount?.total == 1_000)

            let l2 = tokenCountLine(lastTotal: 2_000, window: 258_400, cumIn: 3_000, cumOut: 200)
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write((l2 + "\n").data(using: .utf8)!)
                try? handle.close()
            }
            acc = await reader.scan(file)
            precondition(acc.lastTokenCount?.total == 2_000, "growth must fold only appended bytes and reflect the newest event")
            precondition(acc.totalUsage?.input == 3_000)

            try? FileManager.default.removeItem(at: dir)
            sem.signal()
        }
        sem.wait()
    }

    // MARK: end-to-end pending case (no self-test can exercise a live PID —
    // this drives CodexSessionScanner.liveSessions with injected fixtures)

    private static func testLiveSessionsEndToEndPending() {
        let sem = DispatchSemaphore(value: 0)
        Task {
            let proc = CodexProcess(pid: 4242, startedLocal: Date(), cwd: "/Users/alex/new-project", isRealBinary: true)
            let sessions = await CodexSessionScanner.liveSessions(processes: [proc], threads: [], reader: CodexRolloutReader())
            precondition(sessions.count == 1, "a live codex PID with no threads row must still render")
            precondition(sessions[0].hasUsage == false)
            precondition(sessions[0].contextTokens == nil, "pending must never render as a zero context")
            precondition(sessions[0].kind == .codex)
            sem.signal()
        }
        sem.wait()
    }
}
