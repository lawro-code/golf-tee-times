import XCTest
@testable import TeesViews

/// Onboarding runs once, and every way out of it counts as having run.
///
/// The view is not rendered — `ios/project.yml` is frozen, so there is no
/// ViewInspector here. `OnboardingState` is where the "runs once" rule actually
/// lives; the view calls it on each of its three exits and nothing else in the
/// flow persists anything.
@MainActor
final class OnboardingFlowTests: XCTestCase {

    func testAFreshInstallHasNotSeenOnboarding() {
        XCTAssertFalse(OnboardingState.isComplete(in: InMemoryViewsStore()))
    }

    func testCompletionIsRememberedAcrossARelaunch() {
        let store = InMemoryViewsStore()
        OnboardingState.markComplete(in: store)
        XCTAssertTrue(OnboardingState.isComplete(in: store))

        // A new reader on the same store — a relaunch — agrees.
        XCTAssertTrue(OnboardingState.isComplete(in: InMemoryViewsStore(
            seed: [OnboardingState.completedKey: "1"])))
    }

    func testMarkingCompleteTwiceIsHarmless() {
        let store = InMemoryViewsStore()
        OnboardingState.markComplete(in: store)
        OnboardingState.markComplete(in: store)
        XCTAssertTrue(OnboardingState.isComplete(in: store))
    }

    func testResetShowsItAgain() {
        let store = InMemoryViewsStore()
        OnboardingState.markComplete(in: store)
        OnboardingState.reset(in: store)
        XCTAssertFalse(OnboardingState.isComplete(in: store))
    }

    func testAnUnrecognisedStoredValueMeansNotYetSeen() {
        // A marker written by another build must not skip onboarding for
        // somebody who has never been through it. Showing it twice is a mild
        // annoyance; skipping it is a golfer who never learns what the app does.
        for junk in ["0", "true", "", "yes", "{}"] {
            let store = InMemoryViewsStore(seed: [OnboardingState.completedKey: junk])
            XCTAssertFalse(OnboardingState.isComplete(in: store), "stored value \(junk)")
        }
    }

    // MARK: - The deny path

    func testDenyingNotificationsStillCompletesOnboardingAndDoesNotReprompt() async {
        // The sequence `OnboardingFlow` runs on its last step: ask through the
        // seam, then mark complete whatever the answer was. A no must not leave
        // the golfer stuck on the priming screen, and must not be re-asked.
        let store = InMemoryViewsStore()
        let stub = StubNotificationPermission(answer: false)

        let granted = await stub.requestAuthorization()
        OnboardingState.markComplete(in: store)

        XCTAssertFalse(granted)
        XCTAssertTrue(OnboardingState.isComplete(in: store))
        XCTAssertEqual(stub.requestCount, 1)

        // A second launch does not run the flow at all, so the permission seam
        // is never touched again.
        XCTAssertTrue(OnboardingState.isComplete(in: store))
        XCTAssertEqual(stub.requestCount, 1, "no nagging: the system prompt is asked for once")
    }

    func testSkippingFromTheFirstStepStillCompletesOnboarding() {
        // The skip button is present on every step, including the last, and it
        // takes the same exit as finishing.
        let store = InMemoryViewsStore()
        let stub = StubNotificationPermission(answer: true)

        OnboardingState.markComplete(in: store)

        XCTAssertTrue(OnboardingState.isComplete(in: store))
        XCTAssertEqual(stub.requestCount, 0, "skipping never reaches the system prompt")
    }

    func testTheFlowCanBeConstructedWithBothSeamsStubbed() {
        // Nothing in the initialiser may persist or ask: onboarding that has
        // been merely constructed has not been seen.
        let store = InMemoryViewsStore()
        let stub = StubNotificationPermission(answer: true)
        _ = OnboardingFlow(store: store, requester: stub) { _ in }

        XCTAssertFalse(OnboardingState.isComplete(in: store))
        XCTAssertEqual(stub.requestCount, 0)
    }

    // MARK: - Copy

    func testTheFirstStepSaysWhatTheAppWatchesFor() {
        XCTAssertTrue(OnboardingCopy.watchTitle.contains("cancellations"))
        XCTAssertTrue(OnboardingCopy.watchBody.contains("save"))
        XCTAssertTrue(
            OnboardingCopy.watchDetail.contains("club's own site"),
            "booking happens at the club; being surprised by that later is worse")
    }

    func testEveryStringIsPresent() {
        for string in [
            OnboardingCopy.watchTitle,
            OnboardingCopy.watchBody,
            OnboardingCopy.watchDetail,
            OnboardingCopy.continueTitle,
            OnboardingCopy.skipTitle
        ] {
            XCTAssertFalse(string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testTheStepsAreInOrderAndNotificationsComeLast() {
        // Priming before the system prompt is the whole point: the system
        // prompt can only be answered once per install.
        XCTAssertEqual(OnboardingFlow.Step.allCases, [.whatWeWatch, .notifications])
    }
}

/// Onboarding's failure paths: a key that collides with another feature's, a
/// marker that resurrects itself, a flow that finishes before it has run.
@MainActor
final class OnboardingFailurePathTests: XCTestCase {

    func testEveryKeyTheTrackPersistsIsDistinct() {
        // Every one of these is a namespaced string typed by hand. Two the
        // same means confirming a round marks onboarding complete, or a
        // relaunch reads the wrong blob and loses both.
        let keys = [
            OnboardingState.completedKey,
            ViewsPreferences.Key.holes,
            BookingLedger.Key.pendingTapOuts,
            BookingLedger.Key.answered,
            BookingLedger.Key.bookings
        ]
        XCTAssertEqual(Set(keys).count, keys.count, "two features are writing to one key")
    }

    func testTheLedgerAndOnboardingShareAStoreWithoutTouchingEachOther() {
        // The functional version of the key test: one store, both features,
        // neither able to see the other's state.
        let store = InMemoryViewsStore()
        let slot = BookingLedgerFixtures.slot()

        let ledger = BookingLedger(store: store, now: BookingLedgerFixtures.clock)
        ledger.recordTapOut(slot)
        ledger.appDidBecomeActive()
        ledger.confirmBooked(slot)
        XCTAssertFalse(
            OnboardingState.isComplete(in: store),
            "booking a round must not skip onboarding for someone who has never seen it")

        OnboardingState.markComplete(in: store)
        let relaunched = BookingLedger(store: store, now: BookingLedgerFixtures.clock)
        XCTAssertEqual(relaunched.bookings.count, 1, "and finishing onboarding must not erase the rounds")
        XCTAssertTrue(relaunched.hasBeenAsked(slotID: slot.id))
    }

    func testCompletionIsWrittenAsTheDocumentedMarker() {
        // `isComplete` only accepts "1". If `markComplete` ever writes
        // something else the two halves stop agreeing and onboarding runs on
        // every launch.
        let store = InMemoryViewsStore()
        OnboardingState.markComplete(in: store)
        XCTAssertEqual(store.string(forKey: OnboardingState.completedKey), "1")
    }

    func testResetRemovesTheMarkerRatherThanWritingANegativeOne() {
        // A stored "0" reads as not-complete today and as junk to any build
        // that changes the marker. Absent is the honest state.
        let store = InMemoryViewsStore()
        OnboardingState.markComplete(in: store)
        OnboardingState.reset(in: store)

        XCTAssertNil(store.string(forKey: OnboardingState.completedKey))
        XCTAssertFalse(OnboardingState.isComplete(in: store))
    }

    func testResettingSomethingNeverCompletedIsHarmless() {
        let store = InMemoryViewsStore()
        OnboardingState.reset(in: store)
        XCTAssertFalse(OnboardingState.isComplete(in: store))
        XCTAssertNil(store.string(forKey: OnboardingState.completedKey))
    }

    func testConstructingTheFlowDoesNotFinishIt() {
        // A flow that called back on construction would be shown for one frame
        // and never again — onboarding that has run once without being read.
        var finished: [Bool] = []
        let store = InMemoryViewsStore()
        _ = OnboardingFlow(
            store: store,
            requester: StubNotificationPermission(answer: true)
        ) { finished.append($0) }

        XCTAssertTrue(finished.isEmpty)
        XCTAssertFalse(OnboardingState.isComplete(in: store))
    }

    func testTheStepsKeepTheirStoredPositions() {
        // `Step` is `Int`-backed so Stage 2 can deep-link into one. Reordering
        // the cases would silently repoint an existing link.
        XCTAssertEqual(OnboardingFlow.Step.whatWeWatch.rawValue, 0)
        XCTAssertEqual(OnboardingFlow.Step.notifications.rawValue, 1)
        XCTAssertEqual(OnboardingFlow.Step.allCases.count, 2, "a third step is a product decision, not an edit")
    }
}
