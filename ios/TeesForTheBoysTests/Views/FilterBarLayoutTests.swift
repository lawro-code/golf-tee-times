import SwiftUI
import UIKit
import XCTest
import TeesContract
@testable import TeesViews

/// The regression this guards: the six filter chips (`FilterChip`,
/// `FilterBar.swift`) and the `Clear` button both padded a
/// `.searchChipText()` label (`.subheadline.weight(.medium)`) with
/// `SearchStyle.chipPadding` (14) horizontal and `chipPadding * 0.6` (8.4)
/// vertical, with no `.frame(minHeight:)` anywhere on either control. At the
/// default (Large) Dynamic Type size that renders a tappable height of
/// roughly 20 + 2×8.4 = 36.8pt — about 7pt (16%) short of Apple's documented
/// 44×44pt minimum touch target, and of `TeesLayout.minTapTarget`, the exact
/// standard this codebase already enforces on the visually near-identical
/// `TeesFilterChip` (`.frame(minHeight: TeesLayout.minTapTarget)`) and on
/// `AlertFromSearchButton`'s own buttons.
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
    /// golfer touches most in the app.
    func testEachFilterChipMeetsAppleMinimumTapTarget() {
        let chip = FilterChip(title: "Day", isSelected: false, spokenValue: "Any day", name: "Day") {}
        let height = measuredHeight(chip)

        XCTAssertGreaterThanOrEqual(
            height, 44,
            "a filter chip measured \(height)pt tall at the default text size — under Apple's "
                + "44pt minimum tap target (TeesLayout.minTapTarget), the standard this codebase "
                + "already enforces on TeesFilterChip.")
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
