import Foundation
import Supabase
import TeesContract

/// "Did you book?" answered yes, and the upcoming rounds that follow from it.
///
/// ## Why the row copies the slot instead of pointing at it
///
/// The moment a golfer books an 8am at The Coast, the club stops listing it and
/// the next scrape marks that slot gone. `bookings.slot_id` is
/// `on delete set null` for the same reason. So course name, tee time, price
/// and booking URL are **denormalised at confirm time**: an upcoming round has
/// to keep rendering after the row it came from has moved on, and a round that
/// says "unknown course, unknown time" a week before you play it is worse than
/// not having asked.
///
/// ## Confirming twice is not an error
///
/// `unique (user_id, slot_id)` is what stops one slot becoming two rounds. A
/// second yes — the prompt shown again on another device, a tap that landed
/// twice — is an upsert on that conflict, not a 409 the UI has to apologise
/// for. It also clears `cancelled_at`, because saying yes after saying you
/// cancelled means you have it after all.
///
/// ## What this file deliberately does not do
///
/// It does not work out which watch a booking satisfies. That rule is
/// server-side and belongs to the matcher in track E; the seam for it is
/// ``WatchRepository/deactivate(id:)``, and Stage 2 wires the two together.
public struct BookingRepository: Sendable {

    public static let table = "bookings"

    private let client: SupabaseClient
    private let session: any SessionProviding
    private let now: @Sendable () -> Date

    public init(client: SupabaseClient, session: any SessionProviding) {
        self.init(client: client, session: session, now: { Date() })
    }

    /// Test seam: an injected clock makes "upcoming" a boundary that can be
    /// asserted rather than waited for.
    init(
        client: SupabaseClient,
        session: any SessionProviding,
        now: @escaping @Sendable () -> Date
    ) {
        self.client = client
        self.session = session
        self.now = now
    }

    // MARK: - Confirming

    /// Record that the golfer booked this slot.
    ///
    /// - Parameters:
    ///   - slot: the slot they tapped through to. Everything the round needs to
    ///     render later is copied off it here.
    ///   - players: how many of them are going, 1–4, or nil if they did not say.
    ///     The column is nullable and "I booked it" is worth keeping even
    ///     without a headcount.
    /// - Throws: ``DataError/notSignedIn`` before any request when signed out;
    ///   ``DataError/invalidInput(field:reason:)`` for a headcount the table
    ///   would refuse.
    @discardableResult
    public func confirmBooking(slot: Slot, players: Int?) async throws -> Booking {
        let userID = try session.requireUserID()

        if let players, !(1...4).contains(players) {
            throw DataError.invalidInput(
                field: "players", reason: "A group is between 1 and 4 players.")
        }
        // The column allows null, so an unexpected hole count is written as
        // "we don't know" rather than refusing a booking the golfer has
        // already made. Refusing here would lose the round over a field that
        // is decoration on this screen.
        let holes = (slot.holes == 9 || slot.holes == 18) ? slot.holes : nil

        let row = BookingWriteRow(
            userID: userID,
            slotID: slot.id,
            courseSlug: slot.courseSlug,
            courseName: slot.courseName,
            teeAt: slot.teeAt,
            teeDate: slot.teeDate,
            teeTime: slot.teeTime,
            players: players,
            holes: holes,
            // The lowest published fee, and nil for the roughly one slot in six
            // that publishes none. Null here is ordinary data, not a gap to
            // fill in with a guess.
            price: slot.priceMin,
            bookingURL: slot.bookingURLString.isEmpty ? nil : slot.bookingURLString)

        let data = try await UserDataRequest.data {
            try client.from(Self.table)
                .upsert(row, onConflict: "user_id,slot_id", returning: .representation)
                .select()
                .single()
        }
        let booking: Booking = try UserDataRequest.decode(
            Booking.self, from: data, table: Self.table)
        DataLog.userdata.info(
            "confirmed booking for slot \(slot.id, privacy: .public)")
        return booking
    }

    // MARK: - Reading

    /// Rounds still to play: future tee time, not cancelled, soonest first.
    ///
    /// Filtered on `tee_at` — the absolute instant the server resolved once —
    /// and not on `tee_date`, so a 6:16am tomorrow and a 6:16am today that has
    /// already gone are told apart correctly on either side of a DST change.
    public func upcomingRounds() async throws -> [Booking] {
        let userID = try session.requireUserID()

        let data = try await UserDataRequest.data {
            client.from(Self.table)
                .select()
                .eq("user_id", value: userID)
                .gt("tee_at", value: now())
                .is("cancelled_at", value: nil)
                .order("tee_at")
        }
        return try UserDataRequest.decode([Booking].self, from: data, table: Self.table)
    }

    /// Every round, played and unplayed, newest tee time first. What a history
    /// screen reads; upcoming rounds is the filtered view of it.
    public func allBookings() async throws -> [Booking] {
        let userID = try session.requireUserID()

        let data = try await UserDataRequest.data {
            client.from(Self.table)
                .select()
                .eq("user_id", value: userID)
                .order("tee_at", ascending: false)
        }
        return try UserDataRequest.decode([Booking].self, from: data, table: Self.table)
    }

    // MARK: - Cancelling

    /// Mark a round cancelled. The row stays: `unique (user_id, slot_id)` means
    /// deleting it and confirming again would be the same row anyway, and
    /// keeping it is what lets a later yes un-cancel rather than re-insert.
    @discardableResult
    public func cancel(bookingID: UUID) async throws -> Booking {
        let userID = try session.requireUserID()

        let data = try await UserDataRequest.data {
            try client.from(Self.table)
                .update(
                    BookingCancelRow(cancelledAt: now()), returning: .representation)
                .eq("id", value: bookingID)
                .eq("user_id", value: userID)
                .select()
                .single()
        }
        return try UserDataRequest.decode(Booking.self, from: data, table: Self.table)
    }
}

/// The one-column PATCH ``BookingRepository/cancel(bookingID:)`` sends.
struct BookingCancelRow: Encodable {
    let cancelledAt: Date

    enum CodingKeys: String, CodingKey {
        case cancelledAt = "cancelled_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(UserDataFormat.string(from: cancelledAt), forKey: .cancelledAt)
    }
}
