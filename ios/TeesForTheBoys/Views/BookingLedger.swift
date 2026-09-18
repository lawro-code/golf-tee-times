import Combine
import Foundation
import TeesContract

/// A round the golfer said they booked.
///
/// Deliberately not `TeesData.Booking`. That type is a row in Postgres with a
/// user id, a cancellation column and a server-assigned `UUID`; this one is
/// what a screen in track C can hold without linking `TeesData`, which
/// `ios/project.yml` does not let it do. Stage 2 maps one to the other at the
/// seam — `BookingLedger.onBookingConfirmed` is that seam.
///
/// `slotID` is the identity, because the contract's slot id is already stable
/// across scrapes (CONTRACT.md §1) and confirming the same slot twice is one
/// round, not two.
public struct ConfirmedBooking: Identifiable, Equatable, Codable, Sendable {

    public var id: String { slotID }

    /// `course_slug:YYYY-MM-DD:HHMM:tee`.
    public let slotID: String
    public let courseName: String
    /// `YYYY-MM-DD` at the course.
    public let teeDate: String
    /// `HH:MM:SS` at the course.
    public let teeTime: String
    /// The absolute instant, copied straight off the slot. **Never recomputed**
    /// from `teeDate` + `teeTime`: CONTRACT.md §4 resolves Sydney's two
    /// awkward nights once, on the server, and a client that redoes the sum is
    /// a client that gets them wrong twice a year.
    public let teeAt: Date
    /// This booking's hole count, which at Bankstown, Beverley Park and
    /// Brighton Lakes is not the course's (CONTRACT.md §2).
    public let holes: Int
    public let par: Int?
    public let confirmedAt: Date

    public init(
        slotID: String,
        courseName: String,
        teeDate: String,
        teeTime: String,
        teeAt: Date,
        holes: Int,
        par: Int?,
        confirmedAt: Date
    ) {
        self.slotID = slotID
        self.courseName = courseName
        self.teeDate = teeDate
        self.teeTime = teeTime
        self.teeAt = teeAt
        self.holes = holes
        self.par = par
        self.confirmedAt = confirmedAt
    }

    /// The only place a slot becomes a booking.
    public init(slot: Slot, confirmedAt: Date) {
        self.init(
            slotID: slot.id,
            courseName: slot.courseName,
            teeDate: slot.teeDate,
            teeTime: slot.teeTime,
            teeAt: slot.teeAt,
            holes: slot.holes,
            par: slot.par,
            confirmedAt: confirmedAt)
    }
}

/// "Did you book?", asked once, and the rounds the answer produced.
///
/// ## The whole product rule is: ask once
///
/// The golfer taps out to MiClub from the detail screen, books or does not
/// book, and comes back. On return they get one question. A yes becomes a
/// ``ConfirmedBooking``. A no, a swipe away, a phone call landing on top of the
/// dialog — all the same outcome: nothing recorded, never asked again about
/// that slot, no cost to the user for saying no. Re-asking is what makes an app
/// feel like it is nagging, and what is being asked about is a tee time the
/// golfer may well have decided against.
///
/// "Never again" has to survive a relaunch, so it is written through
/// ``ViewsKeyValueStore`` rather than held in memory.
///
/// ## Three pieces of state, three keys
///
/// | Key | Holds | Why separate |
/// |---|---|---|
/// | `pendingTapOuts` | slots tapped out to but not yet asked about | it is a queue, and it empties |
/// | `answered` | every slot id already asked about | the anti-nag rule |
/// | `bookings` | the yeses | the product |
///
/// Separate keys so that a corrupt `bookings` blob cannot take `answered` down
/// with it. Losing the rounds list is annoying; losing "already asked" means
/// prompting somebody a second time about a round they already declined.
///
/// Every read decodes defensively: unreadable JSON is treated as absent. A
/// value written by a future build must degrade to an empty ledger, never to a
/// crash on launch.
///
/// ## What this class deliberately does not do
///
/// It does not cancel the alert the booking satisfies and it does not write to
/// Supabase — track C links neither `TeesData` nor `TeesPush`.
/// ``onBookingConfirmed`` is the callback Stage 2 hangs both off.
@MainActor
public final class BookingLedger: ObservableObject {

    /// Namespaced so nothing can collide with a host app's defaults. Versioned
    /// so a later shape change is a new key rather than a migration.
    public enum Key {
        public static let pendingTapOuts = "tees.views.bookingLedger.pending.v1"
        public static let answered = "tees.views.bookingLedger.answered.v1"
        public static let bookings = "tees.views.bookingLedger.bookings.v1"
    }

    /// The slot the prompt is currently asking about, or nil.
    ///
    /// Non-nil only between ``appDidBecomeActive()`` and an answer — it is set
    /// on return to the app, never on the way out.
    @Published public private(set) var pendingConfirmation: Slot?

    /// Every round confirmed on this device, oldest first. Past rounds stay:
    /// this is a record, and ``upcoming`` is the filtered view of it.
    @Published public private(set) var bookings: [ConfirmedBooking]

    /// Called once per newly confirmed round.
    ///
    /// Stage 2 hangs alert-cancellation and the Supabase write off this. Not
    /// implemented here on purpose: a screen module that knows how to cancel an
    /// alert is a screen module that has grown a network.
    public var onBookingConfirmed: ((ConfirmedBooking) -> Void)?

    /// Tap-outs waiting for the app to come back, oldest first. Persisted, so a
    /// golfer whose phone kills the app while they are on MiClub still gets
    /// asked when they relaunch.
    private var pendingTapOuts: [Slot]

    /// Slot ids that must never be asked about again.
    private var answered: Set<String>

    private let store: ViewsKeyValueStore
    private let now: () -> Date

    /// - Parameters:
    ///   - store: track C's only persistence seam. Pass an
    ///     `InMemoryViewsStore` in a test or a preview and nothing reaches the
    ///     simulator's defaults.
    ///   - now: injected clock. `upcoming` and the tap-out pruning both depend
    ///     on it, and the fixtures are dated 2026 — a test that reads the real
    ///     clock rots.
    public init(
        store: ViewsKeyValueStore = UserDefaultsViewsStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
        self.answered = Self.decode(Set<String>.self, from: store, key: Key.answered) ?? []
        self.bookings = Self.decode([ConfirmedBooking].self, from: store, key: Key.bookings) ?? []
        self.pendingTapOuts = Self.decode([Slot].self, from: store, key: Key.pendingTapOuts) ?? []
        pruneTapOuts()
    }

    // MARK: - Leaving for the club

    /// Remember that the golfer tapped through to MiClub for this slot.
    ///
    /// Called by the detail screen immediately before Safari opens, because
    /// once the app is backgrounded there is no later. It shows nothing: the
    /// question is put on the way back in, not on the way out.
    public func recordTapOut(_ slot: Slot) {
        guard !answered.contains(slot.id) else { return }
        guard !pendingTapOuts.contains(where: { $0.id == slot.id }) else { return }
        pendingTapOuts.append(slot)
        persistTapOuts()
    }

    // MARK: - Coming back

    /// Promote the oldest waiting tap-out to the prompt. At most one slot is
    /// ever asked about at a time, and each slot at most once ever.
    ///
    /// Marking the slot answered *here*, at the moment the question goes on
    /// screen rather than when it is answered, is what makes "asked once"
    /// hold through the awkward cases: a phone call on top of the dialog, the
    /// app being killed with the dialog up, a second `appDidBecomeActive`
    /// arriving while it is still open. A prompt the golfer saw has been
    /// asked, whatever became of it.
    public func appDidBecomeActive() {
        guard pendingConfirmation == nil else { return }
        pruneTapOuts()
        guard let next = pendingTapOuts.first else { return }
        pendingTapOuts.removeFirst()
        answered.insert(next.id)
        persistTapOuts()
        persistAnswered()
        pendingConfirmation = next
    }

    // MARK: - Answering

    /// Yes. Records the round and fires ``onBookingConfirmed`` — once, even if
    /// the same slot is confirmed twice.
    public func confirmBooked(_ slot: Slot) {
        markAnswered(slot.id)
        guard !bookings.contains(where: { $0.slotID == slot.id }) else { return }
        let booking = ConfirmedBooking(slot: slot, confirmedAt: now())
        bookings.append(booking)
        persistBookings()
        onBookingConfirmed?(booking)
    }

    /// No. Costs the golfer nothing and closes the question for good.
    public func declineBooked(_ slot: Slot) {
        markAnswered(slot.id)
    }

    /// Swiped away, tapped outside, interrupted. Identical outcome to a no —
    /// there is no third answer, and treating silence as "ask me later" is the
    /// nagging this type exists to prevent.
    public func dismissPrompt() {
        guard let slot = pendingConfirmation else { return }
        markAnswered(slot.id)
    }

    /// Whether this slot's question is closed, by any of the three routes.
    public func hasBeenAsked(slotID: String) -> Bool {
        answered.contains(slotID)
    }

    // MARK: - Rounds

    /// Confirmed rounds still ahead of the injected clock, soonest first.
    ///
    /// Compared on `teeAt`, the instant the server already resolved, so a round
    /// booked either side of a Sydney clock change sorts correctly without this
    /// module owning an opinion about DST.
    public var upcoming: [ConfirmedBooking] {
        let cutoff = now()
        return bookings
            .filter { $0.teeAt > cutoff }
            .sorted { $0.teeAt < $1.teeAt }
    }

    // MARK: - Internals

    private func markAnswered(_ slotID: String) {
        if pendingConfirmation?.id == slotID {
            pendingConfirmation = nil
        }
        let wasNew = answered.insert(slotID).inserted
        let hadQueued = pendingTapOuts.contains { $0.id == slotID }
        if hadQueued {
            pendingTapOuts.removeAll { $0.id == slotID }
            persistTapOuts()
        }
        if wasNew { persistAnswered() }
    }

    /// Drop tap-outs whose tee time has already passed, and any that have since
    /// been answered by another route.
    ///
    /// A round that has teed off cannot be booked, so asking about it is noise.
    /// This also stops the stored queue growing for the life of the install: it
    /// stays the size of "rounds you tapped through to this week".
    private func pruneTapOuts() {
        let cutoff = now()
        let kept = pendingTapOuts.filter { $0.teeAt > cutoff && !answered.contains($0.id) }
        guard kept.count != pendingTapOuts.count else { return }
        pendingTapOuts = kept
        persistTapOuts()
    }

    // MARK: - Storage

    private func persistTapOuts() { Self.encode(pendingTapOuts, into: store, key: Key.pendingTapOuts) }
    private func persistAnswered() { Self.encode(answered, into: store, key: Key.answered) }
    private func persistBookings() { Self.encode(bookings, into: store, key: Key.bookings) }

    /// Absent, unreadable and written-by-a-future-build all come back nil. The
    /// caller substitutes an empty collection, which is the documented
    /// behaviour: a corrupt ledger loses history, it does not crash a launch.
    private static func decode<T: Decodable>(
        _ type: T.Type,
        from store: ViewsKeyValueStore,
        key: String
    ) -> T? {
        guard let raw = store.string(forKey: key),
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(T.self, from: data)
        else { return nil }
        return value
    }

    /// Stored as a JSON string because ``ViewsKeyValueStore`` is a string
    /// store — one seam, so a test never has to clean up after itself. An
    /// encode that somehow fails clears the key rather than leaving a stale
    /// value that disagrees with memory.
    private static func encode<T: Encodable>(_ value: T, into store: ViewsKeyValueStore, key: String) {
        guard let data = try? JSONEncoder().encode(value),
              let raw = String(data: data, encoding: .utf8)
        else {
            store.set(nil, forKey: key)
            return
        }
        store.set(raw, forKey: key)
    }
}
