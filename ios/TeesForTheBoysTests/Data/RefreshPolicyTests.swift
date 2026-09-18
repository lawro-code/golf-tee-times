import XCTest
@testable import TeesData

/// `RefreshPolicy` is pure by construction — every decision takes `now` as a
/// parameter — so every one of these asserts on an exact boundary rather than
/// sleeping up to it. If any of them ever needs a `Task.sleep`, the policy has
/// grown a clock and the tests have stopped being deterministic.
final class RefreshPolicyTests: XCTestCase {

    /// A fixed instant. Nothing here reads the real clock.
    private let t0 = Date(timeIntervalSince1970: 1_789_000_000)

    /// The shipping numbers with jitter pinned off, so a boundary is a
    /// boundary. Jitter gets its own tests below.
    private func policy(
        soft: TimeInterval = RefreshPolicy.defaultSoftStaleAfter,
        hard: TimeInterval = RefreshPolicy.defaultHardStaleAfter,
        floor: TimeInterval = RefreshPolicy.defaultMinimumFetchInterval,
        seed: Double = 0
    ) -> RefreshPolicy {
        RefreshPolicy(
            softStaleAfter: soft, hardStaleAfter: hard,
            minimumFetchInterval: floor, jitterSeed: seed)
    }

    // MARK: - The numbers themselves

    /// These are not arbitrary: they follow from the settled scrape cadence of
    /// every 20 minutes for days 0-2. If someone tunes them, this test is the
    /// place that makes them say so out loud.
    func testDefaultsFollowTheSettledScrapeCadence() {
        XCTAssertEqual(RefreshPolicy.defaultSoftStaleAfter, 10 * 60,
                       "soft stale is half a scrape interval")
        XCTAssertEqual(RefreshPolicy.defaultHardStaleAfter, 6 * 60 * 60)
        XCTAssertEqual(RefreshPolicy.defaultMinimumFetchInterval, 60)
        XCTAssertEqual(RefreshPolicy.defaultBackoffLadder, [2, 8, 30, 120])
        XCTAssertEqual(RefreshPolicy.defaultMaximumBackoff, 15 * 60)
        XCTAssertEqual(RefreshPolicy.defaultJitterFraction, 0.2)
    }

    // MARK: - Staleness

    func testStalenessBoundariesAreExact() {
        let p = policy()
        XCTAssertEqual(p.staleness(of: t0, now: t0), .fresh)
        XCTAssertEqual(p.staleness(of: t0, now: t0.addingTimeInterval(599)), .fresh)
        XCTAssertEqual(p.staleness(of: t0, now: t0.addingTimeInterval(600)), .soft,
                       "ten minutes is soft-stale, not nine minutes fifty-nine")
        XCTAssertEqual(p.staleness(of: t0, now: t0.addingTimeInterval(21_599)), .soft)
        XCTAssertEqual(p.staleness(of: t0, now: t0.addingTimeInterval(21_600)), .hard)
        XCTAssertEqual(p.staleness(of: t0, now: t0.addingTimeInterval(86_400)), .hard)
    }

    /// Never having fetched is not "fresh". An empty screen that claims to be
    /// current is the one reading a golfer must not be given.
    func testNeverFetchedIsHardStale() {
        XCTAssertEqual(policy().staleness(of: nil, now: t0), .hard)
    }

    /// A phone whose clock jumps backwards (manual change, NTP correction)
    /// produces a negative age. That must read as fresh, not wrap into a
    /// refresh storm.
    func testClockSkewBackwardsReadsAsFresh() {
        XCTAssertEqual(policy().staleness(of: t0, now: t0.addingTimeInterval(-3600)), .fresh)
    }

    // MARK: - shouldRefresh

    func testFirstLaunchRefreshes() {
        XCTAssertTrue(policy().shouldRefresh(lastFetch: nil, now: t0))
    }

    func testFreshDataIsNotRefetched() {
        XCTAssertFalse(policy().shouldRefresh(lastFetch: t0, now: t0.addingTimeInterval(120)))
    }

    func testSoftStaleDataIsRefetched() {
        XCTAssertTrue(policy().shouldRefresh(lastFetch: t0, now: t0.addingTimeInterval(601)))
    }

    /// The floor is what stops a tab switch, a scroll-to-top and a returning
    /// screen from each becoming a request. Tested against a policy tuned to
    /// refetch aggressively, because with the shipping ten-minute soft window
    /// the floor never gets a chance to be the reason.
    func testSixtySecondFloorBeatsStaleness() {
        let eager = policy(soft: 10, hard: 60)
        XCTAssertEqual(eager.staleness(of: t0, now: t0.addingTimeInterval(30)), .soft,
                       "precondition: staleness alone would say yes")
        XCTAssertFalse(eager.shouldRefresh(lastFetch: t0, now: t0.addingTimeInterval(30)),
                       "inside the floor, stale or not")
        XCTAssertFalse(eager.shouldRefresh(lastFetch: t0, now: t0.addingTimeInterval(59.9)))
        XCTAssertTrue(eager.shouldRefresh(lastFetch: t0, now: t0.addingTimeInterval(60)))
    }

    /// Pull-to-refresh. The user asking is better evidence than any timer.
    func testForceBypassesTheFloor() {
        let eager = policy(soft: 10, hard: 60)
        let inside = t0.addingTimeInterval(5)
        XCTAssertFalse(eager.shouldRefresh(lastFetch: t0, now: inside, force: false))
        XCTAssertTrue(eager.shouldRefresh(lastFetch: t0, now: inside, force: true))
    }

    func testForceBypassesBackoffToo() {
        let p = policy()
        let justFailed = t0.addingTimeInterval(1)
        XCTAssertFalse(p.shouldRefresh(
            lastFetch: nil, lastFailure: t0, attempt: 4, now: justFailed, force: false))
        XCTAssertTrue(p.shouldRefresh(
            lastFetch: nil, lastFailure: t0, attempt: 4, now: justFailed, force: true))
    }

    // MARK: - Backoff

    func testBackoffLengthensThenCaps() {
        let p = policy()
        XCTAssertEqual(p.baseBackoff(attempt: 1), 2)
        XCTAssertEqual(p.baseBackoff(attempt: 2), 8)
        XCTAssertEqual(p.baseBackoff(attempt: 3), 30)
        XCTAssertEqual(p.baseBackoff(attempt: 4), 120)

        // Past the ladder it keeps growing on the same curve...
        XCTAssertEqual(p.baseBackoff(attempt: 5), 480)
        // ...until fifteen minutes, and never past it. A phone that has been
        // in a pocket through an outage still recovers within a quarter hour.
        XCTAssertEqual(p.baseBackoff(attempt: 6), 900)
        XCTAssertEqual(p.baseBackoff(attempt: 20), 900)

        XCTAssertEqual(p.baseBackoff(attempt: 0), 0, "no failures, no wait")
        XCTAssertEqual(p.baseBackoff(attempt: -1), 0)
    }

    func testBackoffIsMonotonic() {
        let p = policy()
        var previous = p.baseBackoff(attempt: 1)
        for attempt in 2...12 {
            let current = p.baseBackoff(attempt: attempt)
            XCTAssertGreaterThanOrEqual(current, previous,
                                        "backoff went backwards at attempt \(attempt)")
            previous = current
        }
    }

    func testBackoffBlocksRetryUntilItHasElapsed() {
        let p = policy()                       // seed 0, so 2s means 2s
        XCTAssertFalse(p.shouldRefresh(
            lastFetch: nil, lastFailure: t0, attempt: 1, now: t0.addingTimeInterval(1.9)))
        XCTAssertTrue(p.shouldRefresh(
            lastFetch: nil, lastFailure: t0, attempt: 1, now: t0.addingTimeInterval(2)))

        // The fourth failure in a row buys two minutes of quiet.
        XCTAssertFalse(p.shouldRefresh(
            lastFetch: nil, lastFailure: t0, attempt: 4, now: t0.addingTimeInterval(119)))
        XCTAssertTrue(p.shouldRefresh(
            lastFetch: nil, lastFailure: t0, attempt: 4, now: t0.addingTimeInterval(120)))
    }

    /// Stale data is not a reason to hammer a server that is already failing.
    func testBackoffOutranksStaleness() {
        let p = policy()
        let dayOld = t0.addingTimeInterval(-86_400)
        XCTAssertEqual(p.staleness(of: dayOld, now: t0), .hard, "precondition")
        XCTAssertFalse(p.shouldRefresh(
            lastFetch: dayOld, lastFailure: t0, attempt: 3, now: t0.addingTimeInterval(5)))
        XCTAssertTrue(p.shouldRefresh(
            lastFetch: dayOld, lastFailure: t0, attempt: 3, now: t0.addingTimeInterval(31)))
    }

    /// A success is the caller's signal to pass `attempt: 0`, and at zero the
    /// ladder is gone entirely — not merely short.
    func testZeroAttemptsMeansNoBackoffAtAll() {
        let p = policy()
        XCTAssertTrue(p.shouldRefresh(
            lastFetch: nil, lastFailure: t0, attempt: 0, now: t0.addingTimeInterval(0.001)))
    }

    // MARK: - Jitter

    func testJitterIsBoundedAtTwentyPercent() {
        let high = RefreshPolicy(jitterSeed: 1)
        let low = RefreshPolicy(jitterSeed: -1)
        let none = RefreshPolicy(jitterSeed: 0)

        XCTAssertEqual(high.backoff(attempt: 4), 144, accuracy: 0.0001)   // 120 + 20%
        XCTAssertEqual(low.backoff(attempt: 4), 96, accuracy: 0.0001)     // 120 - 20%
        XCTAssertEqual(none.backoff(attempt: 4), 120, accuracy: 0.0001)
    }

    func testJitterSeedIsClamped() {
        XCTAssertEqual(RefreshPolicy(jitterSeed: 42).jitterSeed, 1)
        XCTAssertEqual(RefreshPolicy(jitterSeed: -42).jitterSeed, -1)
    }

    /// The property the jitter exists for: two installs that failed at the same
    /// instant do not come back at the same instant. Seeded rather than rolled
    /// per call, so one device's own answers stay reproducible — which is what
    /// makes every other test in this file possible.
    func testTwoInstallsDoNotRetryInStep() {
        let seeds = Set((0..<200).map { _ in RefreshPolicy().jitterSeed })
        XCTAssertGreaterThan(seeds.count, 100, "seeds are per-install, not a constant")
        for seed in seeds {
            XCTAssertLessThanOrEqual(abs(seed), 1)
        }

        let delays = seeds.map { RefreshPolicy(jitterSeed: $0).backoff(attempt: 4) }
        for delay in delays {
            XCTAssertGreaterThanOrEqual(delay, 96)
            XCTAssertLessThanOrEqual(delay, 144)
        }
    }

    func testOneInstallIsReproducible() {
        let p = RefreshPolicy(jitterSeed: 0.37)
        XCTAssertEqual(p.backoff(attempt: 3), p.backoff(attempt: 3))
        XCTAssertEqual(
            p.nextRetry(after: t0, attempt: 3),
            t0.addingTimeInterval(p.backoff(attempt: 3)))
    }

    // MARK: - Both gates, not just the first one that answers

    /// Backoff and the sixty-second floor are separate gates and a caller has
    /// to clear both. Backoff is checked first, so this is the case that
    /// catches an implementation which returns `true` the moment the backoff
    /// is satisfied: a server that fails, recovers and fails again would then
    /// be polled every two seconds, floor or no floor.
    func testTheFloorStillAppliesOnceBackoffHasElapsed() {
        let eager = policy(soft: 10, hard: 60)   // so staleness is never the blocker
        let failure = t0.addingTimeInterval(1)   // fetched at t0, failed a second later

        XCTAssertGreaterThanOrEqual(
            t0.addingTimeInterval(10), eager.nextRetry(after: failure, attempt: 1),
            "precondition: the two-second backoff is spent")
        XCTAssertFalse(
            eager.shouldRefresh(
                lastFetch: t0, lastFailure: failure, attempt: 1,
                now: t0.addingTimeInterval(10)),
            "backoff is clear but the floor is not, and the floor is still a no")
        XCTAssertTrue(
            eager.shouldRefresh(
                lastFetch: t0, lastFailure: failure, attempt: 1,
                now: t0.addingTimeInterval(60)),
            "both gates clear")
    }

    // MARK: - Misconfiguration must degrade towards trying, never towards never

    /// An empty ladder — a Stage 2 tuning that goes wrong, a config typo — has
    /// to mean "no wait", not "wait forever". The opposite reading is an app
    /// that silently stops refreshing for the rest of its life after one
    /// failed request, which is indistinguishable from a hang.
    func testAnEmptyBackoffLadderMeansNoWaitRatherThanForever() {
        let p = RefreshPolicy(backoffLadder: [], jitterSeed: 0)

        XCTAssertEqual(p.baseBackoff(attempt: 1), 0)
        XCTAssertEqual(p.baseBackoff(attempt: 9), 0)
        XCTAssertEqual(p.nextRetry(after: t0, attempt: 3), t0, "retry now, not never")
        XCTAssertTrue(p.shouldRefresh(lastFetch: nil, lastFailure: t0, attempt: 3, now: t0))
    }

    /// A phone that failed in a pocket all night arrives at a very high attempt
    /// count, and the growth past the ladder is exponential: `pow(4, 9e18)` is
    /// infinity. Uncapped, that is a retry date hundreds of millions of years
    /// out and an app that never comes back. It has to still be fifteen
    /// minutes, and it has to be a real number.
    func testALongOutageCannotOverflowTheBackoffIntoNever() {
        let p = policy()
        for attempt in [10, 100, 10_000, Int.max] {
            let wait = p.baseBackoff(attempt: attempt)
            XCTAssertTrue(wait.isFinite, "attempt \(attempt) produced \(wait)")
            XCTAssertEqual(wait, 900, "the fifteen-minute cap holds at attempt \(attempt)")
        }

        let retry = p.nextRetry(after: t0, attempt: Int.max)
        XCTAssertEqual(retry, t0.addingTimeInterval(900))
        XCTAssertTrue(
            p.shouldRefresh(
                lastFetch: nil, lastFailure: t0, attempt: Int.max,
                now: t0.addingTimeInterval(900)),
            "after the longest wait the policy allows, the phone tries again")
    }

    /// Jitter subtracts as well as adds. A fraction tuned past 1.0 with an
    /// unlucky seed would make the wait negative — and a negative wait is a
    /// retry date in the past, which is the hammering the backoff exists to
    /// prevent.
    func testJitterCanNeverProduceANegativeWait() {
        let overtuned = RefreshPolicy(jitterFraction: 3, jitterSeed: -1)

        XCTAssertEqual(overtuned.backoff(attempt: 4), 0, "clamped at zero, never below")
        XCTAssertGreaterThanOrEqual(
            overtuned.nextRetry(after: t0, attempt: 4).timeIntervalSince(t0), 0,
            "a retry date is never in the past")
    }
}
