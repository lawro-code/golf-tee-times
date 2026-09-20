import XCTest
import TeesContract
@testable import TeesViews

/// What the rounds list shows, and what leaves it.
///
/// The row strings and the ledger's `upcoming` are the whole screen: the body
/// is three `Text`s over them, and `ios/project.yml` is frozen so there is no
/// ViewInspector to assert on it with.
@MainActor
final class UpcomingRoundsScreenTests: XCTestCase {

    private let today = "2026-09-18"

    private func ledger(now: @escaping () -> Date = BookingLedgerFixtures.clock) -> BookingLedger {
        BookingLedger(store: InMemoryViewsStore(), now: now)
    }

    private func booking(
        slot: Slot = BookingLedgerFixtures.slot()
    ) -> ConfirmedBooking {
        ConfirmedBooking(slot: slot, confirmedAt: BookingLedgerFixtures.now)
    }

    // MARK: - The row

    func testTheRowSaysTheDayAndTheTime() {
        XCTAssertEqual(
            UpcomingRoundCopy.when(booking(), today: today),
            "Tomorrow \u{00B7} 8:00 am")
    }

    func testTodayReadsAsToday() {
        let slot = BookingLedgerFixtures.slot(
            teeDate: "2026-09-18",
            teeTime: "16:40:00",
            teeAt: "2026-09-18T16:40:00+10:00")
        XCTAssertEqual(
            UpcomingRoundCopy.when(booking(slot: slot), today: today),
            "Today \u{00B7} 4:40 pm")
    }

    func testAFurtherDayGetsItsDate() {
        let slot = BookingLedgerFixtures.slot(
            teeDate: "2026-09-21",
            teeTime: "10:30:00",
            teeAt: "2026-09-21T10:30:00+10:00")
        XCTAssertEqual(
            UpcomingRoundCopy.when(booking(slot: slot), today: today),
            "Mon 21 Sep \u{00B7} 10:30 am")
    }

    func testTheDetailLineCarriesHolesAndPar() {
        XCTAssertEqual(UpcomingRoundCopy.detail(booking()), "18 holes \u{00B7} par 70")
    }

    func testAClubWithNoPublishedParJustSaysHoles() {
        let slot = BookingLedgerFixtures.slot(par: nil)
        XCTAssertEqual(UpcomingRoundCopy.detail(booking(slot: slot)), "18 holes")
    }

    func testANineHoleRoundSaysNine() {
        // Copied off the slot when it was confirmed, so it is this booking's
        // hole count and not the course's (CONTRACT.md §2).
        let slot = BookingLedgerFixtures.slot(
            id: "beverley-park:2026-09-19:0930:midweek-9-holes",
            courseName: "Beverley Park Golf Club",
            holes: 9,
            par: nil)
        XCTAssertEqual(UpcomingRoundCopy.detail(booking(slot: slot)), "9 holes")
    }

    func testTheRowReadsAsOneSentence() {
        // Three small labels read one at a time are fragments. The date is
        // spelled out, never relative: a label read out of context has to say
        // which day it means.
        XCTAssertEqual(
            UpcomingRoundCopy.accessibilityLabel(booking()),
            "The Coast Golf Club, Saturday 19 September, 8:00 am, 18 holes, par 70.")
    }

    func testTheSpokenLabelUsesTheFullClubName() {
        // Unlike the dialog title, which is short because it is a headline.
        XCTAssertTrue(UpcomingRoundCopy.accessibilityLabel(booking()).hasPrefix("The Coast Golf Club"))
    }

    // MARK: - The list

    func testRoundsAppearSoonestFirst() {
        let led = ledger()
        let later = BookingLedgerFixtures.slot(
            id: "bayview:2026-09-21:1030:default",
            courseName: "Bayview Golf Club",
            teeDate: "2026-09-21",
            teeTime: "10:30:00",
            teeAt: "2026-09-21T10:30:00+10:00")

        led.confirmBooked(later)
        led.confirmBooked(BookingLedgerFixtures.slot())

        XCTAssertEqual(
            led.upcoming.map(\.courseName),
            ["The Coast Golf Club", "Bayview Golf Club"])
    }

    func testARoundThatHasTeedOffDropsOffByItself() {
        var current = BookingLedgerFixtures.now
        let led = BookingLedger(store: InMemoryViewsStore(), now: { current })
        led.confirmBooked(BookingLedgerFixtures.slot())

        XCTAssertEqual(led.upcoming.count, 1)

        // The morning after the round.
        current = BookingLedgerFixtures.date("2026-09-20T07:00:00+10:00")
        XCTAssertTrue(led.upcoming.isEmpty, "nothing sweeps up; the list is computed against the clock")
    }

    func testAScreenWithNoRoundsIsTheEmptyState() {
        let led = ledger()
        XCTAssertTrue(led.upcoming.isEmpty)
        _ = UpcomingRoundsScreen(ledger: led, today: today)
    }

    func testTheEmptyStateExplainsWhatPutsARoundHere() {
        // Nothing the golfer does on this screen fills it, so the copy has to
        // say what does — otherwise an empty list reads like a bug.
        XCTAssertFalse(UpcomingRoundCopy.emptyTitle.isEmpty)
        XCTAssertTrue(UpcomingRoundCopy.emptyMessage.contains("did you book"))
        XCTAssertTrue(UpcomingRoundCopy.emptyMessage.contains("book"))
    }
}

/// What the rounds list gets wrong if anybody reaches for the clock.
///
/// The screen's two jobs are an order and a set of strings. Both have a
/// plausible wrong implementation — sort by the time of day, format from the
/// instant — and both are wrong in ways a golfer notices on the morning of a
/// round rather than in a build.
@MainActor
final class UpcomingRoundsFailurePathTests: XCTestCase {

    private let today = "2026-09-18"

    private func ledger() -> BookingLedger {
        BookingLedger(store: InMemoryViewsStore(), now: BookingLedgerFixtures.clock)
    }

    func testTheRowShowsTheClubsWallClockAndNotTheInstant() {
        // `tee_at` here is deliberately an hour away from the wall clock
        // beside it — exactly what a client that resolved the instant itself
        // across Sydney's October change produces (CONTRACT.md §4). The row
        // must read the club's clock. Formatting from `tee_at` puts the
        // golfer on the first tee an hour out.
        let booking = ConfirmedBooking(
            slotID: "long-reef:2026-10-04:0730:default",
            courseSlug: "long-reef",
            courseName: "Long Reef Golf Club",
            teeDate: "2026-10-04",
            teeTime: "07:30:00",
            teeAt: BookingLedgerFixtures.date("2026-10-04T06:30:00+11:00"),
            holes: 18,
            par: 72,
            confirmedAt: BookingLedgerFixtures.now)

        XCTAssertEqual(
            UpcomingRoundCopy.when(booking, today: "2026-10-01"),
            "Sun 4 Oct \u{00B7} 7:30 am")
        XCTAssertTrue(UpcomingRoundCopy.accessibilityLabel(booking).contains("7:30 am"))
    }

    func testRoundsSortByTheInstantAndNotByTheTimeOfDay() {
        // This evening, then tomorrow at dawn. Sorting on `tee_time` puts
        // 06:00 first and tells the golfer their next round is the one after
        // next.
        let led = ledger()
        let tomorrowDawn = BookingLedgerFixtures.slot(
            id: "eastlake:2026-09-19:0600:default",
            courseName: "Eastlake Golf Club",
            teeDate: "2026-09-19",
            teeTime: "06:00:00",
            teeAt: "2026-09-19T06:00:00+10:00")
        let thisEvening = BookingLedgerFixtures.slot(
            id: "moore-park:2026-09-18:1800:default",
            courseName: "Moore Park Golf Club",
            teeDate: "2026-09-18",
            teeTime: "18:00:00",
            teeAt: "2026-09-18T18:00:00+10:00")

        led.confirmBooked(tomorrowDawn)
        led.confirmBooked(thisEvening)

        XCTAssertEqual(
            led.upcoming.map(\.courseName),
            ["Moore Park Golf Club", "Eastlake Golf Club"],
            "soonest first, whatever order they were confirmed in")
    }

    func testTwoRoundsOnTheSameDayKeepTheirOrder() {
        let led = ledger()
        let later = BookingLedgerFixtures.slot(
            id: "the-coast:2026-09-19:1120:default",
            teeDate: "2026-09-19",
            teeTime: "11:20:00",
            teeAt: "2026-09-19T11:20:00+10:00")

        led.confirmBooked(later)
        led.confirmBooked(BookingLedgerFixtures.slot())

        XCTAssertEqual(
            led.upcoming.map(\.teeTime),
            ["08:00:00", "11:20:00"])
    }

    func testTheSpokenLabelOfANineHoleRoundWithNoParEndsCleanly() {
        // The label swaps the middle dot for a comma. With no par there is no
        // dot to swap, and a naive replacement leaves a stray separator or a
        // double space in the middle of a spoken sentence.
        let booking = ConfirmedBooking(
            slot: BookingLedgerFixtures.slot(
                id: "beverley-park:2026-09-19:0930:midweek-9-holes",
                courseName: "Beverley Park Golf Club",
                teeDate: "2026-09-19",
                teeTime: "09:30:00",
                teeAt: "2026-09-19T09:30:00+10:00",
                holes: 9,
                par: nil),
            confirmedAt: BookingLedgerFixtures.now)

        XCTAssertEqual(
            UpcomingRoundCopy.accessibilityLabel(booking),
            "Beverley Park Golf Club, Saturday 19 September, 9:30 am, 9 holes.")
        XCTAssertFalse(UpcomingRoundCopy.accessibilityLabel(booking).contains("\u{00B7}"))
        XCTAssertFalse(UpcomingRoundCopy.accessibilityLabel(booking).contains("  "))
    }

    func testTheSpokenLabelNeverSaysTodayOrTomorrow() {
        // A row read out of context has to say which day it means; "Today" in
        // a label read at 11pm is a round that has already been played.
        let todayBooking = ConfirmedBooking(
            slot: BookingLedgerFixtures.slot(
                teeDate: "2026-09-18",
                teeTime: "16:40:00",
                teeAt: "2026-09-18T16:40:00+10:00"),
            confirmedAt: BookingLedgerFixtures.now)
        let label = UpcomingRoundCopy.accessibilityLabel(todayBooking)

        XCTAssertFalse(label.contains("Today"))
        XCTAssertFalse(label.contains("Tomorrow"))
        XCTAssertTrue(label.contains("Friday 18 September"))
        XCTAssertEqual(
            UpcomingRoundCopy.when(todayBooking, today: today),
            "Today \u{00B7} 4:40 pm",
            "the visible row still says Today; only the spoken one spells it out")
    }

    func testTheRowSurvivesADateItCannotParse() {
        // A row that cannot be formatted is still a round the golfer booked.
        let booking = ConfirmedBooking(
            slot: BookingLedgerFixtures.slot(teeDate: "2026-13-45"),
            confirmedAt: BookingLedgerFixtures.now)

        XCTAssertEqual(UpcomingRoundCopy.when(booking, today: today), "2026-13-45 \u{00B7} 8:00 am")
        XCTAssertTrue(UpcomingRoundCopy.accessibilityLabel(booking).hasSuffix("18 holes, par 70."))
    }

    func testAListOfNothingButPastRoundsIsTheEmptyState() {
        // The empty state is not only a fresh install: it is also every round
        // having been played. The copy has to make sense in both.
        let led = ledger()
        led.confirmBooked(BookingLedgerFixtures.pastSlot())

        XCTAssertEqual(led.bookings.count, 1, "the record keeps it")
        XCTAssertTrue(led.upcoming.isEmpty, "the list does not")
        _ = UpcomingRoundsScreen(ledger: led, today: today)
    }
}
