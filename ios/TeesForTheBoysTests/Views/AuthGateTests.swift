import SwiftUI
import XCTest
@testable import TeesViews

/// The wall: where it stands, and what it says.
@MainActor
final class AuthGateTests: XCTestCase {

    // MARK: - Where it stands

    func testSignedInContentIsShownUnwrapped() {
        XCTAssertEqual(AuthGatePresentation(isSignedIn: true), .content)
    }

    func testSignedOutSeesTheWall() {
        XCTAssertEqual(AuthGatePresentation(isSignedIn: false), .wall)
    }

    /// Both states build. The gate is generic over its content, and a signed-in
    /// gate that failed to compose its content would take the alerts screen
    /// with it.
    func testTheGateBuildsInBothStates() {
        for signedIn in [true, false] {
            _ = AuthGate(isSignedIn: signedIn, actions: StubAuthActions()) {
                Text("Your alerts")
            }
        }
    }

    // MARK: - What it says

    /// The wall exists because somebody tried to set an alert, so it explains
    /// itself in those terms. "Sign in to continue" would be true of any app and
    /// useful in none.
    func testTheExplanationSaysWhyAnAccountIsNeeded() {
        let explanation = AuthGatePresentation.explanation
        XCTAssertTrue(explanation.lowercased().contains("alert"))
        XCTAssertTrue(explanation.lowercased().contains("account"))
        XCTAssertTrue(explanation.hasSuffix("."))
        XCTAssertFalse(explanation.isEmpty)
    }

    func testTheCallToActionSaysWhatItLeadsTo() {
        XCTAssertEqual(AuthGatePresentation.callToAction, "Sign in to set alerts")
    }

    /// Browsing never passes through the gate, so the wall never talks about
    /// searching or seeing tee times — if this copy starts making promises about
    /// browsing, the wall has been put somewhere it does not belong.
    func testTheWallNeverClaimsBrowsingNeedsAnAccount() {
        let copy = (AuthGatePresentation.explanation + " " + AuthGatePresentation.callToAction)
            .lowercased()
        for browsing in ["search", "browse", "see tee times", "view tee times"] {
            XCTAssertFalse(copy.contains(browsing), "The wall must not gate \(browsing)")
        }
    }

    // MARK: - The seam

    /// The gate signs somebody in through the same seam as everything else, so
    /// Stage 2 wires one adapter rather than three.
    func testTheGateUsesTheSameAuthSeamAsTheScreens() async throws {
        let stub = StubAuthActions()
        let model = AuthFormViewModel(mode: .signIn, actions: stub)
        model.email = "will@example.com"
        model.password = "eightchars"

        await model.submit()

        XCTAssertEqual(stub.calls.map(\.kind), [.signIn])
    }
}
