import XCTest
@testable import TeesViews

/// The permission seam and the copy.
///
/// **Nothing here reaches `UNUserNotificationCenter`.** The system prompt can be
/// answered once per install: a test that touched the real centre would either
/// hang waiting for a tap that never comes or burn that one chance. Every test
/// below goes through `StubNotificationPermission`, which is the entire reason
/// the protocol exists.
@MainActor
final class NotificationPrimingTests: XCTestCase {

    func testTheStubReportsAGrant() async {
        let stub = StubNotificationPermission(answer: true)
        let granted = await stub.requestAuthorization()
        XCTAssertTrue(granted)
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testTheStubReportsADenial() async {
        let stub = StubNotificationPermission(answer: false)
        let granted = await stub.requestAuthorization()
        XCTAssertFalse(granted)
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testTheStubCountsEveryAsk() async {
        let stub = StubNotificationPermission(answer: false)
        _ = await stub.requestAuthorization()
        _ = await stub.requestAuthorization()
        XCTAssertEqual(stub.requestCount, 2, "the count is what proves the screen asks once")
    }

    func testTheScreenTakesTheSeamRatherThanTheSystemCentre() {
        // Construction alone: if the initialiser reached the real centre this
        // would be the line that hung.
        let stub = StubNotificationPermission(answer: false)
        _ = NotificationPrimingScreen(requester: stub) { _ in }
        XCTAssertEqual(stub.requestCount, 0, "nothing is asked until the golfer taps")
    }

    func testTheLiveImplementationConformsWithoutBeingCalled() {
        // Proves the protocol is satisfiable by the shipping type. It is never
        // invoked in a test.
        let live: NotificationPermissionRequesting = SystemNotificationPermission()
        let stub: NotificationPermissionRequesting = StubNotificationPermission(answer: false)
        XCTAssertFalse(live === stub)
    }

    // MARK: - Copy

    func testThePrimingCopySaysWhatTheNotificationIsFor() {
        // The system prompt that follows says "Tees would like to send you
        // notifications", which tells nobody anything. This screen is the one
        // that has to earn the yes.
        let body = NotificationPrimingCopy.body
        XCTAssertTrue(body.contains("cancels"), "it has to name what opens a tee time up")
        XCTAssertTrue(body.contains("alerts"), "it has to connect the notification to a saved alert")
        XCTAssertFalse(body.contains("\n"), "one paragraph; the line continuations are for the source, not the screen")
    }

    func testThePrimingCopyPromisesNothingElse() {
        XCTAssertTrue(NotificationPrimingCopy.reassurance.contains("No daily digest"))
    }

    func testSayingNoCostsNothingAndSaysSo() {
        XCTAssertEqual(NotificationPrimingCopy.skipTitle, "Not now")
        let footer = NotificationPrimingCopy.skipFooter
        XCTAssertTrue(footer.contains("still search"), "a no must not read like a penalty")
        XCTAssertTrue(footer.contains("later"), "and it must say the door stays open")
    }

    func testEveryStringIsPresent() {
        // Warnings are errors and an empty label ships silently, so this is the
        // cheap guard against one going missing in an edit.
        for string in [
            NotificationPrimingCopy.title,
            NotificationPrimingCopy.body,
            NotificationPrimingCopy.reassurance,
            NotificationPrimingCopy.allowTitle,
            NotificationPrimingCopy.skipTitle,
            NotificationPrimingCopy.skipFooter
        ] {
            XCTAssertFalse(string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// What the priming screen must not do, and what its copy must not promise.
///
/// The screen's own `ask()` is unreachable from a test — `ios/project.yml` is
/// frozen, so there is no ViewInspector and no way to press a button. What can
/// be pinned is that construction alone neither asks nor decides, and that the
/// promise the copy makes matches the cadence the scraper actually runs.
@MainActor
final class NotificationPrimingFailurePathTests: XCTestCase {

    func testBuildingTheScreenNeitherAsksNorDecides() {
        // A screen that asked in its initialiser would burn the install's one
        // chance at the system prompt before the golfer had read a word of the
        // reason for it; one that called back early would skip the screen.
        let stub = StubNotificationPermission(answer: true)
        var decisions: [Bool] = []
        _ = NotificationPrimingScreen(requester: stub) { decisions.append($0) }

        XCTAssertEqual(stub.requestCount, 0, "nothing is asked until the golfer taps")
        XCTAssertTrue(decisions.isEmpty, "and the flow does not move on before there is an answer")
    }

    func testThePrimingCopyPromisesTheCadenceTheScraperActuallyRuns() {
        // The scrape cadence is settled at twenty minutes for the near days.
        // Copy that promises faster is a promise the backend does not keep.
        let body = NotificationPrimingCopy.body.lowercased()
        XCTAssertTrue(
            body.contains("every twenty minutes"),
            "the screen earning the yes has to say how often we look")
        for overclaim in ["every minute", "every five minutes", "instantly", "the second", "real time", "real-time"] {
            XCTAssertFalse(body.contains(overclaim), "copy promises \(overclaim), which is not the cadence")
        }
    }

    func testThePrimingCopyDoesNotThreatenTheGolferWhoSaysNo() {
        // A "not now" that comes with a cost is not a real choice, and a
        // cornered yes is the thing priming exists to avoid.
        let footer = NotificationPrimingCopy.skipFooter.lowercased()
        for threat in ["won't be able", "cannot", "can't use", "required", "must"] {
            XCTAssertFalse(footer.contains(threat), "the skip footer reads like a penalty: \(threat)")
        }
        XCTAssertFalse(NotificationPrimingCopy.skipTitle.lowercased().contains("never"))
    }

    func testTheCopyNeverNamesAMarketingMessage() {
        // The reassurance is the whole basis of the yes. If the body ever
        // starts describing a digest or an offer, the reassurance is a lie.
        let everything = [
            NotificationPrimingCopy.title,
            NotificationPrimingCopy.body,
            NotificationPrimingCopy.allowTitle
        ].joined(separator: " ").lowercased()
        for word in ["digest", "newsletter", "offer", "deal", "promotion"] {
            XCTAssertFalse(everything.contains(word), "the screen promises no \(word) and must not describe one")
        }
    }
}
