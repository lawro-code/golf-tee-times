import Supabase
import XCTest
@testable import TeesContract
@testable import TeesData

/// The track's shared vocabulary: the error type every file throws, the log
/// where a dropped row states its reason, and the three seams the other three
/// tickets implement.
///
/// Every helper type in this bundle is prefixed `B1` — all four B tickets
/// compile into one `TeesDataTests` bundle and two doubles with the same name
/// will not link.
final class TeesDataSmokeTests: XCTestCase {

    // MARK: - Module

    func testModuleVersionMovedOffTheStage0Stub() {
        XCTAssertFalse(TeesDataModule.version.isEmpty)
        XCTAssertNotEqual(TeesDataModule.version, "0", "Stage 0 left this at \"0\"")
    }

    // MARK: - What is worth retrying

    func testRetryableFailuresAreTheNetworksFault() {
        XCTAssertTrue(DataError.offline.isRetryable)
        XCTAssertTrue(DataError.transport("connection reset").isRetryable)
        XCTAssertTrue(DataError.server(status: 500, message: nil).isRetryable)
        XCTAssertTrue(DataError.server(status: 503, message: "upstream").isRetryable)
    }

    func testNonRetryableFailuresWouldFailIdenticallyNextTime() {
        XCTAssertFalse(DataError.server(status: 400, message: nil).isRetryable)
        XCTAssertFalse(DataError.server(status: 401, message: nil).isRetryable)
        XCTAssertFalse(DataError.server(status: 404, message: nil).isRetryable)
        XCTAssertFalse(DataError.notSignedIn.isRetryable)
        XCTAssertFalse(DataError.decoding(reason: "missing key 'id'").isRetryable)
        XCTAssertFalse(DataError.notConfigured("no url").isRetryable)
        XCTAssertFalse(DataError.cacheUnavailable("disk full").isRetryable)
        XCTAssertFalse(DataError.invalidInput(field: "email", reason: "nope").isRetryable)
        XCTAssertFalse(
            DataError.contractVersionMismatch(expected: "1.0.0", found: "2.0.0").isRetryable)
    }

    // MARK: - What a screen is allowed to show

    func testEveryCaseHasSomethingAUserCouldRead() {
        let all: [DataError] = [
            .notConfigured("TEES_SUPABASE_URL missing"),
            .notSignedIn,
            .offline,
            .transport("URLError.-1005"),
            .server(status: 500, message: nil),
            .decoding(reason: "expected Int at slots.3.holes"),
            .cacheUnavailable("keychain retrieve failed (OSStatus -34018)"),
            .contractVersionMismatch(expected: "1.0.0", found: "0.9.0"),
            .invalidInput(field: "email", reason: "That does not look like an email address."),
        ]
        for error in all {
            XCTAssertFalse(error.description.isEmpty, "\(error.diagnostic) has no message")
            XCTAssertFalse(
                error.description.contains("OSStatus"),
                "a user-facing message must not carry an OSStatus: \(error.description)")
            XCTAssertFalse(
                error.description.contains("URLError"),
                "a user-facing message must not carry a URLError code: \(error.description)")
            XCTAssertFalse(error.diagnostic.isEmpty)
        }
    }

    func testAServerMessageIsPreferredOverTheGenericOne() {
        XCTAssertEqual(
            DataError.server(status: 400, message: "Invalid login credentials").description,
            "Invalid login credentials")
    }

    // MARK: - The one door in

    func testLostOrAbsentNetworkIsOffline() {
        XCTAssertEqual(DataError.from(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(DataError.from(URLError(.networkConnectionLost)), .offline)
        XCTAssertEqual(DataError.from(URLError(.timedOut)), .offline)
    }

    func testOtherURLErrorsAreTransportAndKeepTheirCode() {
        let mapped = DataError.from(URLError(.cannotFindHost))
        guard case .transport(let detail) = mapped else {
            return XCTFail("expected .transport, got \(mapped.diagnostic)")
        }
        XCTAssertTrue(detail.contains("\(URLError.cannotFindHost.rawValue)"), detail)
    }

    func testADecodingFailureKeepsTheKeyPath() throws {
        struct B1Row: Decodable { let holes: Int }
        let json = Data(#"{"holes": "eighteen"}"#.utf8)
        do {
            _ = try JSONDecoder().decode(B1Row.self, from: json)
            XCTFail("that should not have decoded")
        } catch {
            let mapped = DataError.from(error)
            guard case .decoding(let reason) = mapped else {
                return XCTFail("expected .decoding, got \(mapped.diagnostic)")
            }
            XCTAssertTrue(reason.contains("holes"), "the key path is the useful half: \(reason)")
            XCTAssertFalse(reason.contains("\n"), "one line, not a dozen: \(reason)")
        }
    }

    func testAGatewayFailureIsTheServersFaultNotTheSignals() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://stub.supabase.co/rest/v1/open_slots")!,
                statusCode: 502, httpVersion: "HTTP/1.1", headerFields: nil))
        let mapped = DataError.from(
            HTTPError(data: Data("<html><body>502 Bad Gateway</body></html>".utf8), response: response))

        XCTAssertEqual(mapped, .server(status: 502, message: nil))
        XCTAssertTrue(mapped.isRetryable, "a 502 is worth retrying")
        XCTAssertFalse(
            mapped.description.contains("<"),
            "an HTML error page is not a message for a golfer: \(mapped.description)")
    }

    func testAShortServerMessageIsKept() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://stub.supabase.co/rest/v1/open_slots")!,
                statusCode: 429, httpVersion: "HTTP/1.1", headerFields: nil))
        let mapped = DataError.from(
            HTTPError(data: Data("Too many requests".utf8), response: response))

        XCTAssertEqual(mapped, .server(status: 429, message: "Too many requests"))
        XCTAssertFalse(mapped.isRetryable)
    }

    func testAContractVersionMismatchSurvivesTheMapping() {
        let mapped = DataError.from(
            ContractLoader.Failure.versionMismatch(expected: "1.0.0", found: "0.9.0"))
        XCTAssertEqual(mapped, .contractVersionMismatch(expected: "1.0.0", found: "0.9.0"))
        XCTAssertFalse(mapped.isRetryable)
    }

    func testMappingADataErrorReturnsItUnchanged() {
        let original = DataError.server(status: 418, message: "teapot")
        XCTAssertEqual(DataError.from(original), original)
    }

    func testAnUnrecognisedErrorIsTransportRatherThanLeakingNSError() {
        struct B1MysteryFailure: Error {}
        let mapped = DataError.from(B1MysteryFailure())
        guard case .transport = mapped else {
            return XCTFail("expected .transport, got \(mapped.diagnostic)")
        }
    }

    // MARK: - The door in, on the paths that decide what the app does next

    func testAMissingSessionReadsAsNotSignedInRatherThanAServerRefusal() {
        // `restoreSession()` branches on exactly this equality: it is what tells
        // a revoked session (clear it, show signed out) apart from a server
        // having a moment (keep it). Mapping this to `.server` would sign people
        // out of a working app.
        XCTAssertEqual(DataError.from(AuthError.sessionMissing), .notSignedIn)
        XCTAssertFalse(DataError.from(AuthError.sessionMissing).isRetryable)
    }

    func testAWeakPasswordIsTheFieldsProblemNotAServerError() {
        let mapped = DataError.from(
            AuthError.weakPassword(message: "Password is too short.", reasons: ["length"]))
        guard case .invalidInput(let field, let reason) = mapped else {
            return XCTFail("expected .invalidInput, got \(mapped.diagnostic)")
        }
        XCTAssertEqual(field, "password", "the field is what gets the red ring")
        XCTAssertEqual(reason, "Password is too short.", "the server's own wording survives")
        XCTAssertFalse(mapped.isRetryable, "the same password is weak next time too")
    }

    func testAnRLSRefusalIsNotWorthRetrying() {
        // 42501 is Postgres saying the row-level security policy said no. Asking
        // again gets the same answer, so it must not read as retryable.
        let mapped = DataError.from(
            PostgrestError(
                code: "42501", message: "new row violates row-level security policy"))
        guard case .server(let status, _) = mapped else {
            return XCTFail("expected .server, got \(mapped.diagnostic)")
        }
        XCTAssertEqual(status, 403)
        XCTAssertFalse(mapped.isRetryable)
    }

    func testPostgresRunningOutOfRoomIsWorthRetrying() {
        // 53300 is "too many connections" — the pooler under load, not a bug in
        // the request. A watch save that hits this should back off and retry,
        // not tell a golfer their alert was refused.
        let mapped = DataError.from(
            PostgrestError(code: "53300", message: "too many connections"))
        XCTAssertEqual(mapped, .server(status: 503, message: "too many connections"))
        XCTAssertTrue(mapped.isRetryable)
    }

    func testNoRowWhereExactlyOneWasExpectedIsA404() {
        let mapped = DataError.from(
            PostgrestError(
                code: "PGRST116", message: "JSON object requested, multiple (or no) rows returned"))
        guard case .server(let status, _) = mapped else {
            return XCTFail("expected .server, got \(mapped.diagnostic)")
        }
        XCTAssertEqual(status, 404, "a missing row is not a malformed request")
        XCTAssertFalse(mapped.isRetryable)
    }

    func testAnUnclassifiedPostgrestFailureIsNotRetried() {
        let mapped = DataError.from(
            PostgrestError(code: "23505", message: "duplicate key value violates unique constraint"))
        XCTAssertEqual(mapped, .server(status: 400, message: "duplicate key value violates unique constraint"))
        XCTAssertFalse(mapped.isRetryable, "the same insert will collide the same way")
    }

    func testAServerBodyTooLongToBeASentenceIsDropped() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://stub.supabase.co/rest/v1/open_slots")!,
                statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil))
        let wall = String(repeating: "a stack trace ", count: 40)
        let mapped = DataError.from(HTTPError(data: Data(wall.utf8), response: response))

        XCTAssertEqual(mapped, .server(status: 400, message: nil))
        XCTAssertFalse(
            mapped.description.contains("a stack trace"),
            "a wall of text is not a message for a golfer: \(mapped.description)")
    }

    func testACancelledRequestIsNotDressedUpAsSomethingWentWrong() {
        // Scrolling away cancels the in-flight fetch. It must not surface as a
        // failure the user has to read.
        XCTAssertEqual(DataError.from(CancellationError()), .transport("cancelled"))
    }

    func testAMissingFixtureIsACacheFailureAndBadBytesAreADecodingFailure() {
        let missing = DataError.from(ContractLoader.Failure.fixtureMissing("golden.json"))
        guard case .cacheUnavailable(let why) = missing else {
            return XCTFail("expected .cacheUnavailable, got \(missing.diagnostic)")
        }
        XCTAssertTrue(why.contains("golden.json"), why)

        let bad = DataError.from(ContractLoader.Failure.undecodable("payload is not JSON"))
        guard case .decoding(let reason) = bad else {
            return XCTFail("expected .decoding, got \(bad.diagnostic)")
        }
        XCTAssertTrue(reason.contains("not JSON"), reason)
        XCTAssertFalse(bad.isRetryable, "the same bytes fail the same way")
    }

    func testAMissingKeyNamesTheKeyInOneLine() {
        struct B1SlotRow: Decodable { let holes: Int }
        do {
            _ = try JSONDecoder().decode(B1SlotRow.self, from: Data("{}".utf8))
            XCTFail("that should not have decoded")
        } catch {
            let mapped = DataError.from(error)
            guard case .decoding(let reason) = mapped else {
                return XCTFail("expected .decoding, got \(mapped.diagnostic)")
            }
            XCTAssertTrue(reason.contains("holes"), "which key is the useful half: \(reason)")
            XCTAssertFalse(reason.contains("\n"), "one line, not a dozen: \(reason)")
            XCTAssertFalse(
                reason.contains("CodingKeys("),
                "that is Swift's own dump of the error, not a line for a log: \(reason)")
            XCTAssertLessThan(reason.count, 120, "a log line, not a paragraph: \(reason)")
        }
    }

    func testANullWhereAValueWasRequiredNamesTheKeyInOneLine() {
        struct B1SlotRow: Decodable { let holes: Int }
        do {
            _ = try JSONDecoder().decode(B1SlotRow.self, from: Data(#"{"holes": null}"#.utf8))
            XCTFail("that should not have decoded")
        } catch {
            let mapped = DataError.from(error)
            guard case .decoding(let reason) = mapped else {
                return XCTFail("expected .decoding, got \(mapped.diagnostic)")
            }
            XCTAssertTrue(reason.contains("holes"), reason)
            XCTAssertFalse(reason.contains("\n"), "one line, not a dozen: \(reason)")
            XCTAssertFalse(
                reason.contains("CodingKeys("),
                "that is Swift's own dump of the error, not a line for a log: \(reason)")
            XCTAssertLessThan(reason.count, 120, "a log line, not a paragraph: \(reason)")
        }
    }

    // MARK: - What SwiftUI's own alert will show

    func testAnAlertBoundToTheErrorShowsTheSentenceAndNotTheEnumsName() {
        // SwiftUI's `.alert(isPresented:error:)` and every `Text(error.
        // localizedDescription)` read `localizedDescription`, which without
        // `LocalizedError` is "The operation couldn't be completed.
        // (TeesData.DataError error 2.)".
        let all: [DataError] = [
            .notConfigured("TEES_SUPABASE_URL missing"),
            .notSignedIn,
            .offline,
            .transport("URLError.-1005"),
            .server(status: 500, message: nil),
            .server(status: 400, message: "Invalid login credentials"),
            .decoding(reason: "expected Int at slots.3.holes"),
            .cacheUnavailable("keychain retrieve failed (OSStatus -34018)"),
            .contractVersionMismatch(expected: "1.0.0", found: "0.9.0"),
            .invalidInput(field: "email", reason: "That does not look like an email address."),
        ]
        for error in all {
            let shown = (error as Error).localizedDescription
            XCTAssertEqual(shown, error.description, "\(error.diagnostic) reaches a screen as \(shown)")
            XCTAssertFalse(
                shown.contains("couldn't be completed"),
                "\(error.diagnostic) is showing Foundation's fallback: \(shown)")
            XCTAssertFalse(shown.contains("TeesData"), shown)
        }
    }

    // MARK: - Logging

    func testDroppedRowsAreLoggedRatherThanCrashing() {
        let issues = [
            DecodingIssue(collection: "slots", index: 3, reason: "missing key 'tee_at'"),
            DecodingIssue(collection: "courses", index: 0, reason: "expected Int"),
        ]
        DataLog.dropped(issues)
        DataLog.dropped(collection: "course_days", index: 11, reason: "null where Bool required")
        DataLog.failed("fetch", .offline, in: .remote)
        XCTAssertEqual(DataLog.subsystem, "code.lawro.TeesForTheBoys")
        XCTAssertEqual(
            DataLog.Category.allCases.map(\.rawValue),
            ["auth", "remote", "cache", "userdata"],
            "a Console filter relies on these four category names")
        for category in DataLog.Category.allCases {
            DataLog.logger(for: category).debug("smoke")
        }
    }

    // MARK: - Seams

    func testCachedPayloadCarriesWhenWeHeardIt() {
        let fetchedAt = Date(timeIntervalSince1970: 1_789_000_000)
        let cached = CachedPayload(payload: B1PayloadFactory.empty(), fetchedAt: fetchedAt)
        XCTAssertEqual(cached.fetchedAt, fetchedAt)
        XCTAssertEqual(cached.payload.contractVersion, Contract.version)
        XCTAssertTrue(cached.payload.slots.isEmpty)
    }

    func testTheSeamsAreImplementableWithoutSupabase() async throws {
        let remote: any SlotsFetching = B1StubSlotsFetcher()
        let payload = try await remote.fetchPayload()
        XCTAssertEqual(payload.contractVersion, Contract.version)

        let cache: any PayloadCaching = B1StubCache()
        XCTAssertNil(try cache.load())
        try cache.save(payload, fetchedAt: Date())
        XCTAssertNotNil(try cache.load())
        try cache.clear()
        XCTAssertNil(try cache.load())
    }

    func testRequireUserIDIsTheWallAndCurrentUserIDIsNot() throws {
        let signedOut: any SessionProviding = B1StubSession(userID: nil)
        XCTAssertNil(signedOut.currentUserID, "browsing signed out is ordinary, not an error")
        XCTAssertThrowsError(try signedOut.requireUserID()) { error in
            XCTAssertEqual(error as? DataError, .notSignedIn)
        }

        let id = UUID()
        let signedIn: any SessionProviding = B1StubSession(userID: id)
        XCTAssertEqual(try signedIn.requireUserID(), id)
    }
}

// MARK: - Doubles

enum B1PayloadFactory {
    static func empty() -> ContractPayload {
        ContractPayload(
            generatedAt: "2026-09-17T18:29:07+10:00",
            courses: [],
            slots: [],
            courseDays: [])
    }
}

struct B1StubSlotsFetcher: SlotsFetching {
    var payload: ContractPayload = B1PayloadFactory.empty()
    func fetchPayload() async throws -> ContractPayload { payload }
}

final class B1StubCache: PayloadCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CachedPayload?

    func load() throws -> CachedPayload? { lock.withLock { stored } }

    func save(_ payload: ContractPayload, fetchedAt: Date) throws {
        lock.withLock { stored = CachedPayload(payload: payload, fetchedAt: fetchedAt) }
    }

    func clear() throws { lock.withLock { stored = nil } }
}

struct B1StubSession: SessionProviding {
    let userID: UUID?
    var currentUserID: UUID? { userID }
    func requireUserID() throws -> UUID {
        guard let userID else { throw DataError.notSignedIn }
        return userID
    }
}
