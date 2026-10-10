import Foundation

// MARK: - Adaptive poll cadence
// Adapts poll cadence based on local agent session activity and quota movement.
enum PollPolicy {
    enum Tier: String, Equatable {
        /// Polls at user-configured rate while a session is actively working.
        case active
        /// Intermediate polling rate when quota moves while local sessions are idle.
        case drifting
        /// Infrequent polling rate when local sessions and quota are idle.
        case quiet
    }

    /// Duration following the last turn during which a session is considered active.
    static let activityWindow: TimeInterval = 600

    /// Extended active window for agy sessions to accommodate idle pauses between cascades.
    static let agyActivityWindow: TimeInterval = 1800

    static let driftingCap: TimeInterval = 600      // 10 minutes
    static let quietCap: TimeInterval = 3600        // 1 hour
    static let backoffCap: TimeInterval = 3600

    private static let driftingMultiplier: Double = 5
    private static let quietMultiplier: Double = 30

    nonisolated static func isActive(_ sessions: [AgentSession], now: Date) -> Bool {
        sessions.contains { session in
            if session.busy { return true }
            guard let last = session.lastActivityAt else { return false }
            // Reject clock skew or future-dated records.
            let age = now.timeIntervalSince(last)
            let window = session.kind == .agy ? agyActivityWindow : activityWindow
            return age >= 0 && age <= window
        }
    }

    nonisolated static func tier(sessionsActive: Bool, usageChanged: Bool) -> Tier {
        if sessionsActive { return .active }
        return usageChanged ? .drifting : .quiet
    }

    /// Computes poll interval for given tier, floored at configured base interval.
    nonisolated static func interval(base: TimeInterval, tier: Tier) -> TimeInterval {
        switch tier {
        case .active: return base
        case .drifting: return max(base, min(base * driftingMultiplier, driftingCap))
        case .quiet: return max(base, min(base * quietMultiplier, quietCap))
        }
    }

    /// Calculates exponential backoff interval following rate limit errors.
    nonisolated static func backedOff(_ interval: TimeInterval, consecutiveRateLimits: Int) -> TimeInterval {
        guard consecutiveRateLimits > 0 else { return interval }
        // Cap exponent before power calculation to avoid arithmetic overflow.
        let exponent = min(consecutiveRateLimits, 8)
        let penalised = interval * pow(2, Double(exponent))
        // Bound penalised interval without reducing intervals already configured above backoffCap.
        return min(penalised, max(backoffCap, interval))
    }

    /// Determines whether menu open warrants refresh ahead of idle tier schedule.
    nonisolated static func shouldRefreshOnOpen(age: TimeInterval, base: TimeInterval) -> Bool {
        age > base
    }

    /// Returns fingerprint of Claude usage percentages to detect remote quota movement.
    nonisolated static func usageFingerprint(_ cards: [Card]) -> String {
        guard let claude = cards.first(where: { $0.provider == ProviderID.claude.displayName }) else {
            return ""
        }
        return claude.rows
            .map { "\($0.label)=\($0.percent.map(String.init) ?? "-")" }
            .joined(separator: ",")
    }
}

// MARK: - Self-tests

enum PollPolicySelfTests {
    static func run() {
        testTierSelection()
        testIntervalLadder()
        testBackoff()
        testRefreshOnOpen()
        testFingerprint()
        testActivity()
    }

    private static func testTierSelection() {
        precondition(PollPolicy.tier(sessionsActive: true, usageChanged: true) == .active)
        precondition(PollPolicy.tier(sessionsActive: true, usageChanged: false) == .active,
                     "a live session outranks the numbers standing still")
        precondition(PollPolicy.tier(sessionsActive: false, usageChanged: true) == .drifting)
        precondition(PollPolicy.tier(sessionsActive: false, usageChanged: false) == .quiet)
    }

    private static func testIntervalLadder() {
        // The shipping default: 2 min working, 10 min drifting, 1 hour quiet.
        let base: TimeInterval = 120
        precondition(PollPolicy.interval(base: base, tier: .active) == 120)
        precondition(PollPolicy.interval(base: base, tier: .drifting) == 600)
        precondition(PollPolicy.interval(base: base, tier: .quiet) == 3600)

        // A faster base scales down with it rather than snapping to the caps.
        precondition(PollPolicy.interval(base: 60, tier: .drifting) == 300)
        precondition(PollPolicy.interval(base: 60, tier: .quiet) == 1800)

        // Caps hold for a slower base…
        precondition(PollPolicy.interval(base: 300, tier: .drifting) == 600)
        precondition(PollPolicy.interval(base: 300, tier: .quiet) == 3600)

        // …and no tier may ever poll more often than the user asked for.
        for tier in [PollPolicy.Tier.active, .drifting, .quiet] {
            for base in [60.0, 120.0, 300.0, 900.0, 3600.0, 7200.0] {
                precondition(PollPolicy.interval(base: base, tier: tier) >= base,
                             "tier \(tier.rawValue) must never undercut the configured interval")
            }
        }
    }

    private static func testBackoff() {
        precondition(PollPolicy.backedOff(120, consecutiveRateLimits: 0) == 120)
        precondition(PollPolicy.backedOff(120, consecutiveRateLimits: 1) == 240)
        precondition(PollPolicy.backedOff(120, consecutiveRateLimits: 2) == 480)
        precondition(PollPolicy.backedOff(120, consecutiveRateLimits: 3) == 960)

        // Backing off must never increase polling frequency.
        precondition(PollPolicy.backedOff(7200, consecutiveRateLimits: 2) == 7200)
    }

    private static func testRefreshOnOpen() {
        // Refresh if menu opened after active rate.
        precondition(PollPolicy.shouldRefreshOnOpen(age: 180, base: 120))
        // Do not refresh if opened too soon.
        precondition(!PollPolicy.shouldRefreshOnOpen(age: 30, base: 120))
        // Refresh only if age exceeds base.
        precondition(!PollPolicy.shouldRefreshOnOpen(age: 120, base: 120))
        precondition(PollPolicy.shouldRefreshOnOpen(age: 121, base: 120))
        // Base rate is the floor.
        precondition(!PollPolicy.shouldRefreshOnOpen(age: 180, base: 300))
    }

    private static func testFingerprint() {
        func claudeCard(_ percents: [Int?]) -> Card {
            Card(provider: "Claude",
                 rows: percents.enumerated().map { Row(label: "w\($0.offset)", percent: $0.element, detail: "") })
        }
        let a = PollPolicy.usageFingerprint([claudeCard([30, 84])])
        precondition(a == PollPolicy.usageFingerprint([claudeCard([30, 84])]), "same numbers, same fingerprint")
        precondition(a != PollPolicy.usageFingerprint([claudeCard([31, 84])]), "a moved percent must register")

        // An unknown percent is its own state, distinct from any number —
        // it must not collapse onto 0 and read as "unchanged" forever.
        precondition(PollPolicy.usageFingerprint([claudeCard([nil])])
                     != PollPolicy.usageFingerprint([claudeCard([0])]))

        // Codex movement is invisible here on purpose: it costs the Anthropic
        // Codex activity does not affect Claude polling.
        let withCodex = [claudeCard([30, 84]),
                         Card(provider: "Codex", rows: [Row(label: "Weekly", percent: 99, detail: "")])]
        precondition(PollPolicy.usageFingerprint(withCodex) == a)

        // Stable state when no Claude card present.
        precondition(PollPolicy.usageFingerprint([]) == PollPolicy.usageFingerprint([]))
    }

    private static func testActivity() {
        let now = Date()
        precondition(!PollPolicy.isActive([], now: now), "No sessions is not activity")

        let busy = makeSession(busy: true, lastActivityAt: now.addingTimeInterval(-99_999))
        precondition(PollPolicy.isActive([busy], now: now), "Busy counts even with old timestamp")

        let justFinished = makeSession(busy: false, lastActivityAt: now.addingTimeInterval(-60))
        precondition(PollPolicy.isActive([justFinished], now: now),
                     "Gap between turns is active time")

        let stale = makeSession(busy: false, lastActivityAt: now.addingTimeInterval(-PollPolicy.activityWindow - 1))
        precondition(!PollPolicy.isActive([stale], now: now))

        let never = makeSession(busy: false, lastActivityAt: nil)
        precondition(!PollPolicy.isActive([never], now: now))

        // A future-dated record must not read as permanently active.
        let skewed = makeSession(busy: false, lastActivityAt: now.addingTimeInterval(86_400))
        precondition(!PollPolicy.isActive([skewed], now: now))

        // One live session among idle ones is enough.
        precondition(PollPolicy.isActive([stale, never, justFinished], now: now))

        // agy reports IDLE between cascades while quota still burns, so its
        // window is deliberately 3× the generic one.
        let agyMidTurn = makeSession(kind: .agy, busy: false,
                                     lastActivityAt: now.addingTimeInterval(-PollPolicy.activityWindow - 1))
        precondition(PollPolicy.isActive([agyMidTurn], now: now),
                     "agy stays active past the 600s generic window")
        let agyStale = makeSession(kind: .agy, busy: false,
                                   lastActivityAt: now.addingTimeInterval(-PollPolicy.agyActivityWindow - 1))
        precondition(!PollPolicy.isActive([agyStale], now: now))
        // …and the longer window must not leak onto other kinds.
        precondition(!PollPolicy.isActive([makeSession(kind: .codex, busy: false,
                                                       lastActivityAt: agyMidTurn.lastActivityAt)],
                                         now: now))
    }
}
