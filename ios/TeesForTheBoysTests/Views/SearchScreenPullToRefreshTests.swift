import SwiftUI
import UIKit
import XCTest
import TeesContract
@testable import TeesViews

/// Regression coverage for: once the launch-time fetch fails while a payload
/// is already cached, nothing on `SearchScreen` lets a golfer ask for fresh
/// data again.
///
/// `AppSession.apply` only ever surfaces `SearchStore`'s `.failed` state when
/// there is no cached payload at all (`TeeTimeSnapshot.isEmptyAndFailing`
/// requires `payload == nil`) — so with a cache on screen, the results list
/// (or the empty state) is what's showing, never `ViewsErrorState`, and its
/// "Try again" button is unreachable. That leaves pull-to-refresh as the only
/// gesture that could still ask for fresh data on that screen, and
/// `SearchScreen.resultsList`'s `List` never asked SwiftUI for one — confirmed
/// before this fix by `grep -rn "refreshable" ios/TeesForTheBoys`, which
/// returned no matches anywhere in the app.
///
/// `ios/project.yml` is frozen — no ViewInspector, no snapshot library — so
/// this measures the real, un-mocked view exactly the way
/// `AlertFromSearchButtonLayoutTests` does: `UIHostingController` lays out the
/// actual `SearchScreen`, and a `.refreshable` list surfaces as a real
/// `UIRefreshControl` on the underlying scroll view, so this looks for one
/// directly rather than asserting on anything mocked.
@MainActor
final class SearchScreenPullToRefreshTests: XCTestCase {

    /// Same fixture and fixed clock `SearchScreenTests` uses, so the default
    /// search already has results on screen (`resultCount == 5`) and
    /// `resultsList`, not the empty state, is what actually renders.
    private let fixedNow = ContractDate.date(from: "2026-10-03T00:00:00+10:00")!

    private func loadedStore() -> SearchStore {
        let now = fixedNow
        let store = SearchStore(preferences: InMemoryViewsStore(), fixture: "minimal", now: { now })
        store.load()
        return store
    }

    /// Depth-first search for a `UIScrollView` (a `List` is one, under the
    /// hood) carrying a non-nil `refreshControl`.
    private func findRefreshControl(in view: UIView) -> UIRefreshControl? {
        if let scrollView = view as? UIScrollView, let refresh = scrollView.refreshControl {
            return refresh
        }
        for subview in view.subviews {
            if let found = findRefreshControl(in: subview) {
                return found
            }
        }
        return nil
    }

    func testResultsListSupportsPullToRefresh() {
        let screen = SearchScreen(
            store: loadedStore(),
            ledger: BookingLedger(store: InMemoryViewsStore(), now: { self.fixedNow }),
            isSignedIn: true,
            onCreateWatch: { _ in true },
            onRequireSignIn: {},
            onRetry: {})

        let controller = UIHostingController(rootView: screen)
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 850)

        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let refreshControl = findRefreshControl(in: controller.view)
        XCTAssertNotNil(
            refreshControl,
            """
            SearchScreen's results list has no UIRefreshControl, i.e. no pull-to-refresh \
            gesture. A golfer looking at a cached list after a failed background refresh has \
            no way to ask for fresh data: the "Try again" button only appears with no cache at \
            all (ViewsErrorState / SearchStore.LoadState.failed), so pull-to-refresh is the \
            only manual retry surface this screen can offer while results are on screen.
            """)
    }
}
