import SwiftUI
import XCTest
@testable import TeesViews

/// **What these tests can and cannot do.**
///
/// `ios/project.yml` is frozen for Stage 1, so the track has no ViewInspector
/// and no snapshot library. A SwiftUI `body` therefore cannot be asserted on:
/// there is no supported way to ask what a rendered view contains. Pretending
/// otherwise — reflecting over `Mirror(reflecting: view.body)` and matching
/// strings — produces a test that breaks on an Xcode update and proves nothing
/// in between.
///
/// So this file proves the two things that are real:
///
/// 1. **The initialisers exist with the shapes they were promised.** Three
///    other tickets call these. Constructing each one here is a compile-time
///    assertion, and a rename or a lost `public` breaks this file.
/// 2. **`ViewsStaleBanner` is a pure function of `FreshnessSummary`** — which
///    *is* tested, in `FreshnessSummaryTests`.
///
/// Every other decision in these views was deliberately pushed out into
/// `SlotFormatting` and `FreshnessSummary` for exactly this reason.
final class StateViewsTests: XCTestCase {

    /// Constructing the view is the assertion. This just keeps the result used
    /// so the construction cannot be elided, and names the concrete type in a
    /// failure message.
    private func describe<V: View>(_ view: V) -> String {
        String(describing: type(of: view))
    }

    // MARK: - The initialisers are the contract

    func testLoadingStateTakesAMessage() {
        XCTAssertEqual(describe(ViewsLoadingState(message: "Finding tee times")), "ViewsLoadingState")
    }

    /// Generic over the action so a caller can pass a button, two buttons, or
    /// nothing, without this type having an opinion about any of them.
    func testEmptyStateAcceptsAnyActionIncludingNone() {
        let withNothing = ViewsEmptyState(title: "No rounds", message: "Try another day") {
            EmptyView()
        }
        let withButton = ViewsEmptyState(title: "No rounds", message: "Try another day") {
            Button("Clear filters") {}
        }
        let withTwo = ViewsEmptyState(title: "No rounds", message: "Try another day") {
            Button("Clear filters") {}
            Button("Pick a day") {}
        }
        XCTAssertTrue(describe(withNothing).contains("EmptyView"), describe(withNothing))
        XCTAssertTrue(describe(withButton).contains("Button"), describe(withButton))
        XCTAssertTrue(describe(withTwo).contains("TupleView"), describe(withTwo))
    }

    /// Retry is optional because not everything that fails is worth trying
    /// again, and a button that cannot help is worse than no button.
    func testErrorStateRetryIsOptional() {
        var tapped = 0
        let retrying = ViewsErrorState(title: "Something broke", message: "\u{2026}") { tapped += 1 }
        let terminal = ViewsErrorState(title: "Something broke", message: "\u{2026}", retry: nil)
        XCTAssertEqual(describe(retrying), "ViewsErrorState")
        XCTAssertEqual(describe(terminal), "ViewsErrorState")
        XCTAssertEqual(tapped, 0, "constructing the view must not fire the action")
    }

    /// Building an empty state runs its `@ViewBuilder`, which builds the
    /// button — it must not *press* it. "No rounds match" with a clear-filters
    /// button that clears the filters on sight would be a loop the golfer
    /// cannot get out of.
    func testConstructingAnEmptyStateDoesNotFireItsAction() {
        var cleared = 0
        let view = ViewsEmptyState(title: "No rounds", message: "Try another day") {
            Button("Clear filters") { cleared += 1 }
        }
        XCTAssertTrue(describe(view).contains("Button"), describe(view))
        XCTAssertEqual(cleared, 0, "constructing the view pressed the button")
    }

    func testOfflineBannerTakesNothing() {
        XCTAssertEqual(describe(ViewsOfflineBanner()), "ViewsOfflineBanner")
    }

    // MARK: - The stale banner is a pure function of the summary

    /// The banner renders exactly when `bannerText` is non-nil, so a caller can
    /// place it unconditionally and the decision stays in one tested place.
    /// These assertions are on that decision, not on the rendering of it.
    func testStaleBannerShowsNothingWhenEverythingIsFreshAndReached() {
        XCTAssertNil(FreshnessSummary.unknown.bannerText)
        XCTAssertEqual(describe(ViewsStaleBanner(summary: .unknown)), "ViewsStaleBanner")
    }

    func testStaleBannerHasSomethingToSayWhenAClubCouldNotBeReached() throws {
        let summary = FreshnessSummary(
            lastSuccessAt: Date(timeIntervalSince1970: 1_790_803_800),
            failedCourseSlugs: ["castle-cove"],
            failedCourseNames: ["Castle Cove"],
            healthyButEmptyCourseSlugs: [],
            healthyButEmptyCourseNames: [],
            isStale: false,
            bannerText: "Couldn't reach Castle Cove")
        XCTAssertEqual(try XCTUnwrap(summary.bannerText), "Couldn't reach Castle Cove")
        XCTAssertEqual(describe(ViewsStaleBanner(summary: summary)), "ViewsStaleBanner")
    }
}
