import XCTest
@testable import TeesPush
import UserNotifications

/// The module surface: the things other tracks and the app target hold.
final class TeesPushSmokeTests: XCTestCase {

    /// The Stage 0 scaffold joins this into a line on screen, so the property
    /// stays. The value moves off the placeholder's `"0"` now the module does
    /// something — a smoke test that would pass against the placeholder is
    /// testing nothing.
    func testModuleLinks() {
        XCTAssertFalse(TeesPushModule.version.isEmpty)
        XCTAssertNotEqual(TeesPushModule.version, "0")
        XCTAssertEqual(TeesPushModule.version, "1.0.0")
    }

    /// A debug build is signed for the sandbox gateway; a release build is not.
    /// This gate runs in Debug, so this is the half of it that can be asserted.
    func testDebugBuildsRegisterAgainstTheSandboxGateway() {
        #if DEBUG
        XCTAssertEqual(PushEnvironment.current, .sandbox)
        #else
        XCTAssertEqual(PushEnvironment.current, .production)
        #endif
    }

    /// Mapped rather than passed through, so nothing above this module has to
    /// import `UserNotifications` to ask a yes/no question. `@unknown default`
    /// is the case that matters: a status a later iOS adds must not be read as
    /// permission we do not have.
    func testAuthorizationStatusMapping() {
        let cases: [(UNAuthorizationStatus, PushAuthorizationStatus, Bool)] = [
            (.notDetermined, .notDetermined, false),
            (.denied, .denied, false),
            (.authorized, .authorized, true),
            (.provisional, .provisional, false),
            (.ephemeral, .ephemeral, true),
        ]

        for (system, mapped, allowsAlerts) in cases {
            XCTAssertEqual(PushPermission.map(system), mapped)
            XCTAssertEqual(mapped.allowsAlerts, allowsAlerts, mapped.rawValue)
        }
        XCTAssertFalse(PushAuthorizationStatus.unknown.allowsAlerts)
    }

    /// The default sink. A token that arrives with nobody signed in has nowhere
    /// to go, and dropping it is the right outcome rather than an error.
    func testTheNoOpSinkSucceedsQuietly() async throws {
        let sink = NoOpPushTokenSink()
        try await sink.register(token: "abc", environment: .sandbox)
        try await sink.retire(token: "abc")
    }

    func testRoutesAreComparable() {
        XCTAssertEqual(PushRoute.slot(id: "a"), .slot(id: "a"))
        XCTAssertNotEqual(PushRoute.slot(id: "a"), .slot(id: "b"))
        XCTAssertNotEqual(PushRoute.slot(id: "a"), .watch(id: "a"))
    }
}
