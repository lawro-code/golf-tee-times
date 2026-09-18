import XCTest
import TeesContract
@testable import TeesViews

/// Slots and instants for ticket C4's tests, shared across the five files in
/// this ticket.
///
/// Every date is fixed. The fixtures are dated September and October 2026, and
/// a test that reads the real clock passes today and fails on a date nobody
/// will connect back to it.
enum BookingLedgerFixtures {

    static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let parsed = f.date(from: iso) else {
            preconditionFailure("fixture date \(iso) does not parse")
        }
        return parsed
    }

    /// Friday 18 September 2026, 7am in Sydney. Every ledger in these tests is
    /// built on it.
    static let now = date("2026-09-18T07:00:00+10:00")

    static func clock() -> Date { now }

    static func slot(
        id: String = "the-coast:2026-09-19:0800:default",
        courseName: String = "The Coast Golf Club",
        teeDate: String = "2026-09-19",
        teeTime: String = "08:00:00",
        teeAt: String = "2026-09-19T08:00:00+10:00",
        holes: Int = 18,
        par: Int? = 70
    ) -> Slot {
        Slot(
            id: id,
            courseSlug: String(id.split(separator: ":").first ?? "the-coast"),
            courseName: courseName,
            region: "Eastern Suburbs",
            driveMinutesFromBondi: 12,
            par: par,
            requiresRegistration: false,
            teeDate: teeDate,
            teeTime: teeTime,
            teeAt: date(teeAt),
            spotsAvailable: 2,
            totalSpots: 4,
            holes: holes,
            priceMin: 55,
            priceMax: 55,
            priceTiers: [],
            bookingType: "Social",
            bookingURLString: "https://thecoast.miclub.com.au/guests/bookings/1")
    }

    /// A round already teed off relative to ``now``.
    static func pastSlot() -> Slot {
        slot(
            id: "woollahra:2026-09-17:0700:default",
            courseName: "Woollahra Golf Club",
            teeDate: "2026-09-17",
            teeTime: "07:00:00",
            teeAt: "2026-09-17T07:00:00+10:00")
    }
}

@MainActor
final class BookingLedgerTests: XCTestCase {

    private func makeLedger(
        store: ViewsKeyValueStore,
        now: @escaping () -> Date = BookingLedgerFixtures.clock
    ) -> BookingLedger {
        BookingLedger(store: store, now: now)
    }

    // MARK: - Raising the prompt

    func testTapOutThenActivationRaisesThePromptExactlyOnce() {
        let store = InMemoryViewsStore()
        let ledger = makeLedger(store: store)
        let slot = BookingLedgerFixtures.slot()

        XCTAssertNil(ledger.pendingConfirmation, "nothing is asked on the way out")

        ledger.recordTapOut(slot)
        XCTAssertNil(ledger.pendingConfirmation, "still nothing until the app comes back")

        ledger.appDidBecomeActive()
        XCTAssertEqual(ledger.pendingConfirmation?.id, slot.id)

        // Answered, then the app is backgrounded and returns again.
        ledger.declineBooked(slot)
        XCTAssertNil(ledger.pendingConfirmation)
        ledger.appDidBecomeActive()
        XCTAssertNil(ledger.pendingConfirmation, "a second activation must not re-ask")
    }

    func testActivationWhileAPromptIsOpenDoesNotSwapTheSlot() {
        let store = InMemoryViewsStore()
        let ledger = makeLedger(store: store)
        let first = BookingLedgerFixtures.slot()
        let second = BookingLedgerFixtures.slot(
            id: "bexley:2026-09-20:0930:default",
            courseName: "Bexley Golf Club",
            teeDate: "2026-09-20",
            teeTime: "09:30:00",
            teeAt: "2026-09-20T09:30:00+10:00")

        ledger.recordTapOut(first)
        ledger.recordTapOut(second)
        ledger.appDidBecomeActive()
        XCTAssertEqual(ledger.pendingConfirmation?.id, first.id, "oldest tap-out first")

        ledger.appDidBecomeActive()
        XCTAssertEqual(ledger.pendingConfirmation?.id, first.id, "one question at a time")

        // Answer the first and the second is next in line.
        ledger.declineBooked(first)
        ledger.appDidBecomeActive()
        XCTAssertEqual(ledger.pendingConfirmation?.id, second.id)
    }

    func testActivationWithNoTapOutAsksNothing() {
        let ledger = makeLedger(store: InMemoryViewsStore())
        ledger.appDidBecomeActive()
        XCTAssertNil(ledger.pendingConfirmation)
    }

    // MARK: - Asked once, whichever answer

    func testConfirmingPreventsASecondAskAcrossARelaunch() {
        assertAnsweringIsFinal { ledger, slot in ledger.confirmBooked(slot) }
    }

    func testDecliningPreventsASecondAskAcrossARelaunch() {
        assertAnsweringIsFinal { ledger, slot in ledger.declineBooked(slot) }
    }

    func testDismissingPreventsASecondAskAcrossARelaunch() {
        assertAnsweringIsFinal { ledger, _ in ledger.dismissPrompt() }
    }

    /// The shared shape of the three: ask, answer, then prove a brand new
    /// ledger reading the same store will not ask again. "Never again" that
    /// only lasts until the app is killed is not never again.
    private func assertAnsweringIsFinal(
        answer: (BookingLedger, Slot) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let store = InMemoryViewsStore()
        let slot = BookingLedgerFixtures.slot()

        let first = makeLedger(store: store)
        first.recordTapOut(slot)
        first.appDidBecomeActive()
        XCTAssertEqual(first.pendingConfirmation?.id, slot.id, file: file, line: line)

        answer(first, slot)
        XCTAssertNil(first.pendingConfirmation, file: file, line: line)
        XCTAssertTrue(first.hasBeenAsked(slotID: slot.id), file: file, line: line)

        let relaunched = makeLedger(store: store)
        XCTAssertTrue(relaunched.hasBeenAsked(slotID: slot.id), file: file, line: line)

        relaunched.recordTapOut(slot)
        relaunched.appDidBecomeActive()
        XCTAssertNil(
            relaunched.pendingConfirmation,
            "a slot already answered must never be asked about again",
            file: file, line: line)
    }

    func testAPromptLeftUnansweredIsStillNeverAskedAgain() {
        // A phone call lands on the dialog and the app is killed. The golfer
        // saw the question; asking a second time is the nagging this prevents.
        let store = InMemoryViewsStore()
        let slot = BookingLedgerFixtures.slot()

        let first = makeLedger(store: store)
        first.recordTapOut(slot)
        first.appDidBecomeActive()
        XCTAssertNotNil(first.pendingConfirmation)

        let relaunched = makeLedger(store: store)
        XCTAssertTrue(relaunched.hasBeenAsked(slotID: slot.id))
        relaunched.appDidBecomeActive()
        XCTAssertNil(relaunched.pendingConfirmation)
    }

    func testATapOutSurvivesARelaunchBeforeTheQuestionIsAsked() {
        // Killed while over on MiClub, before coming back. The question is
        // still owed.
        let store = InMemoryViewsStore()
        let slot = BookingLedgerFixtures.slot()

        makeLedger(store: store).recordTapOut(slot)

        let relaunched = makeLedger(store: store)
        XCTAssertFalse(relaunched.hasBeenAsked(slotID: slot.id))
        relaunched.appDidBecomeActive()
        XCTAssertEqual(relaunched.pendingConfirmation?.id, slot.id)
    }

    func testTappingOutTwiceAsksOnce() {
        let ledger = makeLedger(store: InMemoryViewsStore())
        let slot = BookingLedgerFixtures.slot()

        ledger.recordTapOut(slot)
        ledger.recordTapOut(slot)
        ledger.appDidBecomeActive()
        XCTAssertEqual(ledger.pendingConfirmation?.id, slot.id)

        ledger.declineBooked(slot)
        ledger.appDidBecomeActive()
        XCTAssertNil(ledger.pendingConfirmation, "the duplicate tap-out must not queue a second question")
    }

    func testATapOutWhoseTeeTimeHasPassedIsNeverAsked() {
        // Nothing useful comes of asking about a round that has already teed
        // off, and pruning is what stops the stored queue growing forever.
        let ledger = makeLedger(store: InMemoryViewsStore())
        ledger.recordTapOut(BookingLedgerFixtures.pastSlot())
        ledger.appDidBecomeActive()
        XCTAssertNil(ledger.pendingConfirmation)
    }

    func testDismissWithNothingPendingIsHarmless() {
        let ledger = makeLedger(store: InMemoryViewsStore())
        ledger.dismissPrompt()
        XCTAssertNil(ledger.pendingConfirmation)
        XCTAssertTrue(ledger.bookings.isEmpty)
    }

    // MARK: - Confirming

    func testConfirmingAppendsABookingAndFiresTheCallbackOnce() throws {
        let store = InMemoryViewsStore()
        let ledger = makeLedger(store: store)
        let slot = BookingLedgerFixtures.slot()

        var fired: [ConfirmedBooking] = []
        ledger.onBookingConfirmed = { fired.append($0) }

        ledger.recordTapOut(slot)
        ledger.appDidBecomeActive()
        ledger.confirmBooked(slot)

        XCTAssertEqual(ledger.bookings.count, 1)
        XCTAssertEqual(fired.count, 1, "Stage 2 cancels an alert off this; twice would cancel twice")

        let booking = try XCTUnwrap(ledger.bookings.first)
        XCTAssertEqual(booking.id, slot.id)
        XCTAssertEqual(booking.slotID, slot.id)
        XCTAssertEqual(booking.courseName, "The Coast Golf Club")
        XCTAssertEqual(booking.teeDate, "2026-09-19")
        XCTAssertEqual(booking.teeTime, "08:00:00")
        XCTAssertEqual(booking.teeAt, slot.teeAt, "tee_at is copied, never recomputed")
        XCTAssertEqual(booking.holes, 18)
        XCTAssertEqual(booking.par, 70)
        XCTAssertEqual(booking.confirmedAt, BookingLedgerFixtures.now)
    }

    func testConfirmingTheSameSlotTwiceRecordsOneRound() {
        let ledger = makeLedger(store: InMemoryViewsStore())
        let slot = BookingLedgerFixtures.slot()

        var fired = 0
        ledger.onBookingConfirmed = { _ in fired += 1 }

        ledger.confirmBooked(slot)
        ledger.confirmBooked(slot)

        XCTAssertEqual(ledger.bookings.count, 1)
        XCTAssertEqual(fired, 1)
    }

    func testBookingsSurviveARelaunch() {
        let store = InMemoryViewsStore()
        makeLedger(store: store).confirmBooked(BookingLedgerFixtures.slot())

        let relaunched = makeLedger(store: store)
        XCTAssertEqual(relaunched.bookings.count, 1)
        XCTAssertEqual(relaunched.upcoming.count, 1)
    }

    // MARK: - Upcoming

    func testUpcomingDropsPastRoundsAndSortsAscending() {
        let ledger = makeLedger(store: InMemoryViewsStore())

        let later = BookingLedgerFixtures.slot(
            id: "bayview:2026-09-21:1030:default",
            courseName: "Bayview Golf Club",
            teeDate: "2026-09-21",
            teeTime: "10:30:00",
            teeAt: "2026-09-21T10:30:00+10:00")
        let sooner = BookingLedgerFixtures.slot()
        let past = BookingLedgerFixtures.pastSlot()

        // Confirmed out of order on purpose.
        ledger.confirmBooked(later)
        ledger.confirmBooked(past)
        ledger.confirmBooked(sooner)

        XCTAssertEqual(ledger.bookings.count, 3, "the record keeps every yes")
        XCTAssertEqual(
            ledger.upcoming.map(\.slotID),
            [sooner.id, later.id],
            "soonest first, and a round that has teed off is gone")
    }

    func testARoundDropsOffUpcomingWhenTheClockPassesIt() {
        // Same ledger, same booking, a clock that moves. Nothing sweeps up:
        // `upcoming` is computed against the injected clock every read.
        let store = InMemoryViewsStore()
        var current = BookingLedgerFixtures.now
        let ledger = BookingLedger(store: store, now: { current })

        ledger.confirmBooked(BookingLedgerFixtures.slot())
        XCTAssertEqual(ledger.upcoming.count, 1)

        current = BookingLedgerFixtures.date("2026-09-19T08:00:01+10:00")
        XCTAssertTrue(ledger.upcoming.isEmpty)
        XCTAssertEqual(ledger.bookings.count, 1, "it left the list, not the record")
    }

    // MARK: - Corrupt storage

    func testCorruptStoredJSONYieldsAnEmptyLedgerRatherThanACrash() {
        let store = InMemoryViewsStore(seed: [
            BookingLedger.Key.pendingTapOuts: "{ this is not json",
            BookingLedger.Key.answered: "[[[",
            BookingLedger.Key.bookings: "\u{FFFD}"
        ])

        let ledger = makeLedger(store: store)

        XCTAssertNil(ledger.pendingConfirmation)
        XCTAssertTrue(ledger.bookings.isEmpty)
        XCTAssertTrue(ledger.upcoming.isEmpty)
        XCTAssertFalse(ledger.hasBeenAsked(slotID: "the-coast:2026-09-19:0800:default"))

        // And it still works from there.
        ledger.appDidBecomeActive()
        XCTAssertNil(ledger.pendingConfirmation)

        let slot = BookingLedgerFixtures.slot()
        ledger.recordTapOut(slot)
        ledger.appDidBecomeActive()
        XCTAssertEqual(ledger.pendingConfirmation?.id, slot.id)
    }

    func testStoredJSONOfTheWrongShapeIsTreatedAsAbsent() {
        // A value a future build might write: valid JSON, wrong type.
        let store = InMemoryViewsStore(seed: [
            BookingLedger.Key.answered: "{\"slots\":[\"the-coast:2026-09-19:0800:default\"]}",
            BookingLedger.Key.bookings: "42"
        ])

        let ledger = makeLedger(store: store)
        XCTAssertFalse(ledger.hasBeenAsked(slotID: "the-coast:2026-09-19:0800:default"))
        XCTAssertTrue(ledger.bookings.isEmpty)
    }

    func testAnEmptyStoreIsAnEmptyLedger() {
        let ledger = makeLedger(store: InMemoryViewsStore())
        XCTAssertNil(ledger.pendingConfirmation)
        XCTAssertTrue(ledger.bookings.isEmpty)
        XCTAssertTrue(ledger.upcoming.isEmpty)
    }
}

/// The ways the ledger can go wrong rather than the way it goes right.
///
/// Each of these was written by asking "what would a plausible wrong
/// implementation do here?" and then pinning the answer: one key instead of
/// three, dedupe held in memory, a queue that is pruned in memory but not in
/// storage, `upcoming` computed off the calendar day instead of the clock.
/// Every one fails against at least one such implementation.
@MainActor
final class BookingLedgerFailurePathTests: XCTestCase {

    private func makeLedger(
        store: ViewsKeyValueStore,
        now: @escaping () -> Date = BookingLedgerFixtures.clock
    ) -> BookingLedger {
        BookingLedger(store: store, now: now)
    }

    /// Two days before the fixtures' `now`, for seeding a queue while the
    /// rounds in it were still ahead.
    private func twoDaysEarlier() -> Date {
        BookingLedgerFixtures.date("2026-09-16T07:00:00+10:00")
    }

    // MARK: - Three keys, and why

    func testACorruptBookingsBlobDoesNotLoseWhoHasAlreadyBeenAsked() {
        // The documented reason the ledger writes three keys instead of one.
        // Losing the rounds list is annoying; losing "already asked" means
        // prompting somebody a second time about a round they declined.
        let slotID = BookingLedgerFixtures.slot().id
        let store = InMemoryViewsStore(seed: [
            BookingLedger.Key.answered: "[\"\(slotID)\"]",
            BookingLedger.Key.bookings: "{ truncated mid-write"
        ])

        let ledger = makeLedger(store: store)

        XCTAssertTrue(ledger.bookings.isEmpty, "the unreadable half is dropped")
        XCTAssertTrue(ledger.hasBeenAsked(slotID: slotID), "the anti-nag record survives it")

        ledger.recordTapOut(BookingLedgerFixtures.slot())
        ledger.appDidBecomeActive()
        XCTAssertNil(ledger.pendingConfirmation, "and still refuses to ask a second time")
    }

    func testACorruptAnsweredBlobDoesNotLoseTheRounds() {
        // The same argument in the other direction.
        let store = InMemoryViewsStore()
        makeLedger(store: store).confirmBooked(BookingLedgerFixtures.slot())
        store.set("[[[", forKey: BookingLedger.Key.answered)

        let ledger = makeLedger(store: store)
        XCTAssertEqual(ledger.bookings.count, 1)
        XCTAssertEqual(ledger.upcoming.count, 1)
    }

    // MARK: - Asked once has to outlive the process

    func testASecondConfirmationAfterARelaunchIsNotASecondRound() {
        // Dedupe held only in memory passes every same-process test and fails
        // the first time the app is killed between two taps.
        let store = InMemoryViewsStore()
        let slot = BookingLedgerFixtures.slot()
        makeLedger(store: store).confirmBooked(slot)

        let relaunched = makeLedger(store: store)
        var fired = 0
        relaunched.onBookingConfirmed = { _ in fired += 1 }
        relaunched.confirmBooked(slot)

        XCTAssertEqual(relaunched.bookings.count, 1, "one slot id is one round, across launches")
        XCTAssertEqual(fired, 0, "Stage 2 cancels an alert off this callback; a re-fire cancels twice")
    }

    func testAnAnswerGivenBeforeTheQuestionStillClosesIt() {
        // The dialog's buttons capture their slot, so an answer can arrive for
        // a slot the ledger is not currently asking about.
        let ledger = makeLedger(store: InMemoryViewsStore())
        let slot = BookingLedgerFixtures.slot()

        ledger.declineBooked(slot)
        XCTAssertTrue(ledger.hasBeenAsked(slotID: slot.id))

        ledger.recordTapOut(slot)
        ledger.appDidBecomeActive()
        XCTAssertNil(ledger.pendingConfirmation, "an answered slot must never be queued again")
    }

    // MARK: - The callback Stage 2 hangs alert-cancellation off

    func testDecliningNeverFiresTheBookingCallback() {
        let ledger = makeLedger(store: InMemoryViewsStore())
        var fired: [ConfirmedBooking] = []
        ledger.onBookingConfirmed = { fired.append($0) }

        let slot = BookingLedgerFixtures.slot()
        ledger.recordTapOut(slot)
        ledger.appDidBecomeActive()
        ledger.declineBooked(slot)

        XCTAssertTrue(fired.isEmpty, "a no must not cancel the alert the golfer still wants")
        XCTAssertTrue(ledger.bookings.isEmpty)
    }

    func testDismissingNeverFiresTheBookingCallback() {
        let ledger = makeLedger(store: InMemoryViewsStore())
        var fired: [ConfirmedBooking] = []
        ledger.onBookingConfirmed = { fired.append($0) }

        let slot = BookingLedgerFixtures.slot()
        ledger.recordTapOut(slot)
        ledger.appDidBecomeActive()
        ledger.dismissPrompt()

        XCTAssertTrue(fired.isEmpty, "silence is a no, and a no records nothing")
        XCTAssertTrue(ledger.bookings.isEmpty)
    }

    func testTheCallbackSeesTheRoundAlreadyInTheLedger() {
        // Stage 2's handler reads the ledger. Firing before the append would
        // hand it a ledger that does not yet contain the round it is about.
        let ledger = makeLedger(store: InMemoryViewsStore())
        let slot = BookingLedgerFixtures.slot()

        var seenFromInsideTheCallback: [String] = []
        ledger.onBookingConfirmed = { [unowned ledger] _ in
            seenFromInsideTheCallback = ledger.bookings.map(\.slotID)
        }

        ledger.confirmBooked(slot)
        XCTAssertEqual(seenFromInsideTheCallback, [slot.id])
    }

    // MARK: - The queue

    func testAStaleTapOutDoesNotBlockTheQuestionBehindIt() {
        // Both queued while both were ahead; the first tees off while the
        // golfer is still over on MiClub. The clock moves inside one ledger,
        // so nothing has re-read the queue from storage and pruned it on the
        // way in — an implementation that only checks the head of the queue
        // goes quiet here and never asks about the round behind it.
        var current = BookingLedgerFixtures.date("2026-09-16T07:00:00+10:00")
        let ledger = BookingLedger(store: InMemoryViewsStore(), now: { current })
        let past = BookingLedgerFixtures.pastSlot()
        let live = BookingLedgerFixtures.slot()

        ledger.recordTapOut(past)
        ledger.recordTapOut(live)

        current = BookingLedgerFixtures.now
        ledger.appDidBecomeActive()
        XCTAssertEqual(
            ledger.pendingConfirmation?.id,
            live.id,
            "the dead tap-out is skipped, not the live one behind it")
    }

    func testAStaleTapOutIsDroppedFromStorageAndNotOnlyFromMemory() {
        // A queue pruned in memory but written back whole grows for the life
        // of the install, and every relaunch re-reads the rounds it just
        // decided to ignore.
        let store = InMemoryViewsStore()
        let past = BookingLedgerFixtures.pastSlot()
        let live = BookingLedgerFixtures.slot()

        let earlier = makeLedger(store: store, now: twoDaysEarlier)
        earlier.recordTapOut(past)
        earlier.recordTapOut(live)
        XCTAssertEqual(
            store.string(forKey: BookingLedger.Key.pendingTapOuts)?.contains(past.id),
            true,
            "precondition: the stale round really was queued")

        _ = makeLedger(store: store)

        let stored = store.string(forKey: BookingLedger.Key.pendingTapOuts) ?? ""
        XCTAssertFalse(stored.contains(past.id), "the stored queue is rewritten, not just filtered on read")
        XCTAssertTrue(stored.contains(live.id), "and the question still owed is still there")
    }

    func testConfirmingSomeOtherRoundLeavesTheOpenQuestionOnScreen() {
        let ledger = makeLedger(store: InMemoryViewsStore())
        let asked = BookingLedgerFixtures.slot()
        let elsewhere = BookingLedgerFixtures.slot(
            id: "bexley:2026-09-20:0930:default",
            courseName: "Bexley Golf Club",
            teeDate: "2026-09-20",
            teeTime: "09:30:00",
            teeAt: "2026-09-20T09:30:00+10:00")

        ledger.recordTapOut(asked)
        ledger.appDidBecomeActive()
        ledger.confirmBooked(elsewhere)

        XCTAssertEqual(
            ledger.pendingConfirmation?.id,
            asked.id,
            "an unrelated answer must not close the dialog the golfer is looking at")
        XCTAssertEqual(ledger.bookings.map(\.slotID), [elsewhere.id])
    }

    // MARK: - Boundaries

    func testARoundTeeingOffThisInstantIsNeitherAskedAboutNorUpcoming() {
        let ledger = makeLedger(store: InMemoryViewsStore())
        let onTheHour = BookingLedgerFixtures.slot(
            id: "moore-park:2026-09-18:0700:default",
            courseName: "Moore Park Golf Club",
            teeDate: "2026-09-18",
            teeTime: "07:00:00",
            teeAt: "2026-09-18T07:00:00+10:00")

        ledger.recordTapOut(onTheHour)
        ledger.appDidBecomeActive()
        XCTAssertNil(ledger.pendingConfirmation, "it is teeing off; the question is already pointless")

        ledger.confirmBooked(onTheHour)
        XCTAssertEqual(ledger.bookings.count, 1, "it is still a round that was booked")
        XCTAssertTrue(ledger.upcoming.isEmpty, "but it is no longer ahead of the clock")
    }

    func testUpcomingGoesByTheClockAndNotByTheCalendarDay() {
        // Both rounds are today. A list built from `tee_date >= today` shows
        // the golfer a round they played at dawn.
        let ledger = makeLedger(store: InMemoryViewsStore())
        let dawn = BookingLedgerFixtures.slot(
            id: "the-coast:2026-09-18:0530:default",
            teeDate: "2026-09-18",
            teeTime: "05:30:00",
            teeAt: "2026-09-18T05:30:00+10:00")
        let dusk = BookingLedgerFixtures.slot(
            id: "the-coast:2026-09-18:1640:default",
            teeDate: "2026-09-18",
            teeTime: "16:40:00",
            teeAt: "2026-09-18T16:40:00+10:00")

        ledger.confirmBooked(dawn)
        ledger.confirmBooked(dusk)

        XCTAssertEqual(ledger.upcoming.map(\.slotID), [dusk.id])
    }

    // MARK: - The instant the server resolved

    func testTheServersInstantSurvivesTheRoundTripUntouched() throws {
        // April, the repeated hour: `tee_at` is an hour off what a client
        // recomputing it from tee_date + tee_time would produce (CONTRACT.md
        // §4). Storage must hand back the server's answer, not its own.
        let clock = { BookingLedgerFixtures.date("2026-04-01T07:00:00+11:00") }
        let store = InMemoryViewsStore()
        let slot = BookingLedgerFixtures.slot(
            id: "long-reef:2026-04-05:0230:default",
            courseName: "Long Reef Golf Club",
            teeDate: "2026-04-05",
            teeTime: "02:30:00",
            teeAt: "2026-04-05T02:30:00+11:00")

        makeLedger(store: store, now: clock).confirmBooked(slot)

        let relaunched = makeLedger(store: store, now: clock)
        let booking = try XCTUnwrap(relaunched.bookings.first)
        XCTAssertEqual(booking.teeAt, slot.teeAt, "tee_at is stored, not recomputed")
        XCTAssertEqual(booking.teeDate, "2026-04-05", "and the wall clock is stored beside it")
        XCTAssertEqual(booking.teeTime, "02:30:00")
        XCTAssertEqual(relaunched.upcoming.map(\.slotID), [slot.id])
    }
}
