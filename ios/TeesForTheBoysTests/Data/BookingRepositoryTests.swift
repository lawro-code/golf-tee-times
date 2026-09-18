import XCTest
@testable import TeesData
import TeesContract
import Supabase

/// "Did you book?" answered yes, and what happens when it is answered twice.
final class BookingRepositoryTests: XCTestCase {

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
    ) -> BookingRepository {
        BookingRepository(client: B4Client.make(), session: session, now: { now })
    }

    // MARK: - The wall

    func testEveryMethodThrowsNotSignedInWithoutASession() async throws {
        let repository = makeRepository(session: .signedOut)

        await assertNotSignedIn {
            _ = try await repository.confirmBooking(slot: B4Fixtures.slot(), players: 4)
        }
        await assertNotSignedIn { _ = try await repository.upcomingRounds() }
        await assertNotSignedIn { _ = try await repository.allBookings() }
        await assertNotSignedIn { _ = try await repository.cancel(bookingID: UUID()) }

        XCTAssertTrue(B4StubURLProtocol.sent.isEmpty)
    }

    // MARK: - Confirming

    /// The round has to keep rendering after the slot row is marked gone, so
    /// everything it needs is copied off the slot at confirm time rather than
    /// joined to it later.
    func testConfirmDenormalisesTheSlotOntoTheRow() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.bookingRow)

        _ = try await makeRepository().confirmBooking(slot: B4Fixtures.slot(), players: 4)

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "bookings").first)
        let body = try XCTUnwrap(sent.json)

        XCTAssertEqual(body["slot_id"] as? String, "the-coast:2026-10-03:0800:1st-tee-social")
        XCTAssertEqual(body["course_slug"] as? String, "the-coast")
        XCTAssertEqual(body["course_name"] as? String, "The Coast Golf Club")
        XCTAssertEqual(body["tee_date"] as? String, "2026-10-03")
        XCTAssertEqual(body["tee_time"] as? String, "08:00:00")
        XCTAssertEqual(body["players"] as? Int, 4)
        XCTAssertEqual(body["holes"] as? Int, 18)
        XCTAssertEqual(body["price"] as? Double, 55)
        XCTAssertEqual(
            body["booking_url"] as? String,
            "https://thecoast.miclub.com.au/guests/bookings/x")
        XCTAssertEqual(
            ContractDate.date(from: try XCTUnwrap(body["tee_at"] as? String)),
            ContractDate.date(from: "2026-10-03T08:00:00+10:00"),
            "tee_at is the instant the server resolved, copied and not recomputed")
    }

    /// `unique (user_id, slot_id)` is what stops one slot becoming two rounds.
    /// A second yes — the prompt shown again on an iPad, a double tap — is an
    /// upsert on that conflict, not an error the UI has to apologise for.
    func testConfirmingTheSameSlotTwiceUpsertsRatherThanFailing() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.bookingRow)
        let repository = makeRepository()
        let slot = B4Fixtures.slot()

        let first = try await repository.confirmBooking(slot: slot, players: 4)
        let second = try await repository.confirmBooking(slot: slot, players: 4)
        XCTAssertEqual(first.id, second.id)

        let sends = B4StubURLProtocol.sent(to: "bookings")
        XCTAssertEqual(sends.count, 2)
        for sent in sends {
            XCTAssertEqual(sent.method, "POST")
            XCTAssertEqual(
                sent.query("on_conflict"), "user_id,slot_id",
                "the conflict target is the composite key, not the id")
            XCTAssertEqual(
                sent.header("Prefer")?.contains("resolution=merge-duplicates"), true)
        }
    }

    /// Saying yes after cancelling means you have it after all, so the merge
    /// has to clear `cancelled_at` — which needs an explicit null, because a
    /// column left out of the payload is a column PostgREST does not touch.
    func testConfirmingClearsAPreviousCancellation() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.bookingRow)
        _ = try await makeRepository().confirmBooking(slot: B4Fixtures.slot(), players: nil)

        let body = try XCTUnwrap(B4StubURLProtocol.sent(to: "bookings").first?.json)
        XCTAssertTrue(body["cancelled_at"] is NSNull)
        XCTAssertTrue(body["players"] is NSNull, "no headcount is not a reason to lose the round")
        XCTAssertNil(body["confirmed_at"], "the first yes keeps its timestamp")
    }

    /// One slot in six publishes no price. The booking records that as null
    /// rather than inventing a number, exactly as the contract requires of the
    /// slot it came from.
    func testAnUnpricedSlotIsConfirmedWithANullPrice() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.bookingRow)
        _ = try await makeRepository().confirmBooking(
            slot: B4Fixtures.slot(priceMin: nil), players: 2)

        let body = try XCTUnwrap(B4StubURLProtocol.sent(to: "bookings").first?.json)
        XCTAssertTrue(body["price"] is NSNull)
    }

    /// A 9-hole booking on an 18-hole course is ordinary — 125 slots in the
    /// golden fixture — and the booking records the booking's hole count.
    func testANineHoleBookingKeepsItsOwnHoleCount() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.bookingRow)
        _ = try await makeRepository().confirmBooking(
            slot: B4Fixtures.slot(holes: 9), players: 2)

        let body = try XCTUnwrap(B4StubURLProtocol.sent(to: "bookings").first?.json)
        XCTAssertEqual(body["holes"] as? Int, 9)
    }

    /// The hole count is decoration on this screen; the round is not. A slot
    /// carrying something the table would refuse — anything but 9 or 18 — is
    /// written as "we don't know" rather than costing the golfer a booking they
    /// have already made at the club.
    func testAnOddHoleCountIsRecordedAsUnknownRatherThanLosingTheRound() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.bookingRow)

        _ = try await makeRepository().confirmBooking(
            slot: B4Fixtures.slot(holes: 12), players: 2)

        let body = try XCTUnwrap(B4StubURLProtocol.sent(to: "bookings").first?.json)
        XCTAssertTrue(body["holes"] is NSNull)
        XCTAssertEqual(
            body["slot_id"] as? String, "the-coast:2026-10-03:0800:1st-tee-social",
            "and the round is still recorded")
    }

    /// An empty booking URL is not a URL. It goes out as null rather than as an
    /// empty string that a later screen would turn into a dead button.
    func testASlotWithNoBookingURLIsStillConfirmed() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.bookingRow)

        _ = try await makeRepository().confirmBooking(
            slot: B4Fixtures.slot(bookingURL: ""), players: 2)

        let body = try XCTUnwrap(B4StubURLProtocol.sent(to: "bookings").first?.json)
        XCTAssertTrue(body["booking_url"] is NSNull)
    }

    /// The owner comes from the session. There is no parameter for it, and RLS
    /// checks it equals `auth.uid()` on the way in.
    func testTheRoundIsRecordedAgainstTheSignedInUser() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.bookingRow)

        _ = try await makeRepository().confirmBooking(slot: B4Fixtures.slot(), players: 2)

        let body = try XCTUnwrap(B4StubURLProtocol.sent(to: "bookings").first?.json)
        XCTAssertEqual(
            (body["user_id"] as? String)?.lowercased(),
            B4Fixtures.userID.uuidString.lowercased())
    }

    func testAnImpossibleHeadcountIsRefusedBeforeTheNetwork() async throws {
        do {
            _ = try await makeRepository().confirmBooking(slot: B4Fixtures.slot(), players: 5)
            XCTFail("expected invalidInput")
        } catch let error as DataError {
            guard case .invalidInput(let field, _) = error else {
                return XCTFail("expected invalidInput, got \(error)")
            }
            XCTAssertEqual(field, "players")
        }
        XCTAssertTrue(B4StubURLProtocol.sent.isEmpty)
    }

    // MARK: - Reading

    /// Filtered on `tee_at`, the instant the server resolved once, and never on
    /// a date compared in the device's zone.
    func testUpcomingRoundsAsksForFutureUncancelledRoundsInOrder() async throws {
        B4StubURLProtocol.respond(json: "[\(B4Fixtures.bookingRow)]")

        let rounds = try await makeRepository().upcomingRounds()
        XCTAssertEqual(rounds.count, 1)

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "bookings").first)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.query("user_id"), "eq.\(B4Fixtures.userID.uuidString)")
        // The SDK spells a null filter `is.NULL`; PostgREST reads it
        // case-insensitively. Asserted as sent, not as imagined.
        XCTAssertEqual(sent.query("cancelled_at"), "is.NULL")
        XCTAssertEqual(sent.query("order"), "tee_at.asc.nullslast")
        XCTAssertEqual(
            sent.query("tee_at")?.hasPrefix("gt."), true,
            "the future is a bound on the instant, not on the calendar date")
    }

    /// History is every round, cancelled ones included, newest first. The
    /// difference from upcoming rounds is the whole reason both exist.
    func testAllBookingsReadsTheWholeHistoryNewestFirst() async throws {
        B4StubURLProtocol.respond(json: "[\(B4Fixtures.bookingRow)]")

        _ = try await makeRepository().allBookings()

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "bookings").first)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.query("user_id"), "eq.\(B4Fixtures.userID.uuidString)")
        XCTAssertEqual(sent.query("order"), "tee_at.desc.nullslast")
        XCTAssertNil(
            sent.query("cancelled_at"), "a cancelled round is still part of the history")
        XCTAssertNil(sent.query("tee_at"), "and so is one that has already been played")
    }

    // MARK: - Cancelling

    /// The round trip that makes the row worth keeping: cancel writes a
    /// timestamp, and a later yes clears it on the same row rather than
    /// inserting a second one. The explicit null is the load-bearing half —
    /// a column left out of the payload is a column PostgREST does not touch,
    /// so without it the round would stay cancelled after being re-confirmed.
    func testSayingYesAfterACancellationUnCancelsTheSameRound() async throws {
        B4StubURLProtocol.respond(status: 200, json: B4Fixtures.bookingRow)
        let repository = makeRepository()
        let id = UUID(uuidString: "12121212-3434-5656-7878-909090909090")!

        _ = try await repository.cancel(bookingID: id)
        _ = try await repository.confirmBooking(slot: B4Fixtures.slot(), players: 2)

        let sends = B4StubURLProtocol.sent(to: "bookings")
        XCTAssertEqual(sends.count, 2)

        XCTAssertEqual(sends[0].method, "PATCH")
        XCTAssertNotNil(sends[0].json?["cancelled_at"] as? String)

        XCTAssertEqual(sends[1].method, "POST")
        XCTAssertEqual(sends[1].query("on_conflict"), "user_id,slot_id")
        XCTAssertTrue(
            sends[1].json?["cancelled_at"] is NSNull,
            "the second yes has to clear the cancellation, not leave it standing")
    }

    func testCancelSetsCancelledAtOnTheOwnersRow() async throws {
        B4StubURLProtocol.respond(json: B4Fixtures.bookingRow)
        let id = UUID(uuidString: "12121212-3434-5656-7878-909090909090")!

        _ = try await makeRepository().cancel(bookingID: id)

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "bookings").first)
        XCTAssertEqual(sent.method, "PATCH")
        XCTAssertEqual(sent.query("id"), "eq.\(id.uuidString)")
        XCTAssertEqual(sent.query("user_id"), "eq.\(B4Fixtures.userID.uuidString)")

        let body = try XCTUnwrap(sent.json)
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(
            ContractDate.date(from: try XCTUnwrap(body["cancelled_at"] as? String)),
            B4Fixtures.now)
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
