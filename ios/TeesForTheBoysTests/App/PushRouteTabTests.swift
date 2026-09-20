import TeesPush
import TeesViews
import XCTest
@testable import TeesForTheBoys

/// `AppSession.tab(for:)` decides which tab a tapped push notification lands
/// on — the other half of the tap-through defect, alongside
/// `AppDelegateWiringTests`. `TeesViews` cannot know about `PushRoute` (it
/// has no `TeesPush` dependency, by design — see `ios/project.yml`'s own
/// comment on the module boundary) and `TeesPush` must not know about
/// `TeesTab`, so this mapping can only live, and only be tested, in the one
/// file that imports both.
///
/// Before this existed, nothing computed a tab for a route at all — a
/// decoded, buffered `PushRoute` sat in `AppSession.pendingRoute` with no
/// code anywhere turning it into a place on screen.
final class PushRouteTabTests: XCTestCase {

    /// One thing to look at — see `PushRoute`'s own doc comment on why a slot
    /// routes rather than a watch when there is only one match. It lives in
    /// the tee time list, so that is where the tap should land.
    @MainActor
    func testASlotRouteLandsOnSearch() {
        XCTAssertEqual(
            AppSession.tab(for: .slot(id: "the-coast:2026-09-20:0758:public-play")),
            .search)
    }

    /// Several matches — the golfer needs to see all of them, which is the
    /// account tab's alert list, not any one slot.
    @MainActor
    func testAWatchRouteLandsOnAccount() {
        XCTAssertEqual(
            AppSession.tab(for: .watch(id: "11111111-1111-1111-1111-111111111111")),
            .account)
    }
}
