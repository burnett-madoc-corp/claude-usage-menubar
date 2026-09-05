import Darwin
import Foundation

// MARK: - JSON helpers
//
// Sessions.swift declares an equivalent extension, but `private` on a
// top-level extension is file-scoped in Swift — redeclared here rather than
// widening the other file's access, mirroring CodexSessions.swift.

private extension Dictionary where Key == String, Value == Any {
    func int64(_ key: String) -> Int64? { (self[key] as? NSNumber)?.int64Value }
    func string(_ key: String) -> String? { self[key] as? String }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
}

// MARK: - pi model registry (context windows)

/// `~/.pi/agent/models-store.json` — pi's cache of every provider's model
/// catalog. Each provider entry carries a `models` array whose members have
/// an `id` and a `contextWindow` (verified live: glm-5.3-flash → 1048576,
/// grok-4.6 → 500000). Parsing is pure so self-tests can drive it; sibling
/// keys like `checkedAt`/`etag` are skipped by the typed walk.
enum PiModelRegistry {
    struct Registry: Sendable, Equatable {
        var byProvider: [String: Int64] = [:]   // "<provider>/<model id>"
        var byId: [String: Int64] = [:]         // bare model id
    }

    static func parse(data: Data) -> Registry {
        var registry = Registry()
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return registry }
        for (provider, value) in obj {
            guard let entry = value as? [String: Any],
                  let models = entry["models"] as? [[String: Any]]
            else { continue }
            for model in models {
                guard let id = model["id"] as? String,
                      let window = (model["contextWindow"] as? NSNumber)?.int64Value,
                      window > 0
                else { continue }
                registry.byProvider["\(provider)/\(id)"] = window
                registry.byId[id] = window
            }
        }
        return registry
    }
}

// MARK: - pi coding agent sessions
//
// pi stores one JSONL file per session under ~/.pi/agent/sessions/<encoded
// cwd>/ — the first line is a header:
//
//   {"type":"session","version":3,"id":"…","timestamp":"…Z","cwd":"/Users/…"}
//
// and subsequent assistant `message` records carry the model, provider and
// a usage block:
//
//   {"type":"message","id":"…","timestamp":"…","message":{"role":"assistant",
//    "model":"…","provider":"…","usage":{"input":…,"output":…,"cacheRead":…,
//    "cacheWrite":…,"reasoning":…,"totalTokens":…,"cost":{…}}}}
//
// Live-process matching is start-time proximity (like Codex): the pi process's
// `lstart` lines up with the header timestamp to the second (the filename
// embeds the same instant, UTC). A live PID with no fresh session for its
// cwd is a resumed session — shown with the newest same-cwd transcript as a
// labelled best guess; a live PID with no session at all renders pending.

/// A session file found on disk, with what the matcher needs.
/// `Meta` (below) is the parsed first-line header.
struct PiLiveSession: Sendable, Equatable {
    var meta: Meta
    var path: URL
    var modified: Date

    struct Meta: Equatable {
        var id: String?
        var cwd: String
        var startedAt: Date?
    }
}

struct PiProcessCandidate: Sendable, Equatable {
    var pid: pid_t
    var startedLocal: Date
    var cwd: String
}

struct PiMatch: Sendable {
    var process: PiProcessCandidate
    var session: PiLiveSession?
    /// No session started within tolerance, but a same-cwd transcript exists
    /// (most likely `pi -c` / resume) — shown with its data, labelled.
    var viaFallback: Bool = false
}

enum PiSessionParsing {
    /// Same tolerance Codex uses: process start vs session creation observed
    /// at ~1s apart on live data; ±5s without reaching distinct-session gaps.
    static let startTolerance: TimeInterval = 5

    /// Pure parser for the session header line. Returns nil for anything
    /// that is not a `session` record with a cwd — malformed files must
    /// never render as rows pointing at nowhere.
    static func header(line: String) -> PiLiveSession.Meta? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj.string("type") == "session",
              let cwd = obj.string("cwd")
        else { return nil }
        let startedAt = obj.string("timestamp").flatMap {
            Format.iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
        }
        return .init(id: obj.string("id"), cwd: cwd, startedAt: startedAt)
    }
}

/// Folds one pi session JSONL line into the accumulator. Pure and
/// synchronous so self-tests can drive it directly.
enum PiSessionFold {
    /// pi's assistant `usage.totalTokens` is the full prompt bill for the
    /// turn (input + output + cacheRead + cacheWrite — reasoning sits inside
    /// output), so it is the context analogue Claude's per-turn quantity and
    /// Codex's `last_token_usage.total_tokens` are for their agents.
    static func fold(line: String, into acc: inout PiSessionReader.Acc) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj.string("type") == "message",
              let message = obj.dict("message"),
              message.string("role") == "assistant",
              let usage = message.dict("usage")
        else { return }

        let dedupKey = obj.string("id") ?? message.string("responseId") ?? UUID().uuidString
        guard !acc.seenMessageIds.contains(dedupKey) else { return }
        acc.rememberMessageId(dedupKey)

        let input = usage.int64("input") ?? 0
        let cacheRead = usage.int64("cacheRead") ?? 0
        let cacheWrite = usage.int64("cacheWrite") ?? 0
        let output = usage.int64("output") ?? 0

        acc.rawInputTokens += input + cacheRead + cacheWrite
        acc.rawOutputTokens += output
        acc.turns += 1
        
        if let cost = usage.dict("cost"), let totalCost = (cost["total"] as? NSNumber)?.doubleValue {
            let current = acc.exactSpent ?? 0.0
            acc.exactSpent = current + totalCost
        }

        if let total = usage.int64("totalTokens") { acc.contextTokens = total }
        if let model = message.string("model") { acc.lastModel = model }
        if let provider = message.string("provider") { acc.lastProvider = provider }
        if let ts = obj.string("timestamp") {
            acc.lastActivityAt = (Format.iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts))
                ?? acc.lastActivityAt
        }
    }
}

actor PiSessionReader {
    static let shared = PiSessionReader()

    static let seenMessageIdCap = 4000

    struct Acc: Sendable {
        var byteOffset: UInt64 = 0
        var partialTail: Data = Data()

        var seenMessageIds: Set<String> = []
        var seenMessageIdOrder: [String] = []

        var rawInputTokens: Int64 = 0
        var rawOutputTokens: Int64 = 0
        var exactSpent: Double? = nil
        var turns: Int = 0
        var contextTokens: Int64?
        var lastModel: String?
        var lastProvider: String?
        var lastActivityAt: Date?

        mutating func rememberMessageId(_ id: String) {
            seenMessageIds.insert(id)
            seenMessageIdOrder.append(id)
            guard seenMessageIdOrder.count > PiSessionReader.seenMessageIdCap else { return }
            let oldest = seenMessageIdOrder.removeFirst()
            seenMessageIds.remove(oldest)
        }
    }

    private var accumulators: [String: Acc] = [:]

    /// pi never records a context-window constant in its session files, but
    /// ~/.pi/agent/models-store.json caches every provider's full model
    /// catalog with per-model `contextWindow` — so "window unknown" becomes a
    /// real percent bar by looking the session's current model up there.
    /// Registry is mtime-cached: parsed once, re-read only when pi rewrites
    /// it. Lookup is by model id, preferring the session's own provider's
    /// catalog entry when it has one.
    private var registryByProvider: [String: Int64] = [:]
    private var registryById: [String: Int64] = [:]
    private var registryMtime: Date?

    func contextWindow(provider: String?, modelId: String?) -> Int64? {
        guard let modelId, !modelId.isEmpty else { return nil }
        refreshRegistryIfNeeded()
        if let provider, !provider.isEmpty,
           let window = registryByProvider["\(provider)/\(modelId)"] { return window }
        return registryById[modelId]
    }

    private func refreshRegistryIfNeeded() {
        let url = PiSessions.defaultModelsStoreURL
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.
            modificationDate] as? Date, mtime != registryMtime else { return }
        registryMtime = mtime
        guard let data = try? Data(contentsOf: url) else { return }
        let parsed = PiModelRegistry.parse(data: data)
        registryByProvider = parsed.byProvider
        registryById = parsed.byId
    }

    func evictAccumulators(keeping livePaths: Set<String>) {
        accumulators = accumulators.filter { livePaths.contains($0.key) }
    }

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
        if size < acc.byteOffset { acc = Acc() }
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
            PiSessionFold.fold(line: String(decoding: lineData, as: UTF8.self), into: &acc)
            searchStart = combined.index(after: nlIndex)
        }
        acc.partialTail = Data(combined[searchStart...])
        acc.byteOffset += UInt64(newBytes.count)

        accumulators[key] = acc
        return acc
    }
}

enum PiSessionMatcher {
    /// Confident: same cwd AND session start within tolerance of process
    /// start. Otherwise the newest same-cwd transcript is a labelled best
    /// guess; no same-cwd transcript at all renders pending.
    static func match(processes: [PiProcessCandidate],
                      sessions: [PiLiveSession]) -> [PiMatch] {
        processes.map { process in
            let sameCwd = sessions.filter { $0.meta.cwd == process.cwd }
            let withinTolerance = sameCwd.filter { session in
                guard let started = session.meta.startedAt else { return false }
                return abs(started.timeIntervalSince(process.startedLocal)) <= PiSessionParsing.startTolerance
            }
            if let closest = withinTolerance.min(by: {
                ($0.meta.startedAt?.timeIntervalSince(process.startedLocal) ?? .infinity)
                    < ($1.meta.startedAt?.timeIntervalSince(process.startedLocal) ?? .infinity)
            }) {
                return PiMatch(process: process, session: closest)
            }
            if let newest = sameCwd.max(by: { $0.modified < $1.modified }) {
                return PiMatch(process: process, session: newest, viaFallback: true)
            }
            return PiMatch(process: process, session: nil)
        }
    }
}

enum PiSessions {
    static var defaultSessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions")
    }

    static var defaultModelsStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/models-store.json")
    }

    static func snapshot(
        processes: [ProcInfo] = ProcessScanner.run(),
        sessionsDir: URL = defaultSessionsDir,
        cwdLookup: (pid_t) -> String? = { CwdLookup.cwd(pid: $0) },
        reader: PiSessionReader = .shared
    ) async -> [AgentSession] {
        // comm is exactly "pi" — a token-substring check would drag in pips
        // and scripts that merely contain the two letters in argv.
        let live = processes
            .filter { $0.comm == "pi" }
            .compactMap { proc -> PiProcessCandidate? in
                guard let cwd = cwdLookup(proc.pid), !cwd.isEmpty else { return nil }
                return PiProcessCandidate(pid: proc.pid, startedLocal: proc.startedLocal, cwd: cwd)
            }
        guard !live.isEmpty else { return [] }

        let sessions = enumerateSessions(in: sessionsDir)
        let matches = PiSessionMatcher.match(processes: live, sessions: sessions)

        var result: [AgentSession] = []
        var scannedPaths: Set<String> = []
        for match in matches {
            let label = PathEncoding.label(cwd: match.process.cwd)
            guard let session = match.session else {
                // Live PID, no transcript yet — pre-first-message. Renders
                // pending; unknown usage, never a fabricated 0%.
                result.append(AgentSession(
                    kind: .pi, pid: match.process.pid, label: label, taskTitle: nil,
                    cwd: match.process.cwd, model: nil, busy: true,
                    turns: 0, inputTokens: 0, outputTokens: 0, exactSpent: nil,
                    subagentTokens: nil, contextTokens: nil, contextWindow: nil,
                    xFloorMultiple: nil, compactionCount: 0,
                    lastCompactionAt: nil, lastCompactionPreCtx: nil, lastCompactionPostCtx: nil,
                    hasUsage: false
                ))
                continue
            }

            scannedPaths.insert(session.path.path)
            let acc = await reader.scan(session.path)
            // pi stores no window constant in the transcript; the model
            // registry lookup is what turns contextTokens into a real bar.
            let window = await reader.contextWindow(provider: acc.lastProvider,
                                                    modelId: acc.lastModel)
            var rowLabel = label
            if match.viaFallback { rowLabel += " (unmatched)" }
            result.append(AgentSession(
                kind: .pi,
                pid: match.process.pid,
                label: rowLabel,
                taskTitle: nil,
                cwd: session.meta.cwd,
                model: acc.lastModel,
                busy: true,
                turns: acc.turns,
                inputTokens: acc.rawInputTokens,
                outputTokens: acc.rawOutputTokens, exactSpent: acc.exactSpent,
                subagentTokens: nil,
                contextTokens: acc.contextTokens,
                contextWindow: window,
                xFloorMultiple: nil,
                compactionCount: 0,
                lastCompactionAt: nil, lastCompactionPreCtx: nil, lastCompactionPostCtx: nil,
                hasUsage: acc.contextTokens != nil,
                lastActivityAt: acc.lastActivityAt
            ))
        }
        await reader.evictAccumulators(keeping: scannedPaths)
        return result.sorted { $0.label < $1.label }
    }

    /// Enumerates session transcripts by reading each file's header line —
    /// the header carries the cwd verbatim, so no reverse-engineered
    /// directory-name encoding can silently drift out from under us.
    static func enumerateSessions(in dir: URL) -> [PiLiveSession] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) else { return [] }

        var result: [PiLiveSession] = []
        for projectDir in dirs where (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let header = readHeader(of: file) else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                result.append(PiLiveSession(meta: header, path: file, modified: modified))
            }
        }
        return result
    }

    /// Reads only the first line — a few hundred bytes, never the transcript.
    static func readHeader(of url: URL) -> PiLiveSession.Meta? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1024), !data.isEmpty else { return nil }
        let firstLine = String(decoding: data.prefix(while: { $0 != 0x0A }), as: UTF8.self)
        guard let meta = PiSessionParsing.header(line: firstLine) else { return nil }
        return .init(id: meta.id, cwd: meta.cwd, startedAt: meta.startedAt)
    }
}

// MARK: - Antigravity (agy) sessions
//
// A live agy process is its own language server: each PID holds a flock on
// ~/.gemini/antigravity-cli/presence/<conversationId>.lock (verified: the
// lock's UUID is the conversation id) and LISTENs on an ephemeral loopback
// port serving the unauthenticated Connect RPC. One `lsof -p <pid>` yields
// all three identities at once — cwd (the cwd fd), the lock (conversation),
// and the port (its own server).
//
// Per-PID servers only know their own conversations, so each process is
// queried directly:
//
//   GetAllCascadeTrajectories → per-conversation summary: title, status
//     (CASCADE_RUN_STATUS_IDLE = idle), workspaces (cwd), lastUserInputTime
//   GetCascadeTrajectory {cascadeId: <conversationId>} → generatorMetadata[]:
//     per-invocation usage {inputTokens, outputTokens — JSON strings} and
//     chatStartMetadata.contextWindowMetadata {estimatedTokensUsed,
//     maxContextTokens} — the real context state, replacing the old
//     history.jsonl heuristic AND resolving the "no usage for agy" gap.
//
// Trajectory payloads run to MBs, so they are fetched only when the
// conversation's lastUserInputTime advances (actor-cached); summaries are
// cheap and always refreshed. If lsof yields nothing for a PID, the row
// degrades through the old history.jsonl cwd heuristic — a live agy session
// is never dropped for lack of identity.

struct AgyHistoryEntry: Equatable, Sendable {
    var display: String?
    var workspace: String?
    var conversationId: String?
    var timestampMs: Int64?
}

enum AgyHistoryParsing {
    static func parse(line: String) -> AgyHistoryEntry? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let conversationId = obj.string("conversationId")
        else { return nil }
        return AgyHistoryEntry(display: obj.string("display"),
                               workspace: obj.string("workspace"),
                               conversationId: conversationId,
                               timestampMs: obj.int64("timestamp"))
    }

    /// The newest entry for a workspace. When `since` is given, entries from
    /// before it are only used if nothing newer exists — a live agy writes a
    /// history line on every user turn, so a same-workspace entry newer than
    /// the process start is confident identity; anything older is a previous
    /// conversation in the same workspace and best-guess at best.
    static func newest(entries: [AgyHistoryEntry], workspace: String, since: Date?) -> AgyHistoryEntry? {
        let sameWorkspace = entries.filter { $0.workspace == workspace }
        if let since,
           let live = sameWorkspace
               .filter({ entry in entry.timestampMs.map { Date(timeIntervalSince1970: Double($0) / 1000) >= since } ?? false })
               .max(by: { ($0.timestampMs ?? 0) < ($1.timestampMs ?? 0) }) {
            return live
        }
        return sameWorkspace.max(by: { ($0.timestampMs ?? 0) < ($1.timestampMs ?? 0) })
    }
}

enum AgySessions {
    static var defaultHistoryPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/history.jsonl")
    }

    static func snapshot(
        processes: [ProcInfo] = ProcessScanner.run(),
        historyPath: URL = defaultHistoryPath,
        cwdLookup: (pid_t) -> String? = { CwdLookup.cwd(pid: $0) },
        lsofOutput: (pid_t) -> String? = { AgyProcessScanner.run(pid: $0) },
        fetcher: AgyRPC.Fetch = AgyRPC.defaultFetch,
        cache: AgyTrajectoryCache = .shared
    ) async -> [AgentSession] {
        let live = processes.filter { $0.comm == "agy" }
        guard !live.isEmpty else { return [] }

        // Fallback identity source, loaded once and only if needed.
        var history: [AgyHistoryEntry]?
        func historyEntries() -> [AgyHistoryEntry] {
            if let history { return history }
            let parsed = Net.tail(of: historyPath, bytes: 1024 * 1024)?
                .split(separator: "\n")
                .compactMap { AgyHistoryParsing.parse(line: String($0)) } ?? []
            history = parsed
            return parsed
        }

        var result: [AgentSession] = []
        var liveConversations: Set<String> = []
        for proc in live {
            let scan = lsofOutput(proc.pid).map { AgyProcessScanner.parse(lsofOutput: $0) }

            // Rich path: the presence lock gives the exact conversation, the
            // LISTEN port gives its own server.
            if let scan, let convId = scan.conversationId, let port = scan.port,
               let summaries = await AgyRPC.fetchSummaries(port: port, fetcher: fetcher),
               let summary = summaries.first(where: { $0.id == convId }) {

                // Only advance-poll the trajectory: an MB-scale payload, but
                // its content is stable between user turns.
                let stamp = summary.lastUserInputTime ?? .distantPast
                let acc = await cache.trajectory(convId: convId, port: port,
                                                 changedAt: stamp, fetcher: fetcher)

                let cwd = summary.workspace ?? scan.cwd
                let label = cwd.map(PathEncoding.label) ?? "Agy"
                let busy = summary.status.map { !$0.contains("IDLE") } ?? true
                result.append(AgentSession(
                    kind: .agy,
                    pid: proc.pid,
                    label: label,
                    taskTitle: summary.title,
                    cwd: cwd ?? "",
                    model: acc?.model,
                    busy: busy,
                    turns: acc?.turns ?? 0,
                    inputTokens: acc?.inputTokens ?? 0,
                    outputTokens: acc?.outputTokens ?? 0, exactSpent: nil,
                    subagentTokens: nil,
                    contextTokens: acc?.contextTokens,
                    contextWindow: acc?.contextWindow,
                    xFloorMultiple: acc?.xFloorMultiple, compactionCount: 0,
                    lastCompactionAt: nil, lastCompactionPreCtx: nil,
                    lastCompactionPostCtx: nil,
                    hasUsage: acc?.contextTokens != nil,
                    lastActivityAt: summary.lastUserInputTime
                ))
                liveConversations.insert(convId)
                continue
            }

            // Degraded paths — a live agy session is never dropped.
            if let cwd = scan?.cwd, !cwd.isEmpty {
                result.append(Self.pendingRow(pid: proc.pid, cwd: cwd))
                continue
            }
            if let cwd = cwdLookup(proc.pid), !cwd.isEmpty {
                let entries = historyEntries()
                let entry = entries.isEmpty ? nil : AgyHistoryParsing.newest(
                    entries: entries, workspace: cwd,
                    since: proc.startedLocal.addingTimeInterval(-5))
                let prompt = entry?.display.flatMap { $0.isEmpty ? nil : $0 }
                result.append(AgentSession(
                    kind: .agy, pid: proc.pid,
                    label: PathEncoding.label(cwd: cwd),
                    taskTitle: prompt, cwd: cwd,
                    model: nil, busy: true,
                    turns: 0, inputTokens: 0, outputTokens: 0, exactSpent: nil,
                    subagentTokens: nil, contextTokens: nil, contextWindow: nil,
                    xFloorMultiple: nil, compactionCount: 0,
                    lastCompactionAt: nil, lastCompactionPreCtx: nil,
                    lastCompactionPostCtx: nil, hasUsage: false
                ))
                continue
            }
            result.append(Self.pendingRow(pid: proc.pid, cwd: ""))
        }
        await cache.evict(keeping: liveConversations)
        return result.sorted { $0.label < $1.label }
    }

    /// A live agy whose identity fell through: unknown usage, never a
    /// fabricated zero — the same contract Codex's pending rows make.
    private static func pendingRow(pid: pid_t, cwd: String) -> AgentSession {
        AgentSession(
            kind: .agy, pid: pid,
            label: cwd.isEmpty ? "Agy" : PathEncoding.label(cwd: cwd),
            taskTitle: nil, cwd: cwd,
            model: nil, busy: true,
            turns: 0, inputTokens: 0, outputTokens: 0, exactSpent: nil,
            subagentTokens: nil, contextTokens: nil, contextWindow: nil,
            xFloorMultiple: nil, compactionCount: 0,
            lastCompactionAt: nil, lastCompactionPreCtx: nil, lastCompactionPostCtx: nil,
            hasUsage: false
        )
    }
}

// MARK: - agy process scan + language-server RPC client

/// Pure parser for one `lsof -nP -p <pid>` dump of a live agy process.
/// The cwd fd line gives a degraded-path cwd; the LISTEN line gives the
/// process's own Connect server; the presence lock line gives the exact
/// conversation id (the lock filename's UUID — verified to equal the
/// conversation id in GetAllCascadeTrajectories).
enum AgyProcessScanner {
    struct Scan: Equatable, Sendable {
        var cwd: String?
        var port: Int?
        var conversationId: String?
    }

    static func run(pid: pid_t) -> String? {
        guard case let .success(data) = BoundedProcess.run(
            executable: "/usr/sbin/lsof", arguments: ["-nP", "-p", String(pid)], timeout: 5
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(lsofOutput: String) -> Scan {
        var scan = Scan(cwd: nil, port: nil, conversationId: nil)
        for line in lsofOutput.split(separator: "\n") {
            if scan.cwd == nil, line.contains(" cwd ") {
                // "… cwd DIR … /path" — the path is the last token.
                let tokens = line.split(separator: " ")
                if let last = tokens.last, last.hasPrefix("/") { scan.cwd = String(last) }
            }
            if scan.port == nil, line.contains("(LISTEN)"),
               let token = line.split(separator: " ").first(where: { $0.hasPrefix("127.0.0.1:") }),
               let port = Int(token.dropFirst("127.0.0.1:".count)) {
                scan.port = port
            }
            if scan.conversationId == nil,
               let range = line.range(of: "/presence/"),
               line[range.upperBound...].hasSuffix(".lock") {
                var name = line[range.upperBound...]
                name = name.dropLast(".lock".count)
                scan.conversationId = String(name)
            }
        }
        return scan
    }
}

/// Connect-RPC client for the agy language server's read-only session calls.
enum AgyRPC {
    static let rpcPath = "/exa.language_server_pb.LanguageServerService/"
    typealias Fetch = (Int, String, [String: Any]) async -> Data?

    /// POSTs one Connect call. The server is loopback-only and takes no
    /// auth; http first, https (self-signed — LoopbackSession) second,
    /// mirroring AntigravityProvider's port probing.
    static func defaultFetch(port: Int, rpc: String, body: [String: Any]) async -> Data? {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        for scheme in ["http", "https"] {
            guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(rpcPath)\(rpc)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 5
            guard let (data, response) = try? await LoopbackSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { continue }
            return data
        }
        return nil
    }

    static func fetchSummaries(port: Int, fetcher: Fetch) async -> [ConversationSummary]? {
        guard let data = await fetcher(port, "GetAllCascadeTrajectories", [:]) else { return nil }
        return parseSummaries(data: data)
    }

    struct ConversationSummary: Equatable, Sendable {
        var id: String
        var title: String?
        var workspace: String?
        var status: String?
        var lastUserInputTime: Date?
    }

    /// Pure parser for GetAllCascadeTrajectories. Workspace paths arrive as
    /// file:// URIs. A missing/blank status reads busy — the safe default for
    /// a process we can see is alive.
    static func parseSummaries(data: Data) -> [ConversationSummary] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let summaries = obj["trajectorySummaries"] as? [String: Any]
        else { return [] }
        return summaries.compactMap { id, value -> ConversationSummary? in
            guard let entry = value as? [String: Any] else { return nil }
            let workspace = (entry["workspaces"] as? [Any])?.compactMap { ws -> String? in
                guard let ws = ws as? [String: Any],
                      let uri = ws["workspaceFolderAbsoluteUri"] as? String
                else { return nil }
                return uri.hasPrefix("file://") ? String(uri.dropFirst("file://".count)) : uri
            }.first
            return ConversationSummary(
                id: id,
                title: entry["summary"] as? String,
                workspace: workspace,
                status: entry["status"] as? String,
                lastUserInputTime: (entry["lastUserInputTime"] as? String).flatMap {
                    Format.iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
                }
            )
        }
    }

    struct TrajectoryAcc: Equatable, Sendable {
        var model: String?
        var contextTokens: Int64?
        var contextWindow: Int64?
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var turns: Int = 0
        var turnCosts: [Int64] = []

        var xFloorMultiple: Double? {
            SessionScanner.xFloor(turnCosts: turnCosts)
        }
    }

    /// Pure parser for GetCascadeTrajectory. Fields verified live:
    ///
    ///   trajectory.generatorMetadata[].chatModel.usage
    ///       {inputTokens, outputTokens, thinkingOutputTokens, …} — JSON
    ///       STRINGS of integers; output already includes thinking.
    ///   trajectory.generatorMetadata[].chatModel.chatStartMetadata
    ///       .contextWindowMetadata
    ///       {estimatedTokensUsed, maxContextTokens} — ints; the context at
    ///       that invocation's START, so the freshest estimate for a row is
    ///       max(newest start estimate, newest input + output).
    ///   trajectory.executorMetadatas[].cascadeConfig.plannerConfig.modelName
    ///       — the human model name ("gemini-3.1-pro-low"); the enum fields
    ///       elsewhere read MODEL_PLACEHOLDER_M36.
    ///
    /// Usage totals sum every invocation (input re-sent per call bills, the
    /// same contract Claude's rawInputTokens keeps); retryInfos duplicates are
    /// ignored — a retry's final usage already lands in its own invocation.
    static func parseTrajectory(data: Data) -> TrajectoryAcc {
        var acc = TrajectoryAcc()
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let trajectory = obj["trajectory"] as? [String: Any]
        else { return acc }

        if let generators = trajectory["generatorMetadata"] as? [Any] {
            var lastUsage: (input: Int64, output: Int64)?
            for case let entry as [String: Any] in generators {
                acc.turns += 1
                guard let chat = entry["chatModel"] as? [String: Any],
                      let usage = chat["usage"] as? [String: Any]
                else { continue }
                let input = number(usage["inputTokens"]) ?? 0
                let output = number(usage["outputTokens"]) ?? 0
                acc.inputTokens += input
                acc.outputTokens += output
                lastUsage = (input, output)

                var turnCost = input + output
                if let start = chat["chatStartMetadata"] as? [String: Any],
                   let windowMeta = start["contextWindowMetadata"] as? [String: Any] {
                    acc.contextWindow = number(windowMeta["maxContextTokens"]) ?? acc.contextWindow
                    let estimated = number(windowMeta["estimatedTokensUsed"]) ?? 0
                    let current = max(estimated, lastUsage!.input + lastUsage!.output)
                    acc.contextTokens = max(acc.contextTokens ?? 0, current)
                    turnCost = current
                }
                if turnCost > 0 {
                    acc.turnCosts.append(turnCost)
                }
            }
            if acc.contextTokens == nil, let lastUsage {
                acc.contextTokens = lastUsage.input + lastUsage.output
            }
        }

        if let executors = trajectory["executorMetadatas"] as? [Any] {
            acc.model = executors.compactMap { entry -> String? in
                guard let entry = entry as? [String: Any],
                      let config = entry["cascadeConfig"] as? [String: Any],
                      let planner = config["plannerConfig"] as? [String: Any]
                else { return nil }
                return planner["modelName"] as? String
            }.last
        }

        if acc.contextWindow != nil || acc.contextTokens != nil {
            acc.contextWindow = contextWindow(for: acc.model,
                                              reported: acc.contextWindow,
                                              observedTokens: acc.contextTokens)
        }
        return acc
    }

    /// Resolves the context window for an agy session's model.
    ///
    /// The agy Connect RPC returns a placeholder 128,000 maxContextTokens in
    /// contextWindowMetadata regardless of the model in use (including Gemini
    /// 3.1 Pro). We override known model families with their actual context
    /// limits: Gemini Pro / 3.1 gets 2,000,000, Gemini Flash gets 1,000,000,
    /// Claude gets 200,000 (or 1,000,000 if suffixed -1m), and GPT-OSS / GPT-4o
    /// gets 128,000. If observed tokens exceed the nominal window, the window
    /// expands to fit, matching Claude's behavior.
    static func contextWindow(for model: String?, reported: Int64? = nil, observedTokens: Int64? = nil) -> Int64? {
        var window: Int64?
        if let model = model?.lowercased() {
            if model.contains("gemini") {
                if model.contains("flash") {
                    window = 1_000_000
                } else if model.contains("pro") || model.contains("3.1") {
                    window = 2_000_000
                } else {
                    window = 1_000_000
                }
            } else if model.contains("claude") {
                window = model.contains("1m") ? 1_000_000 : 200_000
            } else if model.contains("gpt-oss") || model.contains("gpt-4o") {
                window = 128_000
            } else if model.contains("codex") {
                window = 200_000
            }
        }
        if window == nil {
            window = reported
        }
        if let reported, reported != 128_000, let current = window, reported > current {
            window = reported
        }
        if let observed = observedTokens, let current = window, observed > current {
            window = observed
        }
        return window
    }

    /// agy emits integers as bare ints in contextWindowMetadata but as
    /// STRINGS in usage — one tolerant reader for both.
    static func number(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }
}

/// Trajectory payloads are MB-scale, so each conversation's parsed state is
/// cached and only re-fetched when its lastUserInputTime advances. Entries
/// for conversations no longer alive are evicted each cycle.
actor AgyTrajectoryCache {
    static let shared = AgyTrajectoryCache()

    private var entries: [String: (changedAt: Date, acc: AgyRPC.TrajectoryAcc)] = [:]

    var cachedCount: Int { entries.count }

    func trajectory(convId: String, port: Int, changedAt: Date,
                    fetcher: AgyRPC.Fetch) async -> AgyRPC.TrajectoryAcc? {
        if let entry = entries[convId], entry.changedAt == changedAt { return entry.acc }
        guard let data = await fetcher(port, "GetCascadeTrajectory", ["cascadeId": convId])
        else { return entries[convId]?.acc }
        let acc = AgyRPC.parseTrajectory(data: data)
        entries[convId] = (changedAt, acc)
        return acc
    }

    func evict(keeping live: Set<String>) {
        entries = entries.filter { live.contains($0.key) }
    }
}

// MARK: - Self-tests

enum PiAndAgySessionSelfTests {
    static func run() {
        testPiHeaderParsing()
        testPiFold()
        testPiFoldDedup()
        testPiMatcher()
        testPiHeaderReadOfFixtureFile()
        testPiModelRegistry()
        testAgyHistoryParsing()
        testAgyNewestSelection()
        testAgyProcessScan()
        testAgySummariesParse()
        testAgyTrajectoryParse()
        testAgyTrajectoryCache()
    }

    private static func piSessionLine(cwd: String = "/Users/dev/proj",
                                       timestamp: String = "2026-08-29T09:50:43.841Z") -> String {
        #"{"type":"session","version":3,"id":"01a04ced","timestamp":"\#(timestamp)","cwd":"\#(cwd)"}"#
    }

    private static func piMessageLine(id: String, input: Int64 = 2, output: Int64 = 100,
                                       cacheRead: Int64 = 47_168, model: String = "grok-4.6",
                                       total: Int64? = nil, timestamp: String = "2026-08-29T09:55:36.937Z") -> String {
        let t = total ?? input + output + cacheRead
        return """
        {"type":"message","id":"\(id)","timestamp":"\(timestamp)","message":{"role":"assistant","model":"\(model)","usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),"cacheWrite":0,"reasoning":558,"totalTokens":\(t),"cost":{"total":0.001}}}}
        """
    }

    private static func testPiHeaderParsing() {
        let meta = PiSessionParsing.header(line: piSessionLine())
        precondition(meta != nil)
        precondition(meta?.cwd == "/Users/dev/proj")
        precondition(meta?.id == "01a04ced")
        precondition(meta?.startedAt != nil, "the header timestamp must parse")

        precondition(PiSessionParsing.header(line: #"{"type":"message"}"#) == nil,
                     "a non-header line must not parse as a session header")
        precondition(PiSessionParsing.header(line: "not json") == nil)
    }

    private static func testPiFold() {
        var acc = PiSessionReader.Acc()
        PiSessionFold.fold(line: piSessionLine(), into: &acc)
        precondition(acc.turns == 0 && acc.contextTokens == nil,
                     "a session header must contribute no usage")

        PiSessionFold.fold(line: piMessageLine(id: "m1", input: 5_614, output: 833, cacheRead: 47_168), into: &acc)
        precondition(acc.turns == 1)
        precondition(acc.rawInputTokens == 5_614 + 47_168, "input must include cacheRead (cacheWrite is 0 here)")
        precondition(acc.rawOutputTokens == 833)
        precondition(acc.contextTokens == 5_614 + 833 + 47_168,
                     "context must be the usage total, mirroring Codex last_token_usage")
        precondition(acc.lastModel == "grok-4.6")
        precondition(acc.lastActivityAt != nil)

        PiSessionFold.fold(line: piMessageLine(id: "m2", input: 790, output: 3_061, cacheRead: 46_400), into: &acc)
        precondition(acc.turns == 2)
        precondition(acc.rawInputTokens == 5_614 + 47_168 + 790 + 46_400)
        precondition(acc.contextTokens == 790 + 3_061 + 46_400, "the newest usage total must win")
        precondition(abs((acc.exactSpent ?? 0) - 0.002) < 0.0001, "exact spent must sum message costs")
    }

    private static func testPiFoldDedup() {
        var acc = PiSessionReader.Acc()
        let dup = piMessageLine(id: "same")
        PiSessionFold.fold(line: dup, into: &acc)
        PiSessionFold.fold(line: dup, into: &acc)
        PiSessionFold.fold(line: dup, into: &acc)
        precondition(acc.turns == 1, "repeated message ids (streaming retries) must dedup to one turn")
        precondition(acc.rawInputTokens == 2 + 47_168)
        precondition(abs((acc.exactSpent ?? 0) - 0.001) < 0.0001, "deduped turns must not double-count cost")
    }

    private static func testPiMatcher() {
        let started = Date()
        let proc = PiProcessCandidate(pid: 1, startedLocal: started, cwd: "/Users/dev/proj")
        func session(name: String, cwd: String, startedAt: Date?, modified: Date) -> PiLiveSession {
            PiLiveSession(meta: .init(id: name, cwd: cwd, startedAt: startedAt),
                          path: URL(fileURLWithPath: "/tmp/\(name).jsonl"), modified: modified)
        }

        // Same cwd, start within tolerance — confident.
        let conf = PiSessionMatcher.match(
            processes: [proc],
            sessions: [session(name: "in", cwd: "/Users/dev/proj",
                               startedAt: started.addingTimeInterval(4.9), modified: started)])
        precondition(conf.count == 1 && conf[0].session?.meta.id == "in" && !conf[0].viaFallback)

        // Out of tolerance (resumed session) but same cwd — labelled fallback
        // onto the newest same-cwd transcript, never dropped, never guessed wrong silently.
        let resumed = PiSessionMatcher.match(
            processes: [proc],
            sessions: [session(name: "old", cwd: "/Users/dev/proj",
                               startedAt: started.addingTimeInterval(-3600), modified: started.addingTimeInterval(-10))])
        precondition(resumed.count == 1 && resumed[0].session?.meta.id == "old" && resumed[0].viaFallback)

        // No transcript for this cwd at all — pending.
        let pending = PiSessionMatcher.match(
            processes: [proc],
            sessions: [session(name: "elsewhere", cwd: "/Users/other", startedAt: started, modified: started)])
        precondition(pending.count == 1 && pending[0].session == nil && !pending[0].viaFallback)

        // Two candidates in tolerance: closest start wins.
        let tie = PiSessionMatcher.match(
            processes: [proc],
            sessions: [session(name: "far", cwd: "/Users/dev/proj",
                               startedAt: started.addingTimeInterval(4.9), modified: started),
                       session(name: "near", cwd: "/Users/dev/proj",
                               startedAt: started.addingTimeInterval(0.1), modified: started)])
        precondition(tie[0].session?.meta.id == "near", "the closest start must win a multi-match")
    }

    private static func testPiHeaderReadOfFixtureFile() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pi-header-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("--Users-dev-proj--"),
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("--Users-dev-proj--/2026-08-29T09-50-43-841Z_abc.jsonl")
        try? (piSessionLine() + "\n" + piMessageLine(id: "m1") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let sessions = PiSessions.enumerateSessions(in: dir)
        precondition(sessions.count == 1)
        precondition(sessions[0].meta.cwd == "/Users/dev/proj")
        precondition(sessions[0].meta.startedAt != nil)
    }

    // MARK: pi model registry → context windows

    private static func testPiModelRegistry() {
        let data = Data(#"{"openrouter":{"models":[{"id":"z-ai/glm-5.3-flash","contextWindow":1048576,"maxTokens":131072},{"id":"no-window","maxTokens":4096},{"id":"zero-window","contextWindow":0}],"checkedAt":123},"xai":{"models":[{"id":"x-ai/grok-4.6","contextWindow":500000}]}}"#.utf8)
        let registry = PiModelRegistry.parse(data: data)
        precondition(registry.byId["z-ai/glm-5.3-flash"] == 1_048_576)
        precondition(registry.byId["x-ai/grok-4.6"] == 500_000)
        precondition(registry.byProvider["openrouter/z-ai/glm-5.3-flash"] == 1_048_576)
        precondition(registry.byId["no-window"] == nil && registry.byId["zero-window"] == nil,
                     "models without a positive window must not fabricate a denominator")
        precondition(registry.byId["checkedAt"] == nil, "non-provider keys must be skipped")
    }

    // MARK: agy lsof scan → {cwd, port, conversation}

    private static func testAgyProcessScan() {
        let sample = """
        COMMAND   PID USER   FD      TYPE             DEVICE  SIZE/OFF NODE NAME
        agy     62563 alex  cwd       DIR               1,18       544 18629548 /Users/git/empire-earth-4
        agy     62563 alex   10u     IPv4 0x9f7fe5 0t0    TCP 127.0.0.1:49813 (LISTEN)
        agy     62563 alex   70u      REG               1,18          0 18997294 /Users/alex/.gemini/antigravity-cli/presence/0d1906dc-4890-4536-8830-10430ccfab87.lock
        agy     62563 alex   14u     IPv4 0x9f7fe5 0t0    TCP 192.168.1.86:52099->34.54.84.110:443 (ESTABLISHED)
        """
        let scan = AgyProcessScanner.parse(lsofOutput: sample)
        precondition(scan.cwd == "/Users/git/empire-earth-4")
        precondition(scan.port == 49813, "the LISTEN port of the agy server must be found")
        precondition(scan.conversationId == "0d1906dc-4890-4536-8830-10430ccfab87")
        precondition(AgyProcessScanner.parse(lsofOutput: "").conversationId == nil)
    }

    // MARK: agy summaries parse

    private static func testAgySummariesParse() {
        let data = Data(#"{"trajectorySummaries":{"129f0896":{"summary":"Optimizing Multi-Agent Architecture","stepCount":136,"trajectoryId":"7f313669","status":"CASCADE_RUN_STATUS_IDLE","workspaces":[{"workspaceFolderAbsoluteUri":"file:///Users/git/empire-earth-4"}],"lastUserInputTime":"2026-08-28T22:38:54.596520Z"},"a522ac1c":{"summary":"","status":"CASCADE_RUN_STATUS_RUNNING","workspaces":[]}}}"#.utf8)
        let summaries = AgyRPC.parseSummaries(data: data)
        precondition(summaries.count == 2)
        let first = summaries.first { $0.id == "129f0896" }!
        precondition(first.title == "Optimizing Multi-Agent Architecture")
        precondition(first.workspace == "/Users/git/empire-earth-4", "file:// prefix must be stripped")
        precondition(first.status?.contains("IDLE") == true)
        precondition(first.lastUserInputTime != nil)

        let running = summaries.first { $0.id == "a522ac1c" }!
        precondition(running.status?.contains("IDLE") == false)
        precondition(running.workspace == nil, "a conversation with no workspaces has no cwd")
    }

    // MARK: agy trajectory parse — context window, tokens, model

    private static func trajectoryFixture() -> Data {
        Data(#"{"trajectory":{"trajectoryId":"t","cascadeId":"c","steps":[],"generatorMetadata":[{"stepIndices":[1,2],"chatModel":{"model":"MODEL_PLACEHOLDER_M36","usage":{"model":"MODEL_PLACEHOLDER_M36","inputTokens":"9399","outputTokens":"535","thinkingOutputTokens":"300"},"chatStartMetadata":{"checkpointIndex":-1,"contextWindowMetadata":{"estimatedTokensUsed":9500,"maxContextTokens":128000}}}},{"stepIndices":[3],"chatModel":{"usage":{"inputTokens":"26000","outputTokens":"1400","thinkingOutputTokens":"900"},"chatStartMetadata":{"contextWindowMetadata":{"estimatedTokensUsed":25217,"maxContextTokens":128000}}}}],"executorMetadatas":[{"cascadeConfig":{"plannerConfig":{"modelName":"gemini-3-flash"}}},{"cascadeConfig":{"plannerConfig":{"modelName":"gemini-3.1-pro-low"}}}]},"status":"CASCADE_RUN_STATUS_IDLE","numTotalSteps":3}"#.utf8)
    }

    private static func testAgyTrajectoryParse() {
        let acc = AgyRPC.parseTrajectory(data: trajectoryFixture())
        precondition(acc.contextWindow == 2_000_000,
                     "gemini-3.1-pro-low must resolve to 2m context window, overriding reported 128k")
        // Context = max(newest start estimate, newest input+output):
        // 25217 vs 26000+1400 → the fresher, larger view wins.
        precondition(acc.contextTokens == 27_400)
        precondition(acc.inputTokens == 9_399 + 26_000, "usage totals sum every invocation")
        precondition(acc.outputTokens == 535 + 1_400)
        precondition(acc.turns == 2)
        precondition(acc.turnCosts == [9_934, 27_400])
        precondition(acc.xFloorMultiple == nil, "fewer than 5 turns must yield nil bloat")
        precondition(acc.model == "gemini-3.1-pro-low",
                     "the newest executor's planner modelName is the live model")

        // Context window resolution rules
        precondition(AgyRPC.contextWindow(for: "gemini-3.1-pro-low", reported: 128_000) == 2_000_000)
        precondition(AgyRPC.contextWindow(for: "gemini-3.1-pro-high", reported: 128_000) == 2_000_000)
        precondition(AgyRPC.contextWindow(for: "gemini-3.1", reported: 128_000) == 2_000_000)
        precondition(AgyRPC.contextWindow(for: "gemini-3.8-flash-high", reported: 128_000) == 1_000_000)
        precondition(AgyRPC.contextWindow(for: "gemini-3-flash", reported: 128_000) == 1_000_000)
        precondition(AgyRPC.contextWindow(for: "claude-sonnet-4-6", reported: 128_000) == 200_000)
        precondition(AgyRPC.contextWindow(for: "claude-opus-4-6-1m", reported: 128_000) == 1_000_000)
        precondition(AgyRPC.contextWindow(for: "gpt-oss-120b-medium", reported: 128_000) == 128_000)
        precondition(AgyRPC.contextWindow(for: "custom-model", reported: 500_000) == 500_000)
        precondition(AgyRPC.contextWindow(for: "gemini-3.1-pro-low", reported: 128_000, observedTokens: 2_500_000) == 2_500_000)

        // Trajectory with 5+ turns computes bloat (xFloorMultiple)
        let bloatData = Data(#"{"trajectory":{"trajectoryId":"b","generatorMetadata":[{"chatModel":{"usage":{"inputTokens":"10000","outputTokens":"0"}}},{"chatModel":{"usage":{"inputTokens":"10000","outputTokens":"0"}}},{"chatModel":{"usage":{"inputTokens":"10000","outputTokens":"0"}}},{"chatModel":{"usage":{"inputTokens":"10000","outputTokens":"0"}}},{"chatModel":{"usage":{"inputTokens":"10000","outputTokens":"0"}}},{"chatModel":{"usage":{"inputTokens":"25000","outputTokens":"0"}}},{"chatModel":{"usage":{"inputTokens":"25000","outputTokens":"0"}}},{"chatModel":{"usage":{"inputTokens":"25000","outputTokens":"0"}}},{"chatModel":{"usage":{"inputTokens":"25000","outputTokens":"0"}}},{"chatModel":{"usage":{"inputTokens":"25000","outputTokens":"0"}}}],"executorMetadatas":[{"cascadeConfig":{"plannerConfig":{"modelName":"gemini-3.1-pro-high"}}}]}}"#.utf8)
        let bloatAcc = AgyRPC.parseTrajectory(data: bloatData)
        precondition(bloatAcc.turns == 10)
        precondition(bloatAcc.turnCosts.count == 10)
        precondition(bloatAcc.xFloorMultiple == 2.5, "bloat must compute live/baseline ratio")
        precondition(bloatAcc.contextWindow == 2_000_000)

        // A trajectory with no generator metadata (fresh conversation) must
        // stay pending — never a fabricated 0% context.
        let empty = AgyRPC.parseTrajectory(data: Data(#"{"trajectory":{"generatorMetadata":[],"executorMetadatas":[{"cascadeConfig":{"plannerConfig":{"modelName":"gemini-3.1-pro-low"}}}]}}"#.utf8))
        precondition(empty.contextTokens == nil && empty.contextWindow == nil)
        precondition(empty.turns == 0 && empty.inputTokens == 0 && empty.outputTokens == 0)
        precondition(empty.model == "gemini-3.1-pro-low")

        precondition(AgyRPC.parseTrajectory(data: Data("not json".utf8)).contextTokens == nil)
    }

    private static func testAgyTrajectoryCache() {
        let sem = DispatchSemaphore(value: 0)
        Task {
            let cache = AgyTrajectoryCache()
            var calls = 0
            let acc = AgyRPC.TrajectoryAcc(model: "gemini-3.1-pro-low",
                                           contextTokens: 27_400, contextWindow: 2_000_000,
                                           inputTokens: 35_399, outputTokens: 1_935, turns: 2,
                                           turnCosts: [9_934, 27_400])
            let fetcher: AgyRPC.Fetch = { _, _, _ in
                calls += 1
                return trajectoryFixture()
            }
            let t1 = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let first = await cache.trajectory(convId: "c1", port: 1, changedAt: t1, fetcher: fetcher)
            precondition(first == acc)
            _ = await cache.trajectory(convId: "c1", port: 1, changedAt: t1, fetcher: fetcher)
            precondition(calls == 1, "an unchanged conversation must not be re-fetched")
            _ = await cache.trajectory(convId: "c1", port: 1,
                                       changedAt: t1.addingTimeInterval(60), fetcher: fetcher)
            precondition(calls == 2)
            let count1 = await cache.cachedCount
            precondition(count1 == 1)
            await cache.evict(keeping: ["other"])
            let count2 = await cache.cachedCount
            precondition(count2 == 0)
            sem.signal()
        }
        sem.wait()
    }

    private static func testAgyHistoryParsing() {
        let entry = AgyHistoryParsing.parse(
            line: #"{"display":"fix the geometry","timestamp":1787996740245,"workspace":"/Users/git/ee4","conversationId":"f68d3468"}"#)
        precondition(entry?.display == "fix the geometry")
        precondition(entry?.workspace == "/Users/git/ee4")
        precondition(entry?.conversationId == "f68d3468")
        precondition(entry?.timestampMs == 1_787_996_740_245)

        precondition(AgyHistoryParsing.parse(line: #"{"workspace":"/x"}"#) == nil,
                     "an entry without a conversationId is unusable identity and must be dropped")
        precondition(AgyHistoryParsing.parse(line: "not json") == nil)
    }

    private static func testAgyNewestSelection() {
        let started = Date()
        func entry(_ id: String, workspace: String, secondsAgo: Double) -> AgyHistoryEntry {
            AgyHistoryEntry(display: "prompt \(id)", workspace: workspace,
                            conversationId: id,
                            timestampMs: Int64((Date().addingTimeInterval(-secondsAgo)).timeIntervalSince1970 * 1000))
        }

        // An entry newer than the process start is confident identity.
        let live = AgyHistoryParsing.newest(
            entries: [entry("old", workspace: "/w", secondsAgo: 3600),
                      entry("new", workspace: "/w", secondsAgo: 30),
                      entry("other", workspace: "/elsewhere", secondsAgo: 1)],
            workspace: "/w", since: started.addingTimeInterval(-5))
        precondition(live?.conversationId == "new")

        // Nothing since the process start — a previous conversation in the
        // same workspace is still shown, as the labelled best guess it is.
        let stale = AgyHistoryParsing.newest(
            entries: [entry("old", workspace: "/w", secondsAgo: 3600)],
            workspace: "/w", since: started.addingTimeInterval(-5))
        precondition(stale?.conversationId == "old")

        // No history for this workspace at all — pending, not invented.
        let none = AgyHistoryParsing.newest(
            entries: [entry("other", workspace: "/elsewhere", secondsAgo: 1)],
            workspace: "/w", since: started)
        precondition(none == nil)
    }
}
