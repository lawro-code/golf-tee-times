import SwiftUI
import UIKit
import XCTest
import TeesContract
@testable import TeesViews

/// The regression this guards: `OnboardingFlow.body` pins `skipButton` over
/// the content via `.overlay(alignment: .topTrailing)` (`OnboardingFlow
/// .swift`), while `whatWeWatch`'s `ScrollView` reserves no top clearance for
/// it at all. At the default text size the title
/// ("Tees watches for cancellations") is short enough to clear the corner;
/// from `.accessibility3` up it wraps wide enough, close enough to the top,
/// to run under the pinned button — exactly the reported overlap.
///
/// `ios/project.yml` is frozen — no ViewInspector, no snapshot library — so
/// this measures the real, un-mocked view exactly the way
/// `SearchScreenPullToRefreshTests` does: a `UIHostingController` hosted in a
/// real `UIWindow`, walking the actual `UIScrollView` a plain SwiftUI
/// `ScrollView` renders to on iOS (`whatWeWatch` is the only `ScrollView` on
/// screen at the flow's default, first step).
///
/// The fix reserves space for the pinned button with `.safeAreaInset(edge:
/// .top)` — the same mechanism `SearchScreen` already uses in this codebase
/// to pin `AlertFromSearchButton` and `topChrome` over its own list — which
/// surfaces as the `ScrollView`'s underlying `UIScrollView.adjustedContent
/// Inset.top`. This asserts that inset is tall enough to actually clear a
/// Skip button rendered at the same text size, not merely present.
@MainActor
final class OnboardingFlowLayoutTests: XCTestCase {

    /// iPhone 17's point width, iOS 18 — the same class of device the defect
    /// was reproduced on.
    private let screenWidth: CGFloat = 393
    private let screenHeight: CGFloat = 852

    /// Depth-first search for the first `UIScrollView` — `whatWeWatch`'s
    /// `ScrollView`, under the hood, the same trick `SearchScreenPull
    /// ToRefreshTests.findRefreshControl` uses for `List`.
    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    /// Hosts the real, un-mocked `OnboardingFlow` at its default first step
    /// and hands back the `UIScrollView` `whatWeWatch` renders to, laid out
    /// at the given Dynamic Type size.
    private func hostedScrollView(dynamicTypeSize: DynamicTypeSize) -> UIScrollView? {
        let flow = OnboardingFlow(
            store: InMemoryViewsStore(),
            requester: StubNotificationPermission(answer: false)
        ) { _ in }
            .dynamicTypeSize(dynamicTypeSize)

        let controller = UIHostingController(rootView: flow)
        controller.view.frame = CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight)

        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        return findScrollView(in: controller.view)
    }

    /// The Skip button's own real height at the same text size, measured
    /// stand-alone from exactly `OnboardingFlow.skipButton`'s own styling —
    /// `OnboardingCopy.skipTitle`, `.font(.subheadline)`, `.padding(16)` — the
    /// amount of top clearance the content actually needs to fully clear it.
    private func skipButtonHeight(dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let button = Button(OnboardingCopy.skipTitle) {}
            .font(.subheadline)
            .padding(16)
            .dynamicTypeSize(dynamicTypeSize)

        let controller = UIHostingController(rootView: button)
        controller.view.frame = CGRect(x: 0, y: 0, width: screenWidth, height: 300)
        return controller.sizeThatFits(in: CGSize(width: screenWidth, height: .greatestFiniteMagnitude)).height
    }

    /// The bug itself, plus a same-mechanism check at the default size so the
    /// fix cannot merely happen to work at the two accessibility sizes named
    /// in the report while leaving the default size unreserved.
    func testTheTitleClearsThePinnedSkipButtonAtEveryTextSize() {
        for size: DynamicTypeSize in [.large, .accessibility3, .accessibility5] {
            guard let scrollView = hostedScrollView(dynamicTypeSize: size) else {
                XCTFail("whatWeWatch's ScrollView was not found in OnboardingFlow's hosted hierarchy at \(size)")
                continue
            }
            let neededClearance = skipButtonHeight(dynamicTypeSize: size)
            let reserved = scrollView.adjustedContentInset.top

            XCTAssertGreaterThanOrEqual(
                reserved, neededClearance - 2,
                """
                at \(size) the Skip button measures \(neededClearance)pt tall but whatWeWatch's \
                ScrollView only reserves \(reserved)pt of top clearance for it — the title \
                starts rendering underneath the pinned Skip button, exactly the reported overlap.
                """)
        }
    }
}
