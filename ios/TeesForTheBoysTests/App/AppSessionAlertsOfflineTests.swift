import XCTest
@testable import TeesForTheBoys

/// Regression coverage for: a signed-in golfer's alert list was
/// indistinguishable from genuinely having zero alerts when it failed to
/// load offline — no error, no retry, ever, until a full relaunch.
///
/// `refreshAlerts()` (`AppSession.swift`) used to catch a failed
/// `watchRepository.list()` and do nothing but log it — `alerts` stayed at
/// its initial `[]`, which is exactly what a genuinely alert-free account
/// also looks like, and nothing on `AppSession` said otherwise.
/// `applyWatchesOutcome(_:)` is where that result now lands, and it is fed
/// directly here rather than through a real fetch: `AppSession` builds its
/// `WatchRepository` off a real `SupabaseClient` with no seam for swapping in
/// a fake one — unlike `TeeTimeStore`, which `makeTeeTimeStore` makes fully
/// injectable — so a fabricated outcome is the only way to pin this failure
/// path without a network.
@MainActor
final class AppSessionAlertsOfflineTests: XCTestCase {

    private struct AlertsLoadTestFailure: Error {}

    /// The shape the bug hid inside: before any fetch is even attempted,
    /// `alerts` is already `[]` — the same value a failed load leaves behind.
    func testFreshSessionStartsWithNoAlertsAndNoFailure() {
        let session = AppSession()
        XCTAssertTrue(session.alerts.isEmpty)
        XCTAssertFalse(
            session.alertsLoadFailed,
            "a session that has never even tried a fetch must not read as a failed one")
    }

    /// The reported defect, directly: a failed fetch must not look identical
    /// to a genuinely empty one. Before this fix there was no flag at all —
    /// `alerts.isEmpty` was the only signal `AccountScreen` had, for both.
    func testAFailedFetchLeavesAlertsEmptyButFlagsTheFailure() {
        let session = AppSession()

        session.applyWatchesOutcome(.failure(AlertsLoadTestFailure()))

        XCTAssertTrue(
            session.alerts.isEmpty,
            "a failed fetch has nothing to show — but that emptiness must be flagged, not silent")
        XCTAssertTrue(
            session.alertsLoadFailed,
            "AccountScreen's 'No alerts yet' copy and a failed offline load are now indistinguishable")
    }

    /// The retry path this bug also lacked: once a golfer is back online and
    /// retries, a real result — even a legitimately empty one — must clear
    /// the flag, or the error banner outlives the problem it reported.
    func testASucceedingRetryClearsThePreviousFailure() {
        let session = AppSession()
        session.applyWatchesOutcome(.failure(AlertsLoadTestFailure()))
        XCTAssertTrue(session.alertsLoadFailed, "precondition: the failure must have registered")

        session.applyWatchesOutcome(.success([]))

        XCTAssertFalse(
            session.alertsLoadFailed,
            "a successful retry — even one that legitimately finds zero alerts — must clear the failure flag")
    }

    /// Signing out already resets `alerts`; the failure flag has to go with
    /// it, or a golfer who signs into a different account could see a
    /// "couldn't load" banner left over from a session that was never theirs.
    func testSigningOutClearsAPendingFailureTooNotJustTheList() {
        let session = AppSession()
        session.applyWatchesOutcome(.failure(AlertsLoadTestFailure()))

        session.clearUserData()

        XCTAssertTrue(session.alerts.isEmpty)
        XCTAssertFalse(session.alertsLoadFailed)
    }
}
