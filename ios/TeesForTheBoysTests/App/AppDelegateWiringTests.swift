import UIKit
import XCTest
@testable import TeesForTheBoys

/// Regression coverage for the composition root itself.
///
/// Every other test target exercises one track in isolation. Nothing ever
/// exercised `TeesForTheBoysApp`'s own wiring, because nothing could —
/// `AppDelegate` and `AppSession` were both already correct on their own, and
/// the actual defect was that `TeesForTheBoysApp` never installed either of
/// them at all. Before this file's fix, `TeesForTheBoysApp` held no
/// `appDelegate` property whatsoever — this file would not even have
/// compiled against that code, which is as much a "fails against the current
/// code" as a runtime assertion is.
///
/// This constructs `TeesForTheBoysApp` directly and reads its own
/// `appDelegate` rather than asserting on `UIApplication.shared.delegate`.
/// That would be the more end-to-end check, and was the first one written
/// here — but a hosted unit test's process never completes a real
/// scene-connection launch, so `UIApplication.shared.delegate` does not
/// reliably reflect `@UIApplicationDelegateAdaptor` there even when it is
/// declared correctly (confirmed empirically: it stays false on a clean
/// build with the fix applied). That is a property of how Xcode hosts unit
/// tests for a SwiftUI-lifecycle app, not of this code, so it is not what
/// this test pins.
@MainActor
final class AppDelegateWiringTests: XCTestCase {

    /// `TeesForTheBoysApp.init()` is the same code every real launch runs
    /// before `body` is ever evaluated — constructing the value here runs it
    /// for real, with no simulator scene lifecycle required. `AppDelegate`'s
    /// `weak var session` means every one of its methods — device token,
    /// tap — silently no-ops via `session?.…` for as long as this is nil.
    func testConstructingTheAppAttachesItsSessionToItsAppDelegate() {
        let app = TeesForTheBoysApp()
        XCTAssertNotNil(
            app.appDelegate.session,
            """
            TeesForTheBoysApp.appDelegate.session is nil right after \
            construction — a tapped push notification calls \
            session?.handlePushTap(userInfo:) on nothing and is silently \
            dropped, cold, backgrounded, or foregrounded.
            """)
    }
}
