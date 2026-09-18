import XCTest
@testable import TeesData
import TeesContract
import Supabase

/// Watches, driven entirely through canned PostgREST bytes. No network, and
/// nothing whatsoever against a hosted Supabase project.
///
/// What these prove, one line each: the wall throws before a packet leaves, the
/// row that goes out matches the frozen schema, `user_id` comes from the
/// session and never from a caller, and `expires_at` is Sydney's midnight.
final class WatchRepositoryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        B4StubURLProtocol.respond(json: "[]")
    }

    override func tearDown() {
        B4StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeRepository(
        session: B4StubSession = .signedIn,
        now: Date = B4Fixtures.now
    ) -> WatchRepository {
        WatchRepository(client: B4Client.make(), session: session, now: { now })
    }

    // MARK: - The wall

    /// Every write and every read of user-owned data refuses before it builds a
    /// request. The wall is in front of alerts; it is emphatically not in front
    /// of search, which is tested by there being no session in sight anywhere
    /// on the browse path.
    func testEveryMethodThrowsNotSignedInWithoutASession() async throws {
        let repository = makeRepository(session: .signedOut)

        await assertNotSignedIn { _ = try await repository.create(WatchDraft()) }
        await assertNotSignedIn { _ = try await repository.list() }
        await assertNotSignedIn { _ = try await repository.update(id: UUID(), to: WatchDraft()) }
        await assertNotSignedIn { _ = try await repository.deactivate(id: UUID()) }
        await assertNotSignedIn { try await repository.delete(id: UUID()) }

        XCTAssertTrue(
            B4StubURLProtocol.sent.isEmpty,
            "signed out must cost nothing — not even a request the server would refuse")
    }

    // MARK: - Creating

    /// One call, because the UI is one button. The whole draft goes in the one
    /// insert, and what comes out has to match the frozen columns exactly.
    func testCreateSendsOneInsertMatchingTheFrozenSchema() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.watchRow)

        let watch = try await makeRepository().create(
            WatchDraft(
                label: "Saturday morning at The Coast",
                courseSlugs: ["the-coast"],
                weekdays: [7, 6],
                dateFrom: "2026-10-01",
                dateTo: "2026-10-03",
                timeFrom: "07:00",
                timeTo: "09:30",
                minPlayers: 2,
                priceMax: 60,
                maxDriveMinutes: 45))

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "watches").first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/rest/v1/watches")

        let body = try XCTUnwrap(sent.json)
        XCTAssertEqual(body["time_from"] as? String, "07:00:00")
        XCTAssertEqual(body["time_to"] as? String, "09:30:00")
        XCTAssertEqual(body["date_from"] as? String, "2026-10-01")
        XCTAssertEqual(body["date_to"] as? String, "2026-10-03")
        XCTAssertEqual(body["weekdays"] as? [Int], [6, 7])
        XCTAssertEqual(body["course_slugs"] as? [String], ["the-coast"])
        XCTAssertEqual(body["min_players"] as? Int, 2)
        XCTAssertEqual(body["active"] as? Bool, true)
        XCTAssertTrue(body["holes"] is NSNull, "nothing said about holes means either")

        XCTAssertEqual(watch.id.uuidString.lowercased(), "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    /// `user_id` is set from the session, never from a parameter — RLS checks it
    /// equals `auth.uid()`, and an API that let a caller supply it would be an
    /// API whose only defence was the database arguing back.
    func testCreateTakesUserIDFromTheSession() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.watchRow)
        try await makeRepository().create(WatchDraft())

        let body = try XCTUnwrap(B4StubURLProtocol.sent(to: "watches").first?.json)
        XCTAssertEqual(
            (body["user_id"] as? String)?.lowercased(),
            B4Fixtures.userID.uuidString.lowercased())
    }

    /// The end of `date_to` at the course. Asserted as an absolute instant so
    /// it is a claim about the moment, not about the string: midnight on 4
    /// October 2026 in Sydney is 14:00 UTC on the 3rd, because the clocks have
    /// not gone forward yet.
    func testExpiresAtIsMidnightInSydneyAndNotOnThisDevice() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.watchRow)
        try await makeRepository().create(WatchDraft(dateTo: "2026-10-03"))

        let body = try XCTUnwrap(B4StubURLProtocol.sent(to: "watches").first?.json)
        let expiresAt = try XCTUnwrap(body["expires_at"] as? String)
        XCTAssertEqual(
            ContractDate.date(from: expiresAt),
            ContractDate.date(from: "2026-10-03T14:00:00+00:00"))
    }

    /// A watch with no end date does not get an expiry invented for it.
    func testNoEndDateMeansNoExpiry() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.watchRow)
        try await makeRepository().create(WatchDraft(dateTo: nil))

        let body = try XCTUnwrap(B4StubURLProtocol.sent(to: "watches").first?.json)
        XCTAssertTrue(body["expires_at"] is NSNull)
    }

    /// A constraint violation is a message with the field named, caught here,
    /// and never a 400 from Postgres with a constraint name in it.
    func testAnImpossibleDraftNeverReachesTheNetwork() async throws {
        do {
            _ = try await makeRepository().create(
                WatchDraft(timeFrom: "11:00:00", timeTo: "09:00:00"))
            XCTFail("expected invalidInput")
        } catch let error as DataError {
            guard case .invalidInput(let field, _) = error else {
                return XCTFail("expected invalidInput, got \(error)")
            }
            XCTAssertEqual(field, "time_to")
            XCTAssertFalse(error.isRetryable)
        }
        XCTAssertTrue(B4StubURLProtocol.sent.isEmpty)
    }

    // MARK: - Listing

    func testListScopesToTheUserAndHidesRetiredWatches() async throws {
        B4StubURLProtocol.respond(json: "[\(B4Fixtures.watchRow)]")

        let watches = try await makeRepository().list()
        XCTAssertEqual(watches.count, 1)

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "watches").first)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(
            sent.query("user_id"), "eq.\(B4Fixtures.userID.uuidString)")
        XCTAssertEqual(sent.query("active"), "eq.true")
        XCTAssertEqual(sent.query("order"), "created_at.desc.nullslast")
    }

    func testListCanIncludeInactiveWatches() async throws {
        B4StubURLProtocol.respond(json: "[]")
        _ = try await makeRepository().list(includeInactive: true)

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "watches").first)
        XCTAssertNil(sent.query("active"))
    }

    // MARK: - Updating, deactivating, deleting

    func testUpdateIsAPatchScopedToTheRowAndTheOwner() async throws {
        B4StubURLProtocol.respond(json: B4Fixtures.watchRow)
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

        _ = try await makeRepository().update(id: id, to: WatchDraft(dateTo: "2026-10-04"))

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "watches").first)
        XCTAssertEqual(sent.method, "PATCH")
        XCTAssertEqual(sent.query("id"), "eq.\(id.uuidString)")
        XCTAssertEqual(sent.query("user_id"), "eq.\(B4Fixtures.userID.uuidString)")

        let body = try XCTUnwrap(sent.json)
        XCTAssertNil(body["user_id"], "a row never changes owner")
        XCTAssertEqual(
            ContractDate.date(from: try XCTUnwrap(body["expires_at"] as? String)),
            ContractDate.date(from: "2026-10-04T13:00:00+00:00"),
            "an edited end date moves the expiry, still in Sydney")
    }

    /// The seam the "did you book?" flow lands on. It writes one column: a
    /// whole-row PATCH would rewrite every filter to whatever the caller
    /// happened to be holding, which is not what "stop alerting me" means.
    ///
    /// Deciding *which* watch a booking satisfies is the matcher's job in track
    /// E. This ticket stops at the seam.
    func testDeactivateWritesOnlyTheActiveColumn() async throws {
        B4StubURLProtocol.respond(json: B4Fixtures.watchRow)
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

        _ = try await makeRepository().deactivate(id: id)

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "watches").first)
        XCTAssertEqual(sent.method, "PATCH")
        let body = try XCTUnwrap(sent.json)
        XCTAssertEqual(body["active"] as? Bool, false)
        XCTAssertEqual(body.count, 1, "one column, not a rewrite of the whole watch")
    }

    func testDeleteIsScopedToTheRowAndTheOwner() async throws {
        B4StubURLProtocol.respond(json: "[]")
        let id = UUID()

        try await makeRepository().delete(id: id)

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "watches").first)
        XCTAssertEqual(sent.method, "DELETE")
        XCTAssertEqual(sent.query("id"), "eq.\(id.uuidString)")
        XCTAssertEqual(sent.query("user_id"), "eq.\(B4Fixtures.userID.uuidString)")
    }

    /// Clearing a filter has to clear the column. A PATCH that leaves the nil
    /// out is a PATCH that quietly keeps the old price limit, and the only way
    /// left to get rid of it is to delete the alert and start again.
    func testUpdateClearsTheFiltersTheGolferRemoved() async throws {
        B4StubURLProtocol.respond(json: B4Fixtures.watchRow)
        let watch = try JSONDecoder().decode(Watch.self, from: Data(B4Fixtures.watchRow.utf8))

        var draft = WatchDraft(watch: watch)
        draft.priceMax = nil
        draft.maxDriveMinutes = nil
        draft.courseSlugs = nil
        draft.dateTo = nil
        draft.label = nil

        _ = try await makeRepository().update(id: watch.id, to: draft)

        let body = try XCTUnwrap(B4StubURLProtocol.sent(to: "watches").first?.json)
        for column in [
            "price_max", "max_drive_minutes", "course_slugs", "date_to", "label", "expires_at",
        ] {
            XCTAssertTrue(body[column] is NSNull, "\(column) has to be cleared, not left behind")
        }
        XCTAssertEqual(
            body["time_from"] as? String, "07:00:00",
            "and the filters that were kept are still there")
    }

    // MARK: - Failures

    /// RLS refusing a row is the server saying no, not the network dropping.
    /// The difference is whether the UI offers a retry button.
    func testAServerRefusalBecomesATypedServerError() async throws {
        B4StubURLProtocol.respond(
            status: 403,
            json: #"{"code":"42501","message":"new row violates row-level security policy"}"#)

        do {
            _ = try await makeRepository().create(WatchDraft())
            XCTFail("expected a server error")
        } catch let error as DataError {
            guard case .server(let status, _) = error else {
                return XCTFail("expected .server, got \(error)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertFalse(error.isRetryable)
        }
    }

    /// A dropped connection is the network's fault. It has to arrive as
    /// something retryable — not as a server refusal and not as a decoding
    /// failure, because both of those tell the UI to stop trying.
    func testADroppedConnectionIsRetryableAndNotBlamedOnTheServer() async throws {
        B4StubURLProtocol.fail(with: .notConnectedToInternet)

        do {
            _ = try await makeRepository().list()
            XCTFail("expected a failure")
        } catch let error as DataError {
            XCTAssertEqual(error, .offline)
            XCTAssertTrue(error.isRetryable)
        }
    }

    /// The other half of that: a gateway answering with an HTML error page is
    /// the server having a moment, and a 5xx is worth retrying. Left to read as
    /// a transport failure it would send the golfer to Settings to check a
    /// connection that is fine.
    func testAGatewayErrorPageIsAServerFailureAndNotTheNetwork() async throws {
        B4StubURLProtocol.respond(status: 502, json: "<html><body>Bad Gateway</body></html>")

        do {
            _ = try await makeRepository().list()
            XCTFail("expected a failure")
        } catch let error as DataError {
            guard case .server(let status, _) = error else {
                return XCTFail("expected .server, got \(error.diagnostic)")
            }
            XCTAssertEqual(status, 502)
            XCTAssertTrue(error.isRetryable, "5xx is the one server failure worth repeating")
        }
    }

    /// Bytes that do not fit the frozen schema are a bug report, not a retry —
    /// the same bytes fail the same way next time — and the report has to name
    /// the table so it says what broke.
    func testARowThatDoesNotFitTheSchemaIsADecodingFailure() async throws {
        B4StubURLProtocol.respond(json: #"[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]"#)

        do {
            _ = try await makeRepository().list()
            XCTFail("expected a failure")
        } catch let error as DataError {
            guard case .decoding(let reason) = error else {
                return XCTFail("expected .decoding, got \(error.diagnostic)")
            }
            XCTAssertTrue(reason.contains("watches"), "the report says which table: \(reason)")
            XCTAssertFalse(error.isRetryable)
        }
    }

    /// nil expiry means open-ended, not already over. Reading it the other way
    /// would retire every alert without an end date the moment it was saved —
    /// and an alert with no end date is the ordinary one.
    func testAWatchWithNoEndDateNeverExpires() throws {
        let row = B4Fixtures.watchRow.replacingOccurrences(
            of: "\"expires_at\": \"2026-10-03T14:00:00+00:00\"", with: "\"expires_at\": null")
        let watch = try JSONDecoder().decode(Watch.self, from: Data(row.utf8))

        XCTAssertNil(watch.expiresAt)
        XCTAssertFalse(
            makeRepository(now: ContractDate.date(from: "2030-01-01T00:00:00+11:00")!)
                .hasExpired(watch))
    }

    func testExpiredWatchesAreRecognisedAgainstTheInjectedClock() throws {
        let watch = try JSONDecoder().decode(Watch.self, from: Data(B4Fixtures.watchRow.utf8))
        // The fixture expires at 2026-10-03T14:00Z.
        XCTAssertFalse(
            makeRepository(now: ContractDate.date(from: "2026-10-03T13:59:00+00:00")!)
                .hasExpired(watch))
        XCTAssertTrue(
            makeRepository(now: ContractDate.date(from: "2026-10-03T14:00:01+00:00")!)
                .hasExpired(watch))
    }

    // MARK: - Helper

    private func assertNotSignedIn(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected DataError.notSignedIn", file: file, line: line)
        } catch let error as DataError {
            XCTAssertEqual(error, .notSignedIn, file: file, line: line)
        } catch {
            XCTFail("expected DataError.notSignedIn, got \(error)", file: file, line: line)
        }
    }
}
