import XCTest
import TeesPush
@testable import TeesForTheBoys

/// Regression coverage for: signing out never told `PushRegistrar` to give
/// back this device's token.
///
/// Two mates sharing one iPhone is a first-class scenario per
/// `PushTokenRepository`'s own doc comment — golfer A signs out, golfer B
/// signs in, and without this fix A's push token was still live in
/// `push_tokens`, so A kept getting B's alerts on A's phone. `clearUserData()`
/// is the one place both sign-out paths (`observeAuth`'s `.signedOut` case,
/// and `AccountScreen`'s sign-out button via `onSignedOut`) already funnel
/// through, which is why the fix and this test sit there rather than in
/// `signOut()` itself.
@MainActor
final class AppSessionPushRetireOnSignOutTests: XCTestCase {

    /// Stands in for `UIApplication` — nothing here calls `register()`, so it
    /// has nothing to record.
    private final class StubApplication: RemoteNotificationRegistering {
        func registerForRemoteNotifications() {}
    }

    private let sampleToken = Data([0x01, 0x02, 0x03, 0x04])

    func testClearUserDataRetiresACurrentlyRegisteredPushToken() async {
        let sink = RecordingPushTokenSink()
        let registrar = PushRegistrar(application: StubApplication(), sink: sink)
        _ = await registrar.handleRegistration(deviceToken: sampleToken)

        let session = AppSession()
        session.pushRegistrar = registrar

        session.clearUserData()

        // `retire()` is fired from a `Task` inside `clearUserData()` (it is
        // `async`, `clearUserData()` is not) — give it a tick to run before
        // asserting, same as every other fire-and-forget call in this file.
        try? await Task.sleep(nanoseconds: 50_000_000)

        let retired = await sink.retired
        XCTAssertEqual(
            retired, [PushRegistrar.hexString(from: sampleToken)],
            """
            signing out must hand this device's push token back, or the previous \
            golfer keeps receiving alerts meant for whoever signs in next
            """)
    }

    func testClearUserDataIsSafeWithNoRegistrarOrNoCurrentToken() async {
        let session = AppSession()
        session.clearUserData()

        session.pushRegistrar = PushRegistrar(application: StubApplication(), sink: NoOpPushTokenSink())
        session.clearUserData()

        try? await Task.sleep(nanoseconds: 50_000_000)
        // Nothing to assert beyond "did not crash" — nil registrar and a
        // registrar with no `currentToken` are both ordinary, not errors.
    }
}
