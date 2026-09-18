import XCTest
import TeesContract
@testable import TeesViews

/// What the dialog says, and that its three exits land in the same place.
///
/// The `body` itself is not asserted on — `ios/project.yml` is frozen, so there
/// is no ViewInspector in this target. The two things worth proving are the
/// copy, which is a product decision, and the ledger outcome behind each
/// button, which is the whole rule.
@MainActor
final class DidYouBookPromptTests: XCTestCase {

    func testTheTitleNamesTheTimeAndTheClub() {
        let slot = BookingLedgerFixtures.slot()
        XCTAssertEqual(
            DidYouBookPrompt.title(for: slot),
            "Did you book 8:00 am at The Coast?")
    }

    func testTheTitleUsesTheShortClubName() {
        // "Brighton Lakes Recreation Club" in a dialog title wraps to three
        // lines on a small phone at AX5, and the suffix carries nothing.
        let slot = BookingLedgerFixtures.slot(
            id: "brighton-lakes:2026-09-19:1312:default",
            courseName: "Brighton Lakes Recreation Club",
            teeTime: "13:12:00",
            teeAt: "2026-09-19T13:12:00+10:00")
        XCTAssertEqual(
            DidYouBookPrompt.title(for: slot),
            "Did you book 1:12 pm at Brighton Lakes?")
    }

    func testTheMessageCarriesTheDayAndTheRound() {
        let slot = BookingLedgerFixtures.slot()
        XCTAssertEqual(
            DidYouBookPrompt.message(for: slot),
            "Saturday 19 September \u{00B7} 18 holes \u{00B7} par 70")
    }

    func testTheMessageSurvivesAClubThatPublishesNoPar() {
        let slot = BookingLedgerFixtures.slot(par: nil)
        XCTAssertEqual(
            DidYouBookPrompt.message(for: slot),
            "Saturday 19 September \u{00B7} 18 holes")
    }

    func testANineHoleBookingSaysNine() {
        // Bankstown is an 18-hole course that sells 9-hole rounds. The number
        // in the prompt is the booking's, not the club's (CONTRACT.md §2).
        let slot = BookingLedgerFixtures.slot(
            id: "bankstown:2026-09-19:0724:social-play-9-holes-only",
            courseName: "Bankstown Golf Club",
            teeTime: "07:24:00",
            teeAt: "2026-09-19T07:24:00+10:00",
            holes: 9)
        XCTAssertTrue(DidYouBookPrompt.message(for: slot).contains("9 holes"))
    }

    func testTheTwoButtonsAreLabelledInPlainWords() {
        XCTAssertEqual(DidYouBookPrompt.confirmTitle, "Booked it")
        XCTAssertEqual(DidYouBookPrompt.declineTitle, "Didn't book")
    }

    // MARK: - The three exits

    func testTheBookedButtonRecordsTheRound() {
        let ledger = BookingLedger(store: InMemoryViewsStore(), now: BookingLedgerFixtures.clock)
        let slot = BookingLedgerFixtures.slot()
        ledger.recordTapOut(slot)
        ledger.appDidBecomeActive()

        ledger.confirmBooked(slot)

        XCTAssertNil(ledger.pendingConfirmation, "answering closes the dialog")
        XCTAssertEqual(ledger.bookings.map(\.slotID), [slot.id])
    }

    func testDecliningAndDismissingAreTheSameOutcome() {
        let slot = BookingLedgerFixtures.slot()

        let declined = BookingLedger(store: InMemoryViewsStore(), now: BookingLedgerFixtures.clock)
        declined.recordTapOut(slot)
        declined.appDidBecomeActive()
        declined.declineBooked(slot)

        let dismissed = BookingLedger(store: InMemoryViewsStore(), now: BookingLedgerFixtures.clock)
        dismissed.recordTapOut(slot)
        dismissed.appDidBecomeActive()
        dismissed.dismissPrompt()

        for ledger in [declined, dismissed] {
            XCTAssertNil(ledger.pendingConfirmation)
            XCTAssertTrue(ledger.bookings.isEmpty, "a no costs the golfer nothing")
            XCTAssertTrue(ledger.hasBeenAsked(slotID: slot.id))
        }
    }

    func testTheDismissBindingIsSafeAfterAButtonHasAlreadyAnswered() {
        // SwiftUI writes `isPresented = false` for a button press as well as an
        // outside tap, so `dismissPrompt` runs after `confirmBooked` in one of
        // the two orderings. It must not undo the yes.
        let ledger = BookingLedger(store: InMemoryViewsStore(), now: BookingLedgerFixtures.clock)
        let slot = BookingLedgerFixtures.slot()
        ledger.recordTapOut(slot)
        ledger.appDidBecomeActive()

        ledger.confirmBooked(slot)
        ledger.dismissPrompt()

        XCTAssertEqual(ledger.bookings.count, 1)
        XCTAssertNil(ledger.pendingConfirmation)
    }

    func testTheModifierCanBeAttachedWithoutAPendingSlot() {
        // Attached unconditionally at the tab root; it must render nothing
        // until there is something to ask about.
        let ledger = BookingLedger(store: InMemoryViewsStore(), now: BookingLedgerFixtures.clock)
        XCTAssertNil(ledger.pendingConfirmation)
        _ = DidYouBookPrompt(ledger: ledger)
    }
}

/// The dialog's awkward cases: data it cannot format, and answers arriving in
/// an order SwiftUI does not guarantee.
@MainActor
final class DidYouBookPromptFailurePathTests: XCTestCase {

    private func ledger() -> BookingLedger {
        BookingLedger(store: InMemoryViewsStore(), now: BookingLedgerFixtures.clock)
    }

    func testTheQuestionSurvivesDataItCannotFormat() {
        // A dialog is the one thing in the app that must never render blank:
        // it has already interrupted the golfer, and an empty question cannot
        // be answered. Both formatters fall back to the raw contract value.
        let badDate = BookingLedgerFixtures.slot(teeDate: "not-a-date")
        XCTAssertEqual(
            DidYouBookPrompt.title(for: badDate),
            "Did you book 8:00 am at The Coast?")
        XCTAssertEqual(
            DidYouBookPrompt.message(for: badDate),
            "not-a-date \u{00B7} 18 holes \u{00B7} par 70")

        let badTime = BookingLedgerFixtures.slot(teeTime: "half seven")
        XCTAssertEqual(
            DidYouBookPrompt.title(for: badTime),
            "Did you book half seven at The Coast?")
        XCTAssertFalse(
            DidYouBookPrompt.title(for: badTime).contains("  "),
            "a missing piece must not leave a hole in the sentence")
    }

    func testTheQuestionNeverShowsARawIdentifier() {
        let slot = BookingLedgerFixtures.slot()
        XCTAssertFalse(DidYouBookPrompt.title(for: slot).contains(slot.id))
        XCTAssertFalse(DidYouBookPrompt.message(for: slot).contains(slot.id))
        XCTAssertFalse(DidYouBookPrompt.title(for: slot).contains(slot.courseSlug))
    }

    func testAnOutsideTapAfterADeclineDoesNotReopenAnything() {
        // SwiftUI writes `isPresented = false` once for the button and once
        // for the dismissal; `dismissPrompt` runs on a ledger that has already
        // answered. It must stay a no-op rather than re-queue the question.
        let led = ledger()
        let slot = BookingLedgerFixtures.slot()
        led.recordTapOut(slot)
        led.appDidBecomeActive()

        led.declineBooked(slot)
        led.dismissPrompt()
        led.dismissPrompt()

        XCTAssertNil(led.pendingConfirmation)
        XCTAssertTrue(led.bookings.isEmpty)
        led.appDidBecomeActive()
        XCTAssertNil(led.pendingConfirmation, "the question is closed for good")
    }

    func testTheDialogAsksAboutTheSlotTheLedgerIsHoldingNotTheLatestTapOut() throws {
        // The golfer tapped through to two rounds before coming back. The
        // title on screen has to be the one the ledger promoted, or the
        // answer records the wrong round.
        let led = ledger()
        let first = BookingLedgerFixtures.slot()
        let second = BookingLedgerFixtures.slot(
            id: "bayview:2026-09-21:1030:default",
            courseName: "Bayview Golf Club",
            teeDate: "2026-09-21",
            teeTime: "10:30:00",
            teeAt: "2026-09-21T10:30:00+10:00")

        led.recordTapOut(first)
        led.recordTapOut(second)
        led.appDidBecomeActive()

        let asking = try XCTUnwrap(led.pendingConfirmation)
        XCTAssertEqual(
            DidYouBookPrompt.title(for: asking),
            "Did you book 8:00 am at The Coast?")
        XCTAssertEqual(asking.id, first.id)
        XCTAssertNotEqual(asking.id, second.id)
    }
}
