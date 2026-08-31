import Foundation

// MARK: - Adaptive poll cadence
//
// The Anthropic usage endpoint rate-limits aggressively, and a fixed 2-minute
// poll spends the same budget at 3am as it does mid-session. This picks the
// next interval from two signals the app already has for free:
//
//   * whether any agent session is actually doing something (local: ps plus
//     transcript mtimes, no network),
//   * whether the numbers moved since the last poll, which is the only visible
//     evidence that another machine is spending the same quota.
//
// Pure and nonisolated throughout so the whole ladder is fixture-testable
// without a timer, a network call or a clock.
enum PollPolicy {
    enum Tier: String, Equatable {
        /// A session is live and working — poll at the user's chosen rate.
        case active
        /// Nothing running here, but the quota is still moving, so something
        /// elsewhere is using it and the numbers on screen are worth keeping
        /// roughly current.
        case drifting
        /// Nothing running, nothing moving. Check back rarely.
        case quiet
    }

    /// A session counts as active for a while after its last turn, not only
    /// while `busy` is true: the gap between "you sent a prompt" and "you are
    /// reading the answer and about to send another" is still working time,
    /// and dropping to an hourly poll inside it would be wrong.
    static let activityWindow: TimeInterval = 600

    /// agy spends long stretches reporting IDLE between cascades while quota
    /// keeps burning, and `lastUserInputTime` routinely drifts past the 600s
    /// generic window mid-task — which dropped a mid-turn agy machine to the
    /// hourly tier. agy sessions get three times the patience before the
    /// ladder is allowed to call them idle.
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
            // Guard against a clock skew or a future-dated record making a
            // long-dead session look permanently active.
            let age = now.timeIntervalSince(last)
            let window = session.kind == .agy ? agyActivityWindow : activityWindow
            return age >= 0 && age <= window
        }
    }

    nonisolated static func tier(sessionsActive: Bool, usageChanged: Bool) -> Tier {
        if sessionsActive { return .active }
        return usageChanged ? .drifting : .quiet
    }

    /// The user's configured interval is the *active* rate — "how often while
    /// I'm working" — and the idle tiers scale off it rather than replacing
    /// it, so the setting keeps meaning something. Each tier is also floored
    /// at the base: someone who deliberately sets a 15-minute poll must never
    /// be silently polled more often than that.
    nonisolated static func interval(base: TimeInterval, tier: Tier) -> TimeInterval {
        switch tier {
        case .active: return base
        case .drifting: return max(base, min(base * driftingMultiplier, driftingCap))
        case .quiet: return max(base, min(base * quietMultiplier, quietCap))
        }
    }

    /// Exponential backoff after a 429. Without this the app answered a
    /// rate-limit by knocking at exactly the same rate, which is what kept the
    /// "stale — rate limited" badge up: the poll that would have cleared it
    /// was itself being rejected.
    nonisolated static func backedOff(_ interval: TimeInterval, consecutiveRateLimits: Int) -> TimeInterval {
        guard consecutiveRateLimits > 0 else { return interval }
        // Cap the exponent before it reaches pow(), not after — 2^N for a
        // large N overflows to infinity and loses the min() comparison.
        let exponent = min(consecutiveRateLimits, 8)
        let penalised = interval * pow(2, Double(exponent))
        // The cap is a ceiling on the *penalty*, not on the interval itself:
        // clamping straight to backoffCap would speed polling up for anyone
        // whose configured interval is already slower than an hour, which is
        // the exact opposite of backing off.
        return min(penalised, max(backoffCap, interval))
    }

    /// Opening the menu is a strong statement of intent, so it may refresh
    /// ahead of an idle tier's schedule — but never faster than the active
    /// rate. (A Claude 429 storm no longer throttles this decision: backoff
    /// is enforced per-provider via `claudeNextPollAt` in refresh(), where
    /// agy/Codex/OpenRouter are free to refresh while Claude sits out.)
    nonisolated static func shouldRefreshOnOpen(age: TimeInterval, base: TimeInterval) -> Bool {
        age > base
    }

    /// What "the numbers moved" means, as a comparable value.
    ///
    /// Deliberately Claude-only: this whole ladder exists to protect the
    /// Anthropic usage endpoint, and "someone else is burning the quota" is a
    /// statement about that account. Codex percentages come from local rollout
    /// logs and move whenever you use Codex — folding them in here would hold
    /// the app at a 10-minute Claude poll because of activity that costs the
    /// Claude endpoint nothing.
    ///
    /// A failed poll leaves the previous rows in place (see
    /// `UsageMenuBar.merge`), so the fingerprint is unchanged and a broken
    /// endpoint decays toward the quiet tier rather than being mistaken for
    /// movement.
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

        // Saturates at the cap instead of running away, and a very large count
        // must not overflow through pow() into infinity.
        precondition(PollPolicy.backedOff(120, consecutiveRateLimits: 30) == PollPolicy.backoffCap)
        precondition(PollPolicy.backedOff(3600, consecutiveRateLimits: 5) == PollPolicy.backoffCap)
        precondition(PollPolicy.backedOff(120, consecutiveRateLimits: 99).isFinite)

        // An interval already above the cap is left alone rather than reduced —
        // backing off must never speed polling up.
        precondition(PollPolicy.backedOff(7200, consecutiveRateLimits: 2) == 7200)
    }

    private static func testRefreshOnOpen() {
        // Quiet tier, menu opened after 3 minutes: refresh, because the user
        // is looking at it and 3 min is past the 2 min active rate.
        precondition(PollPolicy.shouldRefreshOnOpen(age: 180, base: 120))
        // Opened again 30s later: do not.
        precondition(!PollPolicy.shouldRefreshOnOpen(age: 30, base: 120))
        // The active rate itself is the floor — exactly-at-base does not
        // refresh, just past it does.
        precondition(!PollPolicy.shouldRefreshOnOpen(age: 120, base: 120))
        precondition(PollPolicy.shouldRefreshOnOpen(age: 121, base: 120))
        // A slower configured base is respected: 3 minutes is still inside
        // a 5-minute active rate.
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
        // endpoint nothing and must not pin the poll to the drifting tier.
        let withCodex = [claudeCard([30, 84]),
                         Card(provider: "Codex", rows: [Row(label: "Weekly", percent: 99, detail: "")])]
        precondition(PollPolicy.usageFingerprint(withCodex) == a)

        // No Claude card at all (hidden, or never polled) is stable, not a
        // value that flip-flops and holds the app in the drifting tier.
        precondition(PollPolicy.usageFingerprint([]) == PollPolicy.usageFingerprint([]))
    }

    private static func testActivity() {
        let now = Date()
        precondition(!PollPolicy.isActive([], now: now), "no sessions is not activity")

        let busy = makeSession(busy: true, lastActivityAt: now.addingTimeInterval(-99_999))
        precondition(PollPolicy.isActive([busy], now: now), "busy counts even with an old timestamp")

        let justFinished = makeSession(busy: false, lastActivityAt: now.addingTimeInterval(-60))
        precondition(PollPolicy.isActive([justFinished], now: now),
                     "the gap between turns is still working time")

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
