import SwiftUI
import XCTest
import TeesContract
@testable import TeesViews

/// What the search screen would render, asserted on the values it renders from.
///
/// `ios/project.yml` is frozen for Stage 1, so there is no ViewInspector and no
/// snapshot library in the project — a SwiftUI `body` cannot be reached from a
/// test. The screen is therefore written so that everything worth asserting is
/// a value first: `SearchScreen.Presentation` is the state selection the body
/// switches on, and `store.sections` is the exact array the list iterates. Test
/// those and the body is thin enough to read.
///
/// Everything runs against `minimal.json` on a fixed clock. The fixture's dates
/// are constants — 3, 4 and 10 October 2026 — so "Today" and "Tomorrow" are
/// assertions rather than whatever day the CI machine thinks it is.
@MainActor
final class SearchScreenTests: XCTestCase {

    /// Midnight on the fixture's first day, so `today` is 2026-10-03 and every
    /// one of that day's tee times (earliest 06:16) is still ahead of the
    /// clock — `SlotQuery.apply` drops anything whose `tee_at` is not, so a
    /// later instant would quietly age fixture rows out of these assertions.
    private let fixedNow = ContractDate.date(from: "2026-10-03T00:00:00+10:00")!

    private let day1 = "2026-10-03"
    private let day2 = "2026-10-04"
    private let day3 = "2026-10-10"

    private func loadedStore(_ filters: SearchFilters? = nil) -> SearchStore {
        let now = fixedNow
        let store = SearchStore(
            preferences: InMemoryViewsStore(),
            fixture: "minimal",
            now: { now })
        store.load()
        if let filters { store.filters = filters }
        return store
    }

    private func ledger() -> BookingLedger {
        BookingLedger(store: InMemoryViewsStore(), now: { self.fixedNow })
    }

    // MARK: - The sections the list renders

    /// CONTRACT.md §2 through the whole screen: the default search is 18 holes,
    /// so the fixture's three 9-hole bookings — two at Woollahra, one at
    /// Bankstown, which is an 18-hole club — are not on screen.
    func testDefaultSearchRendersOnlyEighteenHoleBookings() {
        let store = loadedStore()

        XCTAssertEqual(store.resultCount, 5)
        XCTAssertEqual(store.sections.count, 3)
        XCTAssertEqual(store.sections.map(\.date), [day1, day2, day3])
        XCTAssertEqual(store.sections.map(\.results.count), [3, 1, 1])

        for section in store.sections {
            for result in section.results {
                XCTAssertEqual(result.slot.holes, 18, "\(result.id) is not an 18-hole booking")
            }
        }
    }

    /// The day headings the screen shows come from `store.today`, not from a
    /// clock the view reads for itself. CONTRACT.md §4 resolves Sydney once on
    /// the server; a screen deriving its own calendar day is how a heading ends
    /// up a day out.
    func testDayHeadingsAreRelativeToTheStoresToday() {
        let store = loadedStore()

        XCTAssertEqual(store.today, day1)
        XCTAssertEqual(store.sections.map(\.title), ["Today", "Tomorrow", "Sat 10 Oct"])
    }

    /// Warringah sends a 1st Tee group and a 10th Tee group out at 06:16 on the
    /// same morning. Both are bookable, both are on screen, and the order they
    /// appear in is the same every launch.
    func testATwoTeeStartIsTwoRowsInAStableOrder() {
        let store = loadedStore()
        let firstDay = store.sections[0].results.map(\.id)

        XCTAssertEqual(firstDay, [
            "warringah:2026-10-03:0616:10th-tee-social",
            "warringah:2026-10-03:0616:1st-tee-social",
            "the-coast:2026-10-03:0800:1st-tee"
        ])
    }

    /// CONTRACT.md §3. Warringah publishes no fee, and a $60 ceiling must not
    /// be what removes it from the list.
    func testAPriceCeilingStillRendersUnpricedRows() {
        var filters = SearchFilters.standard
        filters.maxPrice = 60
        let store = loadedStore(filters)

        let ids = store.sections.flatMap { $0.results.map(\.id) }
        XCTAssertTrue(ids.contains("warringah:2026-10-03:0616:1st-tee-social"))
        XCTAssertTrue(ids.contains("warringah:2026-10-03:0616:10th-tee-social"))

        // And they sink to the bottom of their own day rather than vanishing.
        // The Coast is $55 and both Warringah rows are unpriced, so the first
        // day is one priced row followed by two unpriced ones.
        let firstDay = store.sections[0].results
        XCTAssertEqual(firstDay.map(\.priceIsUnknown), [false, true, true])
    }

    /// Rule 8 of the ticket, and CONTRACT.md §2 behind it: a first run has 18
    /// holes already chosen, not "any".
    func testHolesIsEighteenOnAFirstRun() {
        let store = loadedStore()
        XCTAssertEqual(store.filters.holes, .eighteen)
        XCTAssertEqual(store.filters.activeCount, 0, "the default must not read as a filter")
    }

    // MARK: - Which of the four states is on screen

    func testIdleAndLoadingBothPresentAsLoading() {
        XCTAssertEqual(SearchScreen.Presentation(state: .idle, resultCount: 0), .loading)
        XCTAssertEqual(SearchScreen.Presentation(state: .loading, resultCount: 0), .loading)
    }

    /// `.idle` presenting as loading rather than as empty matters: "we have not
    /// looked yet" and "there is nothing" are different claims, and showing the
    /// second one first reads as a broken screen.
    func testIdleIsNotMistakenForEmpty() {
        XCTAssertNotEqual(SearchScreen.Presentation(state: .idle, resultCount: 0), .empty)
    }

    func testFailureCarriesItsReasonThrough() {
        let presentation = SearchScreen.Presentation(state: .failed("fixture wat is not in the bundle"), resultCount: 0)
        XCTAssertEqual(presentation, .failed("fixture wat is not in the bundle"))
    }

    func testLoadedWithNoResultsIsEmptyAndWithResultsIsResults() {
        XCTAssertEqual(SearchScreen.Presentation(state: .loaded, resultCount: 0), .empty)
        XCTAssertEqual(SearchScreen.Presentation(state: .loaded, resultCount: 5), .results(5))
    }

    /// A real filter combination that matches nothing, rather than a
    /// hand-built state: a day the scrape never covered.
    func testAFilterMatchingNothingReachesTheEmptyPresentation() {
        var filters = SearchFilters.standard
        filters.days = ["2026-12-25"]
        let store = loadedStore(filters)

        XCTAssertEqual(store.resultCount, 0)
        XCTAssertTrue(store.sections.isEmpty)
        XCTAssertEqual(
            SearchScreen.Presentation(state: store.state, resultCount: store.resultCount),
            .empty)
    }

    // MARK: - Which alert button the screen shows

    /// The ticket's rule: a search that returns nothing is the moment an alert
    /// is worth the most, so the empty state gets the loud button.
    func testEmptyResultsTakeThePrimaryProminence() {
        XCTAssertEqual(SearchScreen.Presentation.empty.alertProminence, .primary)
    }

    func testResultsTakeTheInlineProminence() {
        XCTAssertEqual(SearchScreen.Presentation.results(5).alertProminence, .inline)
    }

    /// The pinned bar appears only over results. In the empty state the same
    /// button is already the primary action, and two of them is a screen
    /// arguing with itself.
    func testTheInlineBarAppearsOnlyOverResults() {
        XCTAssertTrue(SearchScreen.Presentation.results(1).showsInlineAlertButton)
        XCTAssertFalse(SearchScreen.Presentation.empty.showsInlineAlertButton)
        XCTAssertFalse(SearchScreen.Presentation.loading.showsInlineAlertButton)
        XCTAssertFalse(SearchScreen.Presentation.failed("nope").showsInlineAlertButton)
    }

    // MARK: - The empty state's copy

    /// CONTRACT.md §5. Long Reef scraped perfectly and had nothing free; that
    /// is a sentence the golfer is owed, and it is a different sentence from
    /// the "couldn't reach" banner above the list.
    func testEmptyMessageNamesAClubWeReachedThatHadNothing() {
        let store = loadedStore()
        let message = SearchScreen.emptyMessage(freshness: store.freshness)

        XCTAssertEqual(store.freshness.emptyClubsText, "Long Reef has nothing free")
        XCTAssertTrue(message.contains("Long Reef has nothing free"), message)
        XCTAssertTrue(message.contains("alert"), message)
    }

    /// And a club that failed is *not* reported as empty — it belongs in the
    /// stale banner, which names it separately.
    func testAFailedClubIsNotReportedAsHavingNothingFree() {
        let store = loadedStore()

        XCTAssertEqual(store.freshness.failedCourseNames, ["Castle Cove"])
        XCTAssertFalse(store.freshness.healthyButEmptyCourseNames.contains("Castle Cove"))
        XCTAssertTrue(store.freshness.bannerText?.contains("Castle Cove") == true)
    }

    func testEmptyMessageSaysNothingAboutClubsWhenNoneWereEmpty() {
        let message = SearchScreen.emptyMessage(freshness: .unknown)
        XCTAssertFalse(message.contains("nothing free"), message)
        XCTAssertTrue(message.contains("alert"), message)
    }

    // MARK: - Construction

    func testScreenConstructsWithItsPublicInit() {
        let view: any View = SearchScreen(
            store: loadedStore(),
            ledger: ledger(),
            isSignedIn: false,
            onCreateWatch: { _ in true },
            onRequireSignIn: {})
        XCTAssertTrue(view is SearchScreen)
    }
}

// MARK: - Tester's pass, ticket C2

/// What the screen does when the search, or the load behind it, goes wrong.
///
/// The suite above builds most of its `Presentation` values by hand. These
/// drive them through a real `SearchStore` instead, because the three ways this
/// screen can mislead a golfer all come from the store and the screen
/// disagreeing about what "nothing on screen" means.
@MainActor
final class SearchScreenFailurePathTests: XCTestCase {

    /// Midnight on the fixture's first day — see `SearchScreenTests.fixedNow`
    /// for why it has to sit before that day's earliest tee time rather than,
    /// say, 8am.
    private let fixedNow = ContractDate.date(from: "2026-10-03T00:00:00+10:00")!

    private func makeStore(fixture: String, filters: SearchFilters? = nil) -> SearchStore {
        let now = fixedNow
        let store = SearchStore(
            preferences: InMemoryViewsStore(),
            fixture: fixture,
            now: { now })
        store.load()
        if let filters { store.filters = filters }
        return store
    }

    private func ledger() -> BookingLedger {
        BookingLedger(store: InMemoryViewsStore(), now: { self.fixedNow })
    }

    /// A load that failed has zero results, and zero results is exactly what
    /// the empty state looks for. Rendering "Nothing open for this search" over
    /// a fixture we never opened tells a golfer the fifteen clubs are full when
    /// the truth is that we did not look — and offers an alert as the fix for a
    /// problem an alert cannot fix.
    func testAFailedLoadIsNeverPresentedAsAnEmptySearch() {
        let store = makeStore(fixture: "no-such-fixture")

        XCTAssertEqual(store.resultCount, 0)
        XCTAssertTrue(store.sections.isEmpty)

        let presentation = SearchScreen.Presentation(
            state: store.state, resultCount: store.resultCount)

        XCTAssertNotEqual(presentation, .empty, "a failed load rendered as an empty search")
        guard case .failed(let reason) = presentation else {
            return XCTFail("expected .failed, got \(presentation)")
        }
        XCTAssertFalse(reason.isEmpty, "the error state has nothing to tell the golfer")
        XCTAssertFalse(presentation.showsInlineAlertButton)
    }

    /// CONTRACT.md §5 inside the empty state's own copy. Long Reef scraped
    /// perfectly and had nothing free; Castle Cove returned an error. Naming
    /// the second one here would be inventing a fact about a club we never
    /// reached — that club belongs to the stale banner, which says something
    /// different about it.
    func testTheEmptyMessageNeverNamesAClubWeCouldNotReach() {
        let store = makeStore(fixture: "minimal")
        let message = SearchScreen.emptyMessage(freshness: store.freshness)

        XCTAssertEqual(store.freshness.failedCourseNames, ["Castle Cove"])
        XCTAssertTrue(message.contains("Long Reef"), message)
        XCTAssertFalse(
            message.contains("Castle Cove"),
            "a club we could not reach was reported as having nothing free: \(message)")
    }

    /// CONTRACT.md §3 taken to its limit. A ceiling under every published fee
    /// removes every priced round and leaves only the ones no club priced — so
    /// the screen is in `.results`, not `.empty`, and the unpriced rows are
    /// still there to be booked. This is the 17% of inventory the rule exists
    /// to protect, at the one setting where losing it would look plausible.
    func testACeilingUnderEveryPublishedFeeStillShowsTheUnpricedRounds() {
        var filters = SearchFilters.standard
        filters.maxPrice = 1
        let store = makeStore(fixture: "minimal", filters: filters)

        XCTAssertEqual(store.resultCount, 2)
        XCTAssertEqual(store.sections.count, 1)
        XCTAssertEqual(
            store.sections.flatMap { $0.results.map(\.id) },
            [
                "warringah:2026-10-03:0616:10th-tee-social",
                "warringah:2026-10-03:0616:1st-tee-social"
            ])
        for result in store.sections.flatMap(\.results) {
            XCTAssertTrue(result.priceIsUnknown, "\(result.id) survived a $1 ceiling with a price")
        }

        let presentation = SearchScreen.Presentation(
            state: store.state, resultCount: store.resultCount)
        XCTAssertEqual(presentation, .results(2))
        XCTAssertTrue(presentation.showsInlineAlertButton)
        XCTAssertEqual(presentation.alertProminence, .inline)
    }

    // MARK: - "Try again" must retry, not fabricate

    /// A device with no cache and a fetch that has already failed — a fresh
    /// install in airplane mode, or a cold launch during a Supabase outage.
    /// `SearchStore.apply(payload: nil, errorDescription:)` is exactly what
    /// `AppSession.apply(_:)` calls on that path.
    private func failedLiveStore() -> SearchStore {
        let now = fixedNow
        let store = SearchStore(preferences: InMemoryViewsStore(), now: { now })
        store.apply(payload: nil, errorDescription: "offline")
        return store
    }

    /// The regression this guards: `SearchScreen`'s "Try again" used to be
    /// hardcoded to `{ store.load() }`, which unconditionally replays the
    /// bundled `golden` fixture — no network call, no retry, and no sign
    /// anything was faked. Tapping the one button the error screen offers
    /// silently swapped 1755 rows of sample data in for a fetch that never
    /// happened. A caller that wires a real retry (as `AppSession` does, into
    /// `TeeTimeStore.refresh(force:)`) must have that retry run instead — and
    /// the store must be left exactly as it was, not quietly reloaded with
    /// fixture data alongside it.
    func testTryAgainRunsTheInjectedRetryInsteadOfReloadingTheBundledFixture() {
        let store = failedLiveStore()
        XCTAssertEqual(store.state, .failed("offline"))

        var retryCount = 0
        let screen = SearchScreen(
            store: store,
            ledger: ledger(),
            isSignedIn: false,
            onCreateWatch: { _ in true },
            onRequireSignIn: {},
            onRetry: { retryCount += 1 })

        screen.onRetry()

        XCTAssertEqual(retryCount, 1, "\"Try again\" must call the injected retry action")
        XCTAssertEqual(
            store.state, .failed("offline"),
            "\"Try again\" reloaded the bundled fixture instead of only running the injected retry")
        XCTAssertNil(store.payload, "the bundled fixture must not have been loaded behind the retry's back")
    }

    /// The other half of the same seam: with no live retry supplied — a
    /// preview, or a fixture-only test — falling back to `store.load()` is
    /// the only honest thing a fixture-backed store can do, so that fallback
    /// must still work.
    func testTryAgainFallsBackToTheFixtureLoaderWhenNoRetryIsSupplied() {
        let now = fixedNow
        let store = SearchStore(preferences: InMemoryViewsStore(), fixture: "minimal", now: { now })
        store.apply(payload: nil, errorDescription: "offline")
        XCTAssertEqual(store.state, .failed("offline"))

        let screen = SearchScreen(
            store: store,
            ledger: ledger(),
            isSignedIn: false,
            onCreateWatch: { _ in true },
            onRequireSignIn: {})

        screen.onRetry()

        XCTAssertEqual(store.state, .loaded, "the fallback retry should have reloaded the fixture")
    }

    /// The day headings are relative to the store's clock, not to the position
    /// of the section in the list. Move the clock forward past the fixture's
    /// first day and that section drops out entirely — correctly: every one of
    /// its tee times has now passed, and a passed tee time is not inventory
    /// (`SlotQueryTests.testASlotThatHasAlreadyTeedOffIsExcludedEvenThoughItMatchesEveryFilter`).
    /// What is left is the regression this test actually guards: the section
    /// that is now first in the list must be labelled "Today" because it *is*
    /// today, not because a renderer assumed index 0 always is, and the one
    /// after it must get its real weekday rather than "Tomorrow" just for
    /// following "Today" in the array.
    func testTheDayHeadingsFollowTheClockRatherThanThePositionInTheList() {
        // Day one's last tee time is 11:20 on the 3rd; this instant is after
        // all of it and before day two's 09:45, so day one is gone and day two
        // is what "Today" now means.
        let laterNow = ContractDate.date(from: "2026-10-04T00:00:00+10:00")!
        let store = SearchStore(
            preferences: InMemoryViewsStore(),
            fixture: "minimal",
            now: { laterNow })
        store.load()

        XCTAssertEqual(store.today, "2026-10-04")
        XCTAssertEqual(store.sections.map(\.date), ["2026-10-04", "2026-10-10"])
        XCTAssertEqual(store.sections.map(\.title), ["Today", "Sat 10 Oct"])
    }
}
