import Supabase
import XCTest
@testable import TeesData

/// Auth against a stubbed `URLSession`. Nothing here touches the network or a
/// hosted Supabase project: every request is answered by `B1StubURLProtocol`,
/// and the session is held in memory rather than the keychain.
final class AuthServiceTests: XCTestCase {

    private let userID = UUID(uuidString: "6F9B1E4C-1D2A-4B3C-9E8F-0A1B2C3D4E5F")!

    override func setUp() {
        super.setUp()
        B1StubURLProtocol.reset()
    }

    override func tearDown() {
        B1StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Browsing works signed out

    func testASignedOutServiceHasNoUserAndRequireUserIDIsTheWall() {
        let harness = B1AuthHarness()
        XCTAssertNil(harness.service.currentUserID)
        XCTAssertEqual(harness.service.state, .signedOut)
        XCTAssertThrowsError(try harness.service.requireUserID()) { error in
            XCTAssertEqual(error as? DataError, .notSignedIn)
        }
        XCTAssertTrue(
            B1StubURLProtocol.requestedPaths.isEmpty,
            "asking who is signed in must not hit the network")
    }

    // MARK: - Validation, before any round trip

    func testAMalformedEmailIsCaughtBeforeARequestGoesOut() async {
        let harness = B1AuthHarness()
        for address in ["", "   ", "will", "will@example", "will @example.com", "@example.com", "will@.com"] {
            do {
                try await harness.service.signIn(email: address, password: "longenough")
                XCTFail("\(address) should not have been accepted")
            } catch {
                guard case .invalidInput(let field, _)? = error as? DataError else {
                    return XCTFail("expected .invalidInput for \(address), got \(error)")
                }
                XCTAssertEqual(field, "email")
            }
        }
        XCTAssertTrue(
            B1StubURLProtocol.requestedPaths.isEmpty,
            "a typo must not cost a round trip: \(B1StubURLProtocol.requestedPaths)")
    }

    func testAShortPasswordIsCaughtBeforeARequestGoesOut() async {
        let harness = B1AuthHarness()
        do {
            try await harness.service.signUp(email: "will@example.com", password: "short")
            XCTFail("a short password should not have been accepted")
        } catch {
            guard case .invalidInput(let field, let reason)? = error as? DataError else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertEqual(field, "password")
            XCTAssertTrue(reason.contains("\(AuthService.minimumPasswordLength)"), reason)
        }
        XCTAssertTrue(B1StubURLProtocol.requestedPaths.isEmpty)
    }

    func testAValidationFailureIsNotDressedUpAsAServerError() async {
        let harness = B1AuthHarness()
        do {
            try await harness.service.signIn(email: "nope", password: "longenough")
            XCTFail("that should have thrown")
        } catch {
            if case .server = error as? DataError {
                XCTFail("a local validation failure must not claim the server refused it")
            }
            XCTAssertFalse((error as? DataError)?.isRetryable ?? true)
        }
    }

    // MARK: - Signing in

    func testSignInStoresTheSessionAndReportsTheUser() async throws {
        let harness = B1AuthHarness()
        B1StubURLProtocol.handler = { [userID] request in
            guard request.url?.path.hasSuffix("/token") == true else {
                return .json(status: 404, object: ["msg": "unexpected \(request.url?.path ?? "")"])
            }
            return .json(status: 200, object: B1Fixtures.session(userID: userID))
        }

        try await harness.service.signIn(email: "Will@Example.com ", password: "longenough")

        XCTAssertEqual(harness.service.currentUserID, userID)
        XCTAssertEqual(try harness.service.requireUserID(), userID)
        XCTAssertEqual(harness.service.state, .signedIn(userID: userID, email: "will@example.com"))
        XCTAssertEqual(
            harness.storage.storedKeys, [SupabaseClientProvider.sessionStorageKey],
            "the session has to be persisted under our own key, not a derived one")
    }

    func testTheAddressSentToTheServerIsTheTidiedOne() async throws {
        // The stub answers with a fixed email whatever it is asked, so asserting
        // on the state after a sign-in proves nothing about what went out. This
        // reads the request body. Supabase matches the address as sent, so a
        // stray capital or a keyboard's trailing space signs nobody in.
        let harness = B1AuthHarness()
        let captured = B1CapturedBodies()
        B1StubURLProtocol.handler = { [userID] request in
            captured.record(request.b1Body)
            return .json(status: 200, object: B1Fixtures.session(userID: userID))
        }

        try await harness.service.signIn(email: "  Will@Example.COM ", password: "longenough")

        let body = try XCTUnwrap(captured.all.first, "nothing was sent")
        let sent = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any],
            "the body was not JSON")
        XCTAssertEqual(sent["email"] as? String, "will@example.com")
    }

    func testSignUpAsksForAnAccountRatherThanSigningSomebodyIn() async throws {
        let harness = B1AuthHarness()
        B1StubURLProtocol.handler = { [userID] _ in
            .json(status: 200, object: B1Fixtures.session(userID: userID))
        }

        try await harness.service.signUp(email: "will@example.com", password: "longenough")

        XCTAssertEqual(
            B1StubURLProtocol.requestedPaths.first?.hasSuffix("/signup"), true,
            "sign-up went to \(B1StubURLProtocol.requestedPaths)")
    }

    func testWrongCredentialsBecomeAServerFailureThatIsNotWorthRetrying() async {
        let harness = B1AuthHarness()
        B1StubURLProtocol.handler = { _ in
            .json(
                status: 400,
                object: ["error": "invalid_grant", "error_description": "Invalid login credentials"])
        }

        do {
            try await harness.service.signIn(email: "will@example.com", password: "longenough")
            XCTFail("that should have thrown")
        } catch {
            guard case .server(let status, _)? = error as? DataError else {
                return XCTFail("expected .server, got \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertFalse((error as? DataError)?.isRetryable ?? true)
            XCTAssertNil(harness.service.currentUserID)
        }
    }

    func testNoNetworkBecomesOfflineAndIsWorthRetrying() async {
        let harness = B1AuthHarness()
        B1StubURLProtocol.handler = { _ in .failure(URLError(.notConnectedToInternet)) }

        do {
            try await harness.service.signIn(email: "will@example.com", password: "longenough")
            XCTFail("that should have thrown")
        } catch {
            XCTAssertEqual(error as? DataError, .offline)
            XCTAssertTrue((error as? DataError)?.isRetryable ?? false)
        }
    }

    // MARK: - Signing out

    func testSignOutClearsTheStoredSession() async throws {
        let harness = try await B1AuthHarness.signedIn(userID: userID)
        XCTAssertFalse(harness.storage.storedKeys.isEmpty)

        B1StubURLProtocol.handler = { _ in .json(status: 204, object: [:]) }
        try await harness.service.signOut()

        XCTAssertTrue(
            harness.storage.storedKeys.isEmpty,
            "signed out has to mean nothing is left on the device")
        XCTAssertNil(harness.service.currentUserID)
        XCTAssertEqual(harness.service.state, .signedOut)
    }

    func testSignOutStillClearsTheDeviceWhenTheServerIsUnreachable() async throws {
        let harness = try await B1AuthHarness.signedIn(userID: userID)

        B1StubURLProtocol.handler = { _ in .failure(URLError(.networkConnectionLost)) }
        try await harness.service.signOut()

        XCTAssertTrue(harness.storage.storedKeys.isEmpty)
        XCTAssertNil(harness.service.currentUserID)
    }

    func testSignOutSurvivesAServerHavingAMoment() async throws {
        // A 500 on logout is worth retrying, but not worth refusing to sign
        // someone out over: the session is gone from this device either way.
        let harness = try await B1AuthHarness.signedIn(userID: userID)

        B1StubURLProtocol.handler = { _ in .json(status: 500, object: ["msg": "boom"]) }
        try await harness.service.signOut()

        XCTAssertNil(harness.service.currentUserID)
        XCTAssertTrue(harness.storage.storedKeys.isEmpty)
    }

    func testARefusedSignOutReachesTheCallerAndStillClearsTheDevice() async throws {
        let harness = try await B1AuthHarness.signedIn(userID: userID)

        B1StubURLProtocol.handler = { _ in .json(status: 422, object: ["msg": "no"]) }
        do {
            try await harness.service.signOut()
            XCTFail("a refusal the server will repeat has to reach the caller")
        } catch {
            XCTAssertEqual(error as? DataError, .server(status: 422, message: "no"))
        }

        XCTAssertTrue(
            harness.storage.storedKeys.isEmpty,
            "the device has to be cleared before the failure is thrown, not after")
        XCTAssertNil(harness.service.currentUserID)
    }

    func testSignOutClearsAHalfWrittenSessionTheSDKCannotSee() async throws {
        // The SDK only clears storage when it can decode a session to clear. A
        // truncated or corrupt entry survives that, and "signed out" then means
        // a stale blob is still on the device.
        let harness = B1AuthHarness()
        try harness.storage.store(
            key: SupabaseClientProvider.sessionStorageKey, value: Data("half a session".utf8))
        XCTAssertNil(harness.service.currentUserID, "that blob is not a session")

        try await harness.service.signOut()

        XCTAssertTrue(
            harness.storage.storedKeys.isEmpty,
            "signed out has to mean nothing is left on the device")
        XCTAssertTrue(
            B1StubURLProtocol.requestedPaths.isEmpty,
            "there was no session to revoke, so there was nothing to ask the server")
    }

    // MARK: - Restoring at launch

    func testRestoreWithNothingStoredIsSignedOutNotAnError() async throws {
        let harness = B1AuthHarness()
        let restored = try await harness.service.restoreSession()
        XCTAssertFalse(restored)
        XCTAssertTrue(
            B1StubURLProtocol.requestedPaths.isEmpty,
            "with nothing stored there is nothing to ask the server about")
    }

    func testRestoreKeepsAValidSession() async throws {
        let harness = try await B1AuthHarness.signedIn(userID: userID)
        let restored = try await harness.service.restoreSession()
        XCTAssertTrue(restored)
        XCTAssertEqual(harness.service.currentUserID, userID)
    }

    func testBeingOfflineAtLaunchDoesNotSignAnyoneOut() async throws {
        // The stored session has expired, so the SDK tries to refresh it and
        // cannot. Signing the person out here would be the wrong answer: the
        // session is still theirs and the SDK will refresh it later.
        let harness = try await B1AuthHarness.signedIn(userID: userID, expired: true)

        B1StubURLProtocol.handler = { _ in .failure(URLError(.notConnectedToInternet)) }
        let restored = try await harness.service.restoreSession()

        XCTAssertTrue(restored)
        XCTAssertEqual(harness.service.currentUserID, userID)
        XCTAssertFalse(harness.storage.storedKeys.isEmpty)
    }

    func testARejectedRefreshTokenClearsTheSession() async throws {
        let harness = try await B1AuthHarness.signedIn(userID: userID, expired: true)

        B1StubURLProtocol.handler = { _ in
            .json(status: 401, object: ["msg": "Invalid Refresh Token", "code": 401])
        }
        let restored = try await harness.service.restoreSession()

        XCTAssertFalse(restored, "a revoked session is not a session")
        XCTAssertTrue(harness.storage.storedKeys.isEmpty)
    }

    func testAServerHavingAMomentAtLaunchDoesNotSignAnyoneOut() async throws {
        // Offline is not the only failure worth keeping a session through: a
        // 5xx on the refresh is the server's problem, not evidence that this
        // person's session was revoked.
        let harness = try await B1AuthHarness.signedIn(userID: userID, expired: true)

        B1StubURLProtocol.handler = { _ in .json(status: 500, object: ["msg": "boom"]) }
        let restored = try await harness.service.restoreSession()

        XCTAssertTrue(restored, "a 500 on the refresh is not a sign-out")
        XCTAssertFalse(harness.storage.storedKeys.isEmpty)
    }

    // MARK: - State changes

    func testStateChangesEmitsTheCurrentStateWithoutBeingAsked() async throws {
        let harness = B1AuthHarness()
        let first = await b1FirstState(from: harness.service.stateChanges)
        XCTAssertEqual(first, .signedOut)
    }

    func testStateChangesReportsASignIn() async throws {
        let harness = B1AuthHarness()
        B1StubURLProtocol.handler = { [userID] _ in
            .json(status: 200, object: B1Fixtures.session(userID: userID))
        }

        let stream = harness.service.stateChanges
        let states = Task { await b1Collect(from: stream, until: { $0 != .signedOut }) }
        // Give the stream its initial event before changing anything under it.
        try await Task.sleep(for: .milliseconds(100))
        try await harness.service.signIn(email: "will@example.com", password: "longenough")

        let seen = await states.value
        XCTAssertEqual(
            seen.last, .signedIn(userID: userID, email: "will@example.com"),
            "a sign-in has to reach whoever is watching the stream")
    }

    func testAStoredSessionIsAnnouncedBeforeTheNetworkIsAskedAboutIt() async throws {
        // Launched in a car park with no signal. The stored session has expired,
        // so the SDK will try to refresh it — but whoever is watching the stream
        // must hear "signed in" straight away rather than "signed out" until the
        // network gives up. That is what emitLocalSessionAsInitialSession buys.
        let harness = try await B1AuthHarness.signedIn(userID: userID, expired: true)
        B1StubURLProtocol.handler = { _ in .failure(URLError(.notConnectedToInternet)) }

        let first = await b1FirstState(from: harness.service.stateChanges)

        XCTAssertEqual(first, .signedIn(userID: userID, email: "will@example.com"))
    }

    // MARK: - Awaiting a stream without hanging a failing test forever

    private func b1FirstState(
        from stream: AsyncStream<AuthState>, timeout: Duration = .seconds(5)
    ) async -> AuthState? {
        await withTaskGroup(of: AuthState?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func b1Collect(
        from stream: AsyncStream<AuthState>,
        until isFinal: @escaping @Sendable (AuthState) -> Bool,
        timeout: Duration = .seconds(5)
    ) async -> [AuthState] {
        await withTaskGroup(of: [AuthState].self) { group in
            group.addTask {
                var seen: [AuthState] = []
                for await state in stream {
                    seen.append(state)
                    if isFinal(state) { break }
                }
                return seen
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Harness

/// An `AuthService` wired to a client that can only talk to `B1StubURLProtocol`,
/// with its session held in memory.
struct B1AuthHarness {
    let storage: InMemorySessionStorage
    let client: SupabaseClient
    let service: AuthService

    init() {
        let storage = InMemorySessionStorage()
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [B1StubURLProtocol.self]
            return configuration
        }())
        let client = SupabaseClientProvider.client(
            configuration: SupabaseConfiguration(
                url: URL(string: "https://b1stub.supabase.co")!,
                anonKey: "b1-test-anon-key"),
            session: session,
            storage: storage)

        self.storage = storage
        self.client = client
        self.service = AuthService(client: client, storage: storage)
    }

    /// A harness that has already signed somebody in, with the stub reset
    /// afterwards so the next expectation starts from nothing.
    static func signedIn(userID: UUID, expired: Bool = false) async throws -> B1AuthHarness {
        let harness = B1AuthHarness()
        B1StubURLProtocol.handler = { _ in
            .json(status: 200, object: B1Fixtures.session(userID: userID, expired: expired))
        }
        try await harness.service.signIn(email: "will@example.com", password: "longenough")
        B1StubURLProtocol.reset()
        return harness
    }
}

// MARK: - Reading what was actually sent

/// A `Sendable` place for the stub handler — which runs on whichever thread the
/// session is loading on — to hand a request body back to the test.
private final class B1CapturedBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []

    func record(_ body: Data) { lock.withLock { stored.append(body) } }
    var all: [Data] { lock.withLock { stored } }
}

extension URLRequest {
    /// The body, whichever way `URLSession` chose to hand it over.
    ///
    /// By the time a request reaches a `URLProtocol`, `httpBody` has usually
    /// been turned into `httpBodyStream` and reads as nil — which is how a test
    /// ends up quietly asserting on an empty body.
    fileprivate var b1Body: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var body = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            guard read > 0 else { break }
            body.append(buffer, count: read)
        }
        return body
    }
}

// MARK: - Fixtures

enum B1Fixtures {
    /// The shape `/auth/v1/token` returns. Deliberately hand-written rather than
    /// encoded from `Session`, so a change in the SDK's own coding shows up as a
    /// failing test rather than a matching pair of mistakes.
    static func session(userID: UUID, expired: Bool = false) -> [String: Any] {
        let expiresAt = Date().addingTimeInterval(expired ? -3600 : 3600).timeIntervalSince1970
        return [
            "access_token": "b1.stub.access.token",
            "token_type": "bearer",
            "expires_in": 3600,
            "expires_at": Int(expiresAt),
            "refresh_token": "b1-stub-refresh-token",
            "user": [
                "id": userID.uuidString,
                "aud": "authenticated",
                "role": "authenticated",
                "email": "will@example.com",
                "app_metadata": ["provider": "email"],
                "user_metadata": [:],
                "created_at": "2026-09-01T00:00:00Z",
                "updated_at": "2026-09-01T00:00:00Z",
            ],
        ]
    }
}

// MARK: - The stub

/// Answers every request made through the injected `URLSession`. No test in
/// this bundle reaches a network.
final class B1StubURLProtocol: URLProtocol {
    struct Answer: Sendable {
        var status: Int
        var body: Data
        var error: URLError?

        static func json(status: Int, object: [String: Any]) -> Answer {
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return Answer(status: status, body: body, error: nil)
        }

        static func failure(_ error: URLError) -> Answer {
            Answer(status: 0, body: Data(), error: error)
        }
    }

    private static let state = B1StubState()

    static var handler: (@Sendable (URLRequest) -> Answer)? {
        get { state.handler }
        set { state.handler = newValue }
    }

    /// Every path asked for since the last reset. What proves a local validation
    /// failure never left the device.
    static var requestedPaths: [String] { state.paths }

    static func reset() { state.reset() }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        B1StubURLProtocol.state.record(request.url?.path ?? "")

        let answer =
            B1StubURLProtocol.handler?(request)
            ?? .json(status: 500, object: ["msg": "no stub handler was set"])

        if let error = answer.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The stub's mutable state, behind a lock: URLProtocol instances are created
/// on whichever thread the session is loading on.
private final class B1StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandler: (@Sendable (URLRequest) -> B1StubURLProtocol.Answer)?
    private var storedPaths: [String] = []

    var handler: (@Sendable (URLRequest) -> B1StubURLProtocol.Answer)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    var paths: [String] { lock.withLock { storedPaths } }

    func record(_ path: String) {
        lock.withLock { storedPaths.append(path) }
    }

    func reset() {
        lock.withLock {
            storedHandler = nil
            storedPaths = []
        }
    }
}
