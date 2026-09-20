import TeesContract
import TeesViews
import XCTest
@testable import TeesForTheBoys

/// Regression coverage for: "Booked it" for a slot that sold out while the
/// golfer was away from the app never reaches Supabase, so the watch that led
/// them there is never cancelled.
///
/// `scraper/scrape.py` drops a sold-out slot from the payload entirely
/// (`if spots_available <= 0: continue`) rather than keeping it with
/// `spots=0`, so a slot the golfer tapped out to can simply be absent from
/// the fresh payload a relaunch fetches. `AppSession.persistBooking` used to
/// treat "not in the live payload" as a reason to skip the `bookings` insert
/// altogether — which also means the server-side `bookings_satisfy_watches`
/// trigger (`supabase/migrations/alerts_0010_watch_lifecycle.sql`) never
/// runs, so the watch that produced the alert never gets marked satisfied and
/// keeps firing forever. `AppSession.slotToPersist(for:in:)` is the decision
/// this covers directly, with no network involved: everything
/// `BookingRepository.confirmBooking` needs is either the live slot or a
/// reconstruction off the fields `ConfirmedBooking` already captured at
/// confirm time.
@MainActor
final class AppSessionBookingPersistenceTests: XCTestCase {

    private static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let parsed = f.date(from: iso) else {
            preconditionFailure("fixture date \(iso) does not parse")
        }
        return parsed
    }

    private func confirmedBooking(
        slotID: String = "the-coast:2026-09-19:0800:default",
        courseSlug: String = "the-coast",
        courseName: String = "The Coast Golf Club",
        teeDate: String = "2026-09-19",
        teeTime: String = "08:00:00",
        teeAt: String = "2026-09-19T08:00:00+10:00",
        holes: Int = 18,
        par: Int? = 70
    ) -> ConfirmedBooking {
        ConfirmedBooking(
            slotID: slotID,
            courseSlug: courseSlug,
            courseName: courseName,
            teeDate: teeDate,
            teeTime: teeTime,
            teeAt: Self.date(teeAt),
            holes: holes,
            par: par,
            confirmedAt: Self.date("2026-09-18T09:00:00+10:00"))
    }

    // MARK: - The exact repro

    /// The slot the golfer tapped out to has sold out and the next scrape
    /// dropped it, so the fresh payload `AppSession.start()` fetched on
    /// relaunch does not contain it at all. This must still produce a slot to
    /// persist — not a skipped booking.
    func testASlotDroppedFromTheFreshPayloadIsStillPersistedNotSkipped() {
        let confirmed = confirmedBooking()
        let freshPayload = ContractPayload(
            generatedAt: "2026-09-19T07:00:00+10:00",
            courses: [],
            slots: [], // the sold-out slot is gone, not present with spots=0
            courseDays: [])

        let slot = AppSession.slotToPersist(for: confirmed, in: freshPayload)

        XCTAssertEqual(slot.id, confirmed.slotID)
        XCTAssertEqual(
            slot.courseSlug, "the-coast",
            "courseSlug is what bookings_satisfy_watches matches on; it must be the real one, not empty")
        XCTAssertEqual(slot.teeDate, confirmed.teeDate)
        XCTAssertEqual(slot.teeTime, confirmed.teeTime)
        XCTAssertEqual(slot.teeAt, confirmed.teeAt)
        XCTAssertEqual(slot.holes, confirmed.holes)
    }

    /// A payload that was never fetched (or whose fetch itself failed) is the
    /// same shape of problem — nothing to look the slot up in — and must not
    /// be treated any differently.
    func testANilPayloadAlsoFallsBackRatherThanSkipping() {
        let confirmed = confirmedBooking()

        let slot = AppSession.slotToPersist(for: confirmed, in: nil)

        XCTAssertEqual(slot.id, confirmed.slotID)
        XCTAssertEqual(slot.courseSlug, confirmed.courseSlug)
    }

    // MARK: - The common case, unaffected

    /// When the slot is still in the live payload, its richer copy — current
    /// price, booking URL — is used, not a stripped-down reconstruction.
    func testASlotStillInTheLivePayloadUsesTheLiveCopyNotAReconstruction() {
        let confirmed = confirmedBooking()
        let liveSlot = Slot(
            id: confirmed.slotID,
            courseSlug: "the-coast",
            courseName: "The Coast Golf Club",
            region: "Eastern Suburbs",
            driveMinutesFromBondi: 12,
            par: 70,
            requiresRegistration: false,
            teeDate: confirmed.teeDate,
            teeTime: confirmed.teeTime,
            teeAt: confirmed.teeAt,
            spotsAvailable: 2,
            totalSpots: 4,
            holes: 18,
            priceMin: 55,
            priceMax: 55,
            priceTiers: [],
            bookingType: "Social",
            bookingURLString: "https://thecoast.miclub.com.au/guests/bookings/1")
        let payload = ContractPayload(
            generatedAt: "2026-09-19T07:00:00+10:00",
            courses: [],
            slots: [liveSlot],
            courseDays: [])

        let slot = AppSession.slotToPersist(for: confirmed, in: payload)

        XCTAssertEqual(slot.priceMin, 55, "the live, current price — not lost by preferring a reconstruction")
        XCTAssertEqual(slot.bookingURLString, "https://thecoast.miclub.com.au/guests/bookings/1")
    }
}
