import SwiftUI
import UIKit
import XCTest
import TeesContract
@testable import TeesViews

/// The regression this guards: `SearchScreen` pins `AlertFromSearchButton`
/// (`.inline`) to the results screen's bottom safe area
/// (`SearchScreen.swift`'s `inlineAlertBar`, via `.safeAreaInset(edge: .bottom)`).
/// Its label had no line limit or height cap, so at the largest system text
/// size (AX5) a real watch sentence wrapped to three or four lines and the bar
/// swelled to roughly a third of a 6.1" screen — leaving the results `List`
/// too little room to show even one full tee-time row above it. The first
/// row's own text then rendered straight under the bar's opaque background,
/// cut off mid-word with no on-screen cue that scrolling would reveal the
/// rest.
///
/// `ios/project.yml` is frozen — no ViewInspector, no snapshot library — so
/// this measures the real, un-mocked view exactly the way SwiftUI itself
/// does: `UIHostingController.sizeThatFits(in:)` lays it out and hands back
/// its measured height. No window, no run loop, nothing rendered to a
/// simulator's screen — and nothing about `AlertFromSearchButton` is faked.
@MainActor
final class AlertFromSearchButtonLayoutTests: XCTestCase {

    /// The exact repro's own search: default, unfiltered — `SearchFilters
    /// .standard` — whose sentence is `WatchDraftTests
    /// .testAStandardFilterSetStillMakesAWholeSentence`'s own pinned string,
    /// "Alert me when any tee time opens". Deliberately the *shortest*
    /// sentence the button ever shows: if even this one overflows the cap
    /// this test enforces, a longer, filtered search only makes the bar
    /// taller still.
    private func standardDraft() -> WatchDraft {
        WatchDraft(filters: .standard, courses: [], today: "2026-09-16")
    }

    /// iPhone 17's point width, iOS 18 — the same class of device the defect
    /// was reproduced on.
    private let screenWidth: CGFloat = 393

    /// Renders exactly what `SearchScreen.inlineAlertBar` renders — the same
    /// view, wrapped in the same gutter and vertical padding it adds there —
    /// at the given Dynamic Type size, and measures its real height.
    private func measuredHeight(dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let bar = AlertFromSearchButton(
            draft: standardDraft(),
            prominence: .inline,
            isSignedIn: true,
            onCreate: { _ in true },
            onRequireSignIn: {})
            .padding(.horizontal, SearchStyle.gutter)
            .padding(.vertical, SearchStyle.chipSpacing)
            .dynamicTypeSize(dynamicTypeSize)

        let controller = UIHostingController(rootView: bar)
        controller.view.frame = CGRect(x: 0, y: 0, width: screenWidth, height: 2000)
        return controller.sizeThatFits(in: CGSize(width: screenWidth, height: .greatestFiniteMagnitude)).height
    }

    /// A 6.1" iPhone's point height (iPhone 17 included). The bug report's own
    /// description of the defect: the pinned bar swelled to "roughly a third"
    /// of this at AX5. A pinned, secondary utility bar taking a fifth of the
    /// screen is still generous room for it — comfortably under half of what
    /// the pre-fix defect actually produced — while leaving the rest to the
    /// screen's actual content, `SearchScreen.resultsList`.
    private let screenHeight: CGFloat = 852
    private let maxBarFraction: CGFloat = 0.20

    /// The bug itself: at AX5, even the shortest sentence the button ever
    /// shows — the default, unfiltered search's "Alert me when any tee time
    /// opens" — must not swell the pinned bar into dominating the screen the
    /// way the pre-fix defect did. That swelling is exactly what starves
    /// `SearchScreen.resultsList` of room for a single row above it.
    func testInlineBarDoesNotDominateTheScreenAtMaximumAccessibilitySize() {
        let height = measuredHeight(dynamicTypeSize: .accessibility5)
        let ceiling = screenHeight * maxBarFraction

        XCTAssertLessThanOrEqual(
            height, ceiling,
            "the inline alert bar measured \(height)pt tall at AX5 — more than "
                + "\(Int(maxBarFraction * 100))% of a 6.1\" screen (\(ceiling)pt). "
                + "That is what leaves SearchScreen.resultsList no room for a "
                + "single tee-time row above it.")
    }

    /// The cap must not visibly change ordinary reading: the same sentence
    /// already renders as a single compact row there today, and the fix must
    /// not touch that.
    func testInlineBarIsUnaffectedAtTheDefaultTextSize() {
        let height = measuredHeight(dynamicTypeSize: .large) // .large is the system default.
        XCTAssertLessThanOrEqual(
            height, 100,
            "the inline bar grew past a single compact row at the default text size: \(height)pt")
    }
}
