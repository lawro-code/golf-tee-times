import TeesContract
import XCTest
@testable import TeesViews

/// What one tap decides.
///
/// `tap()` is the button's whole behaviour hoisted out of the `Button` action
/// so it can be asserted: `ios/project.yml` is frozen, there is no
/// ViewInspector, and the alternative — trusting that the closure inside the
/// body does what the comment above it says — is how the wall ends up in front
/// of search by accident.
@MainActor
final class AlertFromSearchButtonTests: XCTestCase {

    private let today = "2026-09-16"

    private func draft(_ filters: SearchFilters = .standard) -> WatchDraft {
        WatchDraft(filters: filters, courses: [], today: today)
    }

    // MARK: - The wall

    /// Signed out, the tap asks for an account and creates nothing. Creating
    /// the watch first and asking afterwards would mean a watch with no owner.
    func testASignedOutTapAsksForSignInAndCreatesNothing() async {
        var created: [WatchDraft] = []
        var signInRequests = 0

        let button = AlertFromSearchButton(
            draft: draft(),
            prominence: .inline,
            isSignedIn: false,
            onCreate: { created.append($0); return true },
            onRequireSignIn: { signInRequests += 1 }
        )

        let outcome = await button.tap()
        XCTAssertEqual(outcome, .signInRequired)
        XCTAssertEqual(signInRequests, 1)
        XCTAssertTrue(created.isEmpty, "A signed-out tap must not create a watch")
    }

    /// Signed in, the tap creates the watch and nothing asks for a sign-in.
    func testASignedInTapCreatesTheWatchAndNeverAsksForSignIn() async {
        var created: [WatchDraft] = []
        var signInRequests = 0
        let watch = draft(SearchFilters(timesOfDay: [.morning]))

        let button = AlertFromSearchButton(
            draft: watch,
            prominence: .inline,
            isSignedIn: true,
            onCreate: { created.append($0); return true },
            onRequireSignIn: { signInRequests += 1 }
        )

        let outcome = await button.tap()
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(signInRequests, 0)
        XCTAssertEqual(created.count, 1)
        // The watch handed out is the one the button was showing — same
        // identity, so what was confirmed on screen is what gets saved.
        XCTAssertEqual(created.first?.id, watch.id)
        XCTAssertEqual(created.first?.sentence, "Alert me when a morning tee time opens")
    }

    /// The regression this guards: `tap()` used to report `.created` the
    /// instant `onCreate` was *called*, never once waiting to find out
    /// whether the save behind it — a network request — actually succeeded.
    /// That is what let `AlertFromSearchButton`'s button show a permanent
    /// "Alert saved" checkmark for a watch that had just failed to save
    /// (offline, DNS failure, Supabase down, a dropped connection). `onCreate`
    /// now reports whether the create landed, and `tap()` must wait for that
    /// answer and refuse to call it `.created` when the answer is no.
    func testATapThatFailsToSaveIsNeverReportedAsCreated() async {
        let button = AlertFromSearchButton(
            draft: draft(SearchFilters(timesOfDay: [.morning])),
            prominence: .inline,
            isSignedIn: true,
            onCreate: { _ in false }, // the network create failed
            onRequireSignIn: {}
        )

        let outcome = await button.tap()

        XCTAssertEqual(
            outcome, .failed,
            "A failed save must never be reported as .created — that is the flag the button uses to show \"Alert saved\"")
    }

    // MARK: - One tap, whatever it looks like

    /// `.primary` and `.inline` are the same button wearing different clothes.
    /// A difference in what they *do* would be a second code path for the most
    /// important action in the app.
    func testProminenceChangesTheLookAndNothingElse() async {
        for prominence in [AlertFromSearchButton.Prominence.inline, .primary] {
            var created = 0
            var signInRequests = 0
            let button = AlertFromSearchButton(
                draft: draft(),
                prominence: prominence,
                isSignedIn: true,
                onCreate: { _ in created += 1; return true },
                onRequireSignIn: { signInRequests += 1 }
            )
            let outcome = await button.tap()
            XCTAssertEqual(outcome, .created)
            XCTAssertEqual(created, 1)
            XCTAssertEqual(signInRequests, 0)
        }
    }

    /// A standard filter set is a legitimate watch — "tell me when anything
    /// opens" — and it is the one a first-time user is most likely to create.
    /// The button is never disabled for it.
    func testAnUntouchedFilterSetStillCreatesAWatch() async {
        var created: [WatchDraft] = []
        let button = AlertFromSearchButton(
            draft: draft(.standard),
            prominence: .primary,
            isSignedIn: true,
            onCreate: { created.append($0); return true },
            onRequireSignIn: {}
        )

        let outcome = await button.tap()
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(created.first?.sentence, "Alert me when any tee time opens")
    }

    // MARK: - The filters moving underneath the confirmation

    /// The bug this test exists for: the bar lives in `SearchScreen`'s bottom
    /// safe area with a stable identity, so a confirmation that is never
    /// cleared follows the golfer from Saturday mornings to Sunday twilight —
    /// still naming the Saturday watch, and standing where the button to create
    /// the Sunday one should be.
    func testChangingTheFiltersClearsTheConfirmation() {
        let saved = draft(SearchFilters(days: ["2026-09-19"], timesOfDay: [.morning]))

        let survivor = AlertFromSearchButton.survivingConfirmation(
            saved,
            filtersNow: SearchFilters(
                days: ["2026-09-20"], timesOfDay: [.twilight], courseSlugs: ["long-reef"]))

        XCTAssertNil(survivor, "A confirmation must not outlive the search it describes")
    }

    /// Even a change back to the untouched filter set clears it: "Alert me when
    /// any tee time opens" is a different watch from the one on screen.
    func testClearingTheFiltersAlsoClearsTheConfirmation() {
        let saved = draft(SearchFilters(timesOfDay: [.morning]))
        XCTAssertNil(AlertFromSearchButton.survivingConfirmation(saved, filtersNow: .standard))
    }

    /// Filters that still describe the saved watch keep it — adjusting the
    /// alert to Sunday twilight and then searching Sunday twilight leaves a
    /// confirmation that is still true. The same watch comes back, not a copy.
    func testFiltersThatStillDescribeTheWatchKeepTheConfirmation() {
        let filters = SearchFilters(days: ["2026-09-20"], timesOfDay: [.twilight])
        let saved = draft(filters)

        let survivor = AlertFromSearchButton.survivingConfirmation(saved, filtersNow: filters)

        XCTAssertEqual(survivor?.id, saved.id)
        XCTAssertEqual(survivor?.sentence, saved.sentence)
    }

    /// A watch adjusted away from the search it came from is a stale claim as
    /// soon as the search moves again, however it moves.
    func testAnAdjustedWatchIsClearedWhenTheSearchMovesOn() {
        let adjusted = draft(SearchFilters(timesOfDay: [.earlyMorning]))
        XCTAssertNil(
            AlertFromSearchButton.survivingConfirmation(
                adjusted, filtersNow: SearchFilters(timesOfDay: [.morning])))
    }

    /// Nothing showing stays nothing showing: the button is already on screen
    /// and a filter change must not conjure a confirmation.
    func testNoConfirmationSurvivesAsNoConfirmation() {
        XCTAssertNil(
            AlertFromSearchButton.survivingConfirmation(
                nil, filtersNow: SearchFilters(timesOfDay: [.midday])))
    }

    /// The empty state's headline is the draft's own sentence, so the two can
    /// never disagree about what the button is offering to watch for.
    func testThePrimaryProminenceCarriesTheEmptyStateSentence() {
        let watch = draft(SearchFilters(timesOfDay: [.twilight]))
        XCTAssertEqual(
            watch.emptySentence, "No twilight tee times \u{2014} alert me when one opens.")
        XCTAssertFalse(watch.sentence.isEmpty)
    }
}
