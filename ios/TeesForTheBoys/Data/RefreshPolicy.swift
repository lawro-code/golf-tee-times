import Foundation

/// How stale the data on screen is.
///
/// Three states rather than a bool because the UI does three different things:
/// nothing, a quiet background refetch, and an explicit "this may be out of
/// date" banner. Track C reads this; it is the only staleness vocabulary in
/// the app.
public enum Staleness: String, Sendable, Hashable, CaseIterable {
    /// Recent enough to show without comment.
    case fresh
    /// Worth refetching behind the scenes, but keep showing what we have.
    case soft
    /// Old enough that a golfer could act on a tee time that is already gone.
    /// Say so.
    case hard
}

/// The numbers behind "when do we go back to the network".
///
/// They are named constants rather than literals buried in the store so that
/// track C and Stage 2 can tune them — and, more usefully, so that every one
/// of them can be argued with in one place.
///
/// The defaults follow from the settled scrape cadence, which is **every 20
/// minutes for days 0-2 and twice daily for days 3-5** and is not being
/// raised. Refetching faster than the server can possibly have new data just
/// spends battery and API quota to show the same bytes.
///
/// Every decision function here is pure, taking `now` as a parameter. No
/// `Date()` is called inside this type. That is what lets the tests assert on
/// a boundary instead of sleeping through it.
public struct RefreshPolicy: Sendable, Hashable {

    // MARK: - Defaults, with their reasons

    /// Half a scrape interval. Past this the server may well have something
    /// new, so refetch — quietly, still showing the cache.
    public static let defaultSoftStaleAfter: TimeInterval = 10 * 60

    /// Eighteen scrape intervals. Past this something is wrong — no signal,
    /// a dead scraper — and showing the data without a warning invites a
    /// wasted drive to a course whose tee sheet has moved on.
    public static let defaultHardStaleAfter: TimeInterval = 6 * 60 * 60

    /// The floor between network fetches. Tab switches, scroll-to-top, a
    /// screen reappearing and a push arriving can all ask for a refresh within
    /// the same second; the server's answer will not have changed.
    /// `refresh(force:)` is the deliberate way past this.
    public static let defaultMinimumFetchInterval: TimeInterval = 60

    /// 2s, 8s, 30s, 2min. Quick enough that a blip on the train recovers while
    /// the golfer is still looking at the screen, slow enough that a genuine
    /// outage is not hammered.
    public static let defaultBackoffLadder: [TimeInterval] = [2, 8, 30, 120]

    /// Beyond the ladder the wait keeps growing but stops here. A phone left
    /// in a pocket during a two-hour outage should still recover within
    /// fifteen minutes of the network coming back.
    public static let defaultMaximumBackoff: TimeInterval = 15 * 60

    /// ±20%. Everyone on the same train loses Wi-Fi in the same tunnel; if the
    /// backoff were exact they would all come back in step and arrive at the
    /// API as one spike.
    public static let defaultJitterFraction: Double = 0.2

    // MARK: - Stored

    public let softStaleAfter: TimeInterval
    public let hardStaleAfter: TimeInterval
    public let minimumFetchInterval: TimeInterval
    public let backoffLadder: [TimeInterval]
    public let maximumBackoff: TimeInterval
    public let jitterFraction: Double

    /// A per-install constant in `-1...1` that spreads this device's retries
    /// away from every other device's.
    ///
    /// Jitter is seeded rather than rolled per call on purpose. Rolling a
    /// random number inside `shouldRefresh` would make it non-deterministic
    /// and untestable, and would also mean a device could be told "not yet"
    /// and then "go" for the same instant. A seed gives the property that
    /// matters — two devices differ — while keeping one device's own answers
    /// reproducible.
    public let jitterSeed: Double

    public init(
        softStaleAfter: TimeInterval = RefreshPolicy.defaultSoftStaleAfter,
        hardStaleAfter: TimeInterval = RefreshPolicy.defaultHardStaleAfter,
        minimumFetchInterval: TimeInterval = RefreshPolicy.defaultMinimumFetchInterval,
        backoffLadder: [TimeInterval] = RefreshPolicy.defaultBackoffLadder,
        maximumBackoff: TimeInterval = RefreshPolicy.defaultMaximumBackoff,
        jitterFraction: Double = RefreshPolicy.defaultJitterFraction,
        jitterSeed: Double = Double.random(in: -1...1)
    ) {
        self.softStaleAfter = softStaleAfter
        self.hardStaleAfter = hardStaleAfter
        self.minimumFetchInterval = minimumFetchInterval
        self.backoffLadder = backoffLadder
        self.maximumBackoff = maximumBackoff
        self.jitterFraction = jitterFraction
        self.jitterSeed = min(max(jitterSeed, -1), 1)
    }

    /// The shipping policy. One seed per process, which is all the spreading
    /// a single device needs.
    public static let standard = RefreshPolicy()

    // MARK: - Staleness

    /// Pure function of the last successful fetch and an injected `now`.
    /// Never having fetched is `.hard`: we have nothing, and pretending
    /// otherwise would hide an empty screen behind a fresh-looking one.
    public func staleness(of lastFetch: Date?, now: Date) -> Staleness {
        guard let lastFetch else { return .hard }
        let age = now.timeIntervalSince(lastFetch)
        if age >= hardStaleAfter { return .hard }
        if age >= softStaleAfter { return .soft }
        return .fresh
    }

    // MARK: - Backoff

    /// The ladder value for a failure count, before jitter. `attempt` is the
    /// number of consecutive failures: 1 is the first.
    public func baseBackoff(attempt: Int) -> TimeInterval {
        guard attempt > 0, let last = backoffLadder.last else { return 0 }
        if attempt <= backoffLadder.count {
            return min(backoffLadder[attempt - 1], maximumBackoff)
        }
        // Past the ladder keep growing on the same curve the ladder implies
        // (roughly 4x a rung) until the cap takes over.
        let grown = last * pow(4.0, Double(attempt - backoffLadder.count))
        return min(grown, maximumBackoff)
    }

    /// The ladder value with this install's jitter applied.
    public func backoff(attempt: Int) -> TimeInterval {
        let base = baseBackoff(attempt: attempt)
        guard base > 0 else { return 0 }
        return max(0, base + base * jitterFraction * jitterSeed)
    }

    /// When a device that has failed `attempt` times in a row may try again.
    public func nextRetry(after lastFailure: Date, attempt: Int) -> Date {
        lastFailure.addingTimeInterval(backoff(attempt: attempt))
    }

    // MARK: - The decision

    /// Should we go to the network?
    ///
    /// Order matters, and it is: an explicit ask wins; then backoff, because a
    /// server that is failing should not be asked again just because the data
    /// is old; then the fetch floor; then staleness.
    ///
    /// - Parameters:
    ///   - lastFetch: when a fetch last succeeded, or nil if never.
    ///   - lastFailure: when a fetch last failed, or nil if the last one worked.
    ///   - attempt: consecutive failures so far. 0 after any success.
    ///   - now: injected. This type never reads the clock itself.
    ///   - force: pull-to-refresh. Bypasses everything here — but not the
    ///     store's single-flight, which is a separate guarantee.
    public func shouldRefresh(
        lastFetch: Date?,
        lastFailure: Date? = nil,
        attempt: Int = 0,
        now: Date,
        force: Bool = false
    ) -> Bool {
        if force { return true }

        if let lastFailure, attempt > 0 {
            if now < nextRetry(after: lastFailure, attempt: attempt) { return false }
        }

        guard let lastFetch else { return true }

        if now.timeIntervalSince(lastFetch) < minimumFetchInterval { return false }

        return staleness(of: lastFetch, now: now) != .fresh
    }
}
