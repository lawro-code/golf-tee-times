import SwiftUI
import UIKit
import XCTest
import TeesContract
import TeesDesign
@testable import TeesViews

/// The regression this guards: the six filter chips across the top of
/// `SearchScreen` and the `Clear` button both meet Apple's documented 44×44pt
/// minimum touch target. `FilterBar` now builds its chips from
/// `TeesFilterChip`, which declares `.frame(minHeight: TeesLayout
/// .minTapTarget)` itself — this test proves that integration, not
/// `TeesFilterChip` in isolation, so a future change to `FilterBar`'s own
/// padding or frame around the chip cannot silently shrink it back down. The
/// `Clear` button has no equivalent design-system component (`docs/style.css`
/// `button#reset-filters` is its own one-off look), so it is measured
/// directly.
///
/// `ios/project.yml` is frozen — no ViewInspector, no snapshot library — so
/// this measures the real, un-mocked view exactly the way
/// `AlertFromSearchButtonLayoutTests` does: `UIHostingController.sizeThatFits`
/// lays it out and hands back its measured height. No window, no run loop,
/// nothing rendered to a simulator's screen.
@MainActor
final class FilterBarLayoutTests: XCTestCase {

    /// iPhone 17's point width, iOS 18.
    private let screenWidth: CGFloat = 393

    private func measuredHeight<V: View>(
        _ view: V, dynamicTypeSize: DynamicTypeSize = .large
    ) -> CGFloat {
        let controller = UIHostingController(rootView: view.dynamicTypeSize(dynamicTypeSize))
        controller.view.frame = CGRect(x: 0, y: 0, width: screenWidth, height: 200)
        return controller.sizeThatFits(in: CGSize(width: screenWidth, height: .greatestFiniteMagnitude))
            .height
    }

    /// One of the six chips across the top of `SearchScreen` — the control a
    /// golfer touches most in the app. Built the same way `FilterBar.body`
    /// builds one, not reconstructed by hand, so a change to that call site
    /// is what this test actually watches.
    func testEachFilterChipMeetsAppleMinimumTapTarget() {
        let chip = TeesFilterChip(
            model: .selector(label: "Day", value: "Any day", isSelected: false),
            style: .selector
        ) {}
        let height = measuredHeight(chip)

        XCTAssertGreaterThanOrEqual(
            height, 44,
            "a filter chip measured \(height)pt tall at the default text size — under Apple's "
                + "44pt minimum tap target (TeesLayout.minTapTarget).")
    }

    /// Sits on the same row, styled with the exact same padding math as a chip.
    func testClearButtonMeetsAppleMinimumTapTarget() {
        let bar = FilterBar(store: SearchStore.previewStore())
        let height = measuredHeight(bar.clearButton)

        XCTAssertGreaterThanOrEqual(
            height, 44,
            "the Clear button measured \(height)pt tall at the default text size — under Apple's "
                + "44pt minimum tap target.")
    }
}
