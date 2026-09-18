import XCTest
@testable import TeesPush

/// Registering for APNs on a machine that will never issue a token.
///
/// This gate runs on a simulator, which is exactly the environment where
/// `registerForRemoteNotifications()` never calls back. Every one of these
/// tests drives the registrar through the stub instead, and the failure paths
/// matter more than the happy one: an app that traps when APNs says no is an
/// app that cannot be run in the simulator at all.
@MainActor
final class PushRegistrarTests: XCTestCase {

    /// Stands in for `UIApplication`. The real one is satisfied by a two-line
    /// extension and has nothing worth asserting on.
    @MainActor
    private final class StubApplication: RemoteNotificationRegistering {
        private(set) var registerCallCount = 0
        func registerForRemoteNotifications() { registerCallCount += 1 }
    }

    private let sampleToken = Data([
        0x00, 0x0f, 0xb4, 0xff, 0x10, 0x20, 0x30, 0x40,
        0x50, 0x60, 0x70, 0x80, 0x90, 0xa0, 0xb0, 0xc0,
        0xd0, 0xe0, 0xf0, 0x01, 0x02, 0x03, 0x04, 0x05,
        0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d,
    ])

    // MARK: - Data to hex

    /// `%02x`, not `%x`. A leading zero byte dropped here produces a token the
    /// gateway rejects silently: no push, no error, no clue.
    func testHexConversion() {
        let cases: [(name: String, bytes: [UInt8], expected: String)] = [
            ("a leading zero byte", [0x00, 0x0f, 0xb4, 0xff], "000fb4ff"),
            ("every byte a zero", [0x00, 0x00, 0x00], "000000"),
            ("the top of the range", [0xff, 0xfe], "fffe"),
            ("lowercase, never upper", [0xab, 0xcd, 0xef], "abcdef"),
            ("nothing at all", [], ""),
        ]

        for test in cases {
            XCTAssertEqual(
                PushRegistrar.hexString(from: Data(test.bytes)), test.expected, test.name)
        }
    }

    func testAThirtyTwoByteTokenIsSixtyFourCharacters() {
        XCTAssertEqual(sampleToken.count, 32)
        XCTAssertEqual(PushRegistrar.hexString(from: sampleToken).count, 64)
        XCTAssertTrue(PushRegistrar.hexString(from: sampleToken).hasPrefix("000fb4ff"))
    }

    // MARK: - Asking

    func testRegisterAsksTheApplicationOnce() {
        let application = StubApplication()
        let registrar = PushRegistrar(application: application, sink: NoOpPushTokenSink())

        registrar.register()

        XCTAssertEqual(application.registerCallCount, 1)
        XCTAssertNil(registrar.lastOutcome)
    }

    // MARK: - The token reaching the sink

    func testTheSinkIsHandedTheHexTokenAndTheEnvironment() async {
        for environment in PushEnvironment.allCases {
            let sink = RecordingPushTokenSink()
            let registrar = PushRegistrar(
                application: StubApplication(), sink: sink, environment: environment)

            let outcome = await registrar.handleRegistration(deviceToken: sampleToken)

            let registrations = await sink.registrations
            XCTAssertEqual(registrations.count, 1, "\(environment.rawValue)")
            XCTAssertEqual(
                registrations.first,
                PushTokenRegistration(
                    token: PushRegistrar.hexString(from: sampleToken),
                    environment: environment),
                "\(environment.rawValue)")
            XCTAssertEqual(outcome, .registered(environment: environment))
            XCTAssertEqual(registrar.lastOutcome, .registered(environment: environment))
        }
    }

    /// The environment strings are written straight into
    /// `push_tokens.environment`, whose check constraint allows these two and
    /// nothing else.
    func testEnvironmentRawValuesMatchTheDatabaseConstraint() {
        XCTAssertEqual(PushEnvironment.sandbox.rawValue, "sandbox")
        XCTAssertEqual(PushEnvironment.production.rawValue, "production")
        XCTAssertEqual(PushEnvironment.allCases.count, 2)
    }

    // MARK: - The failure paths, which are the point

    /// The simulator's own case. iOS refuses, and the sink must never hear
    /// about it — a registration that did not happen must not write a row.
    func testAFailureToRegisterCallsNoSinkAndDoesNotTrap() async {
        let sink = RecordingPushTokenSink()
        let registrar = PushRegistrar(application: StubApplication(), sink: sink)

        registrar.didFailToRegister(
            NSError(domain: "NSCocoaErrorDomain", code: 3010, userInfo: nil))

        let registrations = await sink.registrations
        XCTAssertTrue(registrations.isEmpty)
        XCTAssertNil(registrar.currentToken)
        guard let outcome = registrar.lastOutcome, case .systemRefused = outcome else {
            return XCTFail("a refusal should be recorded as one")
        }
    }

    /// Nobody signed in yet, or the phone is offline. The token is kept so a
    /// later launch can try again with the same one.
    func testASinkThatThrowsIsRecordedAndTheTokenIsKept() async {
        let sink = RecordingPushTokenSink(failure: .refused)
        let registrar = PushRegistrar(application: StubApplication(), sink: sink)

        let outcome = await registrar.handleRegistration(deviceToken: sampleToken)

        let registrations = await sink.registrations
        XCTAssertTrue(registrations.isEmpty)
        XCTAssertEqual(registrar.currentToken, PushRegistrar.hexString(from: sampleToken))
        guard case .notStored = outcome else {
            return XCTFail("a sink failure should be recorded, not swallowed")
        }
    }

    func testAnEmptyDeviceTokenNeverReachesTheSink() async {
        let sink = RecordingPushTokenSink()
        let registrar = PushRegistrar(application: StubApplication(), sink: sink)

        let outcome = await registrar.handleRegistration(deviceToken: Data())

        let registrations = await sink.registrations
        XCTAssertTrue(registrations.isEmpty)
        guard case .systemRefused = outcome else {
            return XCTFail("an empty token is a refusal, not a registration")
        }
        // Not kept, so a later sign-out cannot hand the sink an empty string.
        XCTAssertNil(registrar.currentToken)
        let retirement = await registrar.retire()
        let retired = await sink.retired
        XCTAssertNil(retirement)
        XCTAssertTrue(retired.isEmpty)
    }

    // MARK: - Handing it back

    func testRetireHandsTheTokenBackAndForgetsIt() async {
        let sink = RecordingPushTokenSink()
        let registrar = PushRegistrar(application: StubApplication(), sink: sink)
        await registrar.handleRegistration(deviceToken: sampleToken)

        let outcome = await registrar.retire()

        let retired = await sink.retired
        XCTAssertEqual(retired, [PushRegistrar.hexString(from: sampleToken)])
        XCTAssertNil(registrar.currentToken)
        XCTAssertEqual(outcome, .retired)
    }

    func testRetiringWithoutATokenDoesNothing() async {
        let sink = RecordingPushTokenSink()
        let registrar = PushRegistrar(application: StubApplication(), sink: sink)

        let outcome = await registrar.retire()

        let retired = await sink.retired
        XCTAssertNil(outcome)
        XCTAssertTrue(retired.isEmpty)
    }

    // MARK: - The app delegate's own entry points
    //
    // Every test above drives `handleRegistration`, which is the awaited twin.
    // `didRegister` is what `UIApplicationDelegate` actually calls, it is
    // synchronous, and it is the only path that runs in the shipped app.

    /// The delegate method cannot await, so the registrar starts the hand-off
    /// itself. A `didRegister` that forgot to would leave every test above
    /// passing and no device token in the database.
    func testTheSynchronousDelegateCallbackStillReachesTheSink() async {
        let sink = RecordingPushTokenSink()
        let registrar = PushRegistrar(
            application: StubApplication(), sink: sink, environment: .production)

        // Exactly what the app delegate does: no await, no return value.
        registrar.didRegister(deviceToken: sampleToken)

        let registrations = await waitForRegistrations(sink, count: 1)
        XCTAssertEqual(
            registrations,
            [PushTokenRegistration(
                token: PushRegistrar.hexString(from: sampleToken),
                environment: .production)])
        XCTAssertEqual(registrar.currentToken, PushRegistrar.hexString(from: sampleToken))
        XCTAssertEqual(registrar.lastOutcome, .registered(environment: .production))
    }

    // MARK: - Handing it back when the phone is offline

    /// Sign-out with no signal. The retire fails, and the token has to survive
    /// it — a registrar that forgets the token here can never retire it, and
    /// the row in `push_tokens` keeps this device on the alert list forever.
    func testARetireThatFailsKeepsTheTokenForTheNextAttempt() async {
        let sink = FlakyRetireSink(refusals: 1)
        let registrar = PushRegistrar(application: StubApplication(), sink: sink)
        await registrar.handleRegistration(deviceToken: sampleToken)
        let hex = PushRegistrar.hexString(from: sampleToken)

        let firstAttempt = await registrar.retire()

        guard let firstAttempt, case .notStored = firstAttempt else {
            return XCTFail("a failed retire should be recorded, not swallowed")
        }
        XCTAssertEqual(registrar.currentToken, hex, "dropped here, it can never be retired")
        var retired = await sink.retired
        XCTAssertTrue(retired.isEmpty)

        // The next launch tries again with the same token.
        let secondAttempt = await registrar.retire()

        retired = await sink.retired
        XCTAssertEqual(secondAttempt, .retired)
        XCTAssertEqual(retired, [hex])
        XCTAssertNil(registrar.currentToken)
    }

    // MARK: - A second token

    /// APNs re-issues a token after a restore or a reinstall. The sink is told
    /// about the new one, and `retire()` must hand back the new one — retiring
    /// a token this device no longer has leaves the live one in the table.
    func testAReissuedTokenIsTheOneRetireHandsBack() async {
        let sink = RecordingPushTokenSink()
        let registrar = PushRegistrar(application: StubApplication(), sink: sink)
        let reissued = Data((0..<32).map { UInt8(0x20 + $0) })

        await registrar.handleRegistration(deviceToken: sampleToken)
        await registrar.handleRegistration(deviceToken: reissued)
        await registrar.retire()

        let registrations = await sink.registrations
        let retired = await sink.retired
        XCTAssertEqual(
            registrations.map(\.token),
            [PushRegistrar.hexString(from: sampleToken),
             PushRegistrar.hexString(from: reissued)])
        XCTAssertEqual(retired, [PushRegistrar.hexString(from: reissued)])
        XCTAssertNil(registrar.currentToken)
    }

    /// The fixed defect, in the order that hid it: a good token first, then an
    /// empty one. If the empty token is written down before it is rejected,
    /// the sink is later handed an empty string at sign-out and the real
    /// token is never retired.
    func testAnEmptyTokenArrivingAfterAGoodOneDoesNotReplaceIt() async {
        let sink = RecordingPushTokenSink()
        let registrar = PushRegistrar(application: StubApplication(), sink: sink)
        await registrar.handleRegistration(deviceToken: sampleToken)
        let hex = PushRegistrar.hexString(from: sampleToken)

        let outcome = await registrar.handleRegistration(deviceToken: Data())

        guard case .systemRefused = outcome else {
            return XCTFail("an empty token is a refusal, not a registration")
        }
        XCTAssertEqual(registrar.currentToken, hex)

        await registrar.retire()

        let retired = await sink.retired
        XCTAssertEqual(retired, [hex], "an empty string must never reach the sink")
    }

    /// Nobody has signed in, so the registrar was built with its default sink.
    /// The token has nowhere to go and that is a success, not an error to
    /// surface — a default that threw would record `.notStored` here.
    func testARegistrarBuiltWithoutASinkStillSucceeds() async {
        let registrar = PushRegistrar(application: StubApplication())

        let outcome = await registrar.handleRegistration(deviceToken: sampleToken)

        XCTAssertEqual(outcome, .registered(environment: .current))
        XCTAssertEqual(registrar.currentToken, PushRegistrar.hexString(from: sampleToken))
    }

    // MARK: -

    /// `didRegister` hands off in a task it does not await, so this polls
    /// rather than assuming one hop is enough. Gives up rather than hanging
    /// the gate.
    private func waitForRegistrations(
        _ sink: RecordingPushTokenSink, count: Int, timeout: TimeInterval = 2
    ) async -> [PushTokenRegistration] {
        let deadline = Date().addingTimeInterval(timeout)
        var registrations = await sink.registrations
        while registrations.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
            registrations = await sink.registrations
        }
        return registrations
    }
}

/// Fails the first `retire` calls, then succeeds. The ordinary case: the
/// phone is offline at sign-out and the app tries again later.
private actor FlakyRetireSink: PushTokenSink {
    enum Failure: Error { case offline }

    private(set) var retired: [String] = []
    private var refusalsLeft: Int

    init(refusals: Int) { self.refusalsLeft = refusals }

    func register(token: String, environment: PushEnvironment) async throws {}

    func retire(token: String) async throws {
        if refusalsLeft > 0 {
            refusalsLeft -= 1
            throw Failure.offline
        }
        retired.append(token)
    }
}
