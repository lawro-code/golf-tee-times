import SwiftUI
import UIKit
import XCTest
import TeesContract
@testable import TeesViews

/// The regression this guards: `SearchScreen.content(presentation:sections:)`'s
/// `.loading` and `.failed` branches apply `.frame(maxHeight: .infinity)`
/// directly to their content, which SwiftUI centres by default. The `.empty`
/// branch instead routes through `emptyState`, which wraps the same-shaped
/// content in a bare `ScrollView` and only then applies the same frame
/// modifier — to the `ScrollView`, not to the content. A `ScrollView` always
/// lays its content out at the top of its scroll axis regardless of the frame
/// it is given, so the empty state alone, of the four, sits pinned under the
/// filter bar instead of centred in the space above the tab bar.
///
/// `ios/project.yml` is frozen — no ViewInspector, no snapshot library — so
/// this measures the real, un-mocked view the same way
/// `AlertFromSearchButtonLayoutTests` does: hosted in a `UIHostingController`
/// and laid out for real. Centred-vs-pinned is a position, which
/// `sizeThatFits` cannot report, so this instead checks for the one thing a
/// `ScrollView` uniquely puts in the hierarchy: a real `UIScrollView`.
/// `content(presentation:sections:)` is measured directly — not the whole
/// screen — specifically so `FilterBar`'s own horizontally scrolling chip row
/// (a `ScrollView` present in every one of the four states, via
/// `SearchScreen.topChrome`) can never be mistaken for this one.
@MainActor
final class SearchScreenEmptyStateLayoutTests: XCTestCase {

    private let fixedNow = ContractDate.date(from: "2099-10-03T00:00:00+10:00")!

    private func screen() -> SearchScreen {
        let now = fixedNow
        let store = SearchStore(preferences: InMemoryViewsStore(), fixture: "minimal", now: { now })
        store.load()
        return SearchScreen(
            store: store,
            ledger: BookingLedger(store: InMemoryViewsStore(), now: { self.fixedNow }),
            isSignedIn: true,
            onCreateWatch: { _ in true },
            onRequireSignIn: {})
    }

    /// The screen's own choice of coordinate width (`AlertFromSearchButtonLayoutTests
    /// .screenWidth`) and a plausible height for the space between the filter
    /// bar and the tab bar — comfortably taller than the empty state's own
    /// content, which is the whole point: there is real slack to place it in.
    private let width: CGFloat = 393
    private let height: CGFloat = 700

    /// Whether any real `UIScrollView` exists anywhere in the hosted view's
    /// hierarchy, walked after a real layout pass.
    private func hostedViewContainsAScrollView<V: View>(_ view: V) -> Bool {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        controller.view.layoutIfNeeded()
        let found = Self.containsScrollView(controller.view)
        window.isHidden = true
        return found
    }

    private static func containsScrollView(_ view: UIView) -> Bool {
        if view is UIScrollView { return true }
        return view.subviews.contains { containsScrollView($0) }
    }

    /// The bug, reproduced: `SearchStore.state == .loaded` with
    /// `resultCount == 0` is the ticket's own repro — every course scraped
    /// cleanly and simply had nothing free, which is exactly what
    /// `Presentation.empty` means. This is the one state, of the four, that
    /// must not put a `ScrollView` — and so a `UIScrollView` — in the
    /// hierarchy: nothing here needs to scroll, and putting it in a scroll
    /// container is what pins it to the top instead of centring it.
    func testEmptyStateContentHasNoScrollViewUnlikeAScrollableList() {
        let content = screen().content(presentation: .empty, sections: [])

        XCTAssertFalse(
            hostedViewContainsAScrollView(content),
            "the .empty state's content contains a UIScrollView — it is pinned to the top of a "
                + "ScrollView instead of centred the way .loading and .failed are")
    }

    /// The two states right next to `.empty` in the same switch statement, as
    /// a control: today, correctly, neither one puts a `ScrollView` in the
    /// hierarchy, which is exactly the treatment `.empty` is missing.
    func testLoadingAndFailedHaveNoScrollViewEither() {
        let loading = screen().content(presentation: .loading, sections: [])
        let failed = screen().content(presentation: .failed("offline"), sections: [])

        XCTAssertFalse(hostedViewContainsAScrollView(loading), "the .loading state unexpectedly contains a ScrollView")
        XCTAssertFalse(hostedViewContainsAScrollView(failed), "the .failed state unexpectedly contains a ScrollView")
    }

    /// The one state that *should* scroll, as the other half of the control:
    /// 1755 rows cannot all render at once, so `.results` must keep its real
    /// `List` (itself `UITableView`-backed, hence a `UIScrollView`) — this
    /// test would fail just as loudly if the fix accidentally reached into
    /// `resultsList` instead of `emptyState`.
    func testResultsStillContainsAScrollViewBecauseTheListMustScroll() {
        let results = screen().content(presentation: .results(1), sections: [])

        XCTAssertTrue(
            hostedViewContainsAScrollView(results),
            "the .results state lost its scrollable List")
    }
}
