import XCTest
@testable import TeesData
import TeesContract

/// Asked once. The rest of this file is that sentence, tested.
final class BookingPromptLedgerTests: XCTestCase {

    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Its own suite per test: the ledger is the only thing in it, and
        // nothing here can reach the app's defaults.
        suiteName = "B4BookingPromptLedgerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeLedger(now: Date = B4Fixtures.now) -> BookingPromptLedger {
        BookingPromptLedger(defaults: defaults, now: { now })
    }

    /// The prompt appears once when the golfer comes back from MiClub.
    func testASlotIsAskedAboutOnce() {
        let ledger = makeLedger()
        let slot = B4Fixtures.slot()

        XCTAssertTrue(ledger.shouldAsk(about: slot))
        ledger.recordAsked(slot: slot)
        XCTAssertFalse(ledger.shouldAsk(about: slot))
        XCTAssertFalse(ledger.shouldAsk(about: slot))
    }

    /// A no, a dismiss and a phone call landing on top of the prompt all cost
    /// the golfer nothing — because the ledger records that it *asked*, not
    /// what the answer was. There is no answer to record here, and that is the
    /// design.
    func testANoOrADismissIsNeverAskedAgain() {
        let ledger = makeLedger()
        let slot = B4Fixtures.slot()

        ledger.recordAsked(slot: slot)      // shown; swiped away; no answer
        XCTAssertFalse(ledger.shouldAsk(about: slot))
        XCTAssertEqual(ledger.askedSlotIDs, [slot.id])
    }

    /// Two-tee starts mean two slots can share a course, a date and a minute.
    /// The ledger is keyed on the slot id, which is the only thing that tells
    /// them apart.
    func testTwoTeesAtTheSameMinuteAreTwoDifferentQuestions() {
        let ledger = makeLedger()
        let first = B4Fixtures.slot(id: "warringah:2026-10-03:0616:1st-tee-social")
        let tenth = B4Fixtures.slot(id: "warringah:2026-10-03:0616:10th-tee-social")

        ledger.recordAsked(slot: first)
        XCTAssertFalse(ledger.shouldAsk(about: first))
        XCTAssertTrue(ledger.shouldAsk(about: tenth))
    }

    /// It survives a relaunch, because the prompt does not get a second go just
    /// because the app was killed.
    func testItSurvivesBeingRebuiltOnTheSameDefaults() {
        let slot = B4Fixtures.slot()
        makeLedger().recordAsked(slot: slot)

        let afterRelaunch = makeLedger()
        XCTAssertFalse(afterRelaunch.shouldAsk(about: slot))
    }

    /// An entry is only worth keeping while the tee time is still ahead. After
    /// it has passed the slot cannot be booked and the question can never be
    /// asked, so the row is dropped rather than kept for the life of the
    /// install.
    func testEntriesArePrunedOnceTheTeeTimeHasPassed() {
        let slot = B4Fixtures.slot()          // tees off 2026-10-03T08:00+10:00
        let before = makeLedger(now: B4Fixtures.now)
        before.recordAsked(slot: slot)
        XCTAssertEqual(before.askedSlotIDs, [slot.id])

        let after = makeLedger(now: ContractDate.date(from: "2026-10-03T09:00:00+10:00")!)
        after.prune()
        XCTAssertTrue(after.askedSlotIDs.isEmpty)
        XCTAssertNil(defaults.dictionary(forKey: BookingPromptLedger.storageKey))
    }

    /// Pruning one slot must not take a live one with it.
    func testPruningKeepsSlotsThatHaveNotTeedOffYet() {
        let past = B4Fixtures.slot(
            id: "past", teeDate: "2026-10-01", teeAt: "2026-10-01T06:00:00+10:00")
        let future = B4Fixtures.slot(
            id: "future", teeDate: "2026-10-05", teeAt: "2026-10-05T06:00:00+11:00")

        let ledger = makeLedger(now: ContractDate.date(from: "2026-09-30T06:00:00+10:00")!)
        ledger.recordAsked(slot: past)
        ledger.recordAsked(slot: future)

        let later = makeLedger(now: ContractDate.date(from: "2026-10-02T06:00:00+10:00")!)
        XCTAssertEqual(later.askedSlotIDs, ["future"])
    }

    /// Asking is a read. The prompt is consulted on the path back from MiClub
    /// and on every launch after it, and a disk write on that path buys nothing.
    func testAskingDoesNotWriteAnything() {
        XCTAssertTrue(makeLedger().shouldAsk(about: B4Fixtures.slot()))
        XCTAssertNil(
            defaults.dictionary(forKey: BookingPromptLedger.storageKey),
            "a question that was never answered leaves nothing behind")
    }

    /// What is stored is the tee time, as a plain unix timestamp. That is what
    /// makes pruning possible at all, and what a later version reading this key
    /// will still be able to make sense of.
    func testAnEntryRemembersTheTeeTimeItCanBeThrownAwayAfter() throws {
        let slot = B4Fixtures.slot()
        makeLedger().recordAsked(slot: slot)

        let stored = try XCTUnwrap(
            defaults.dictionary(forKey: BookingPromptLedger.storageKey) as? [String: Double])
        XCTAssertEqual(stored[slot.id], slot.teeAt.timeIntervalSince1970)
    }

    /// Recording is read-modify-write, and the prompt can be answered while a
    /// launch is pruning. Without a lock around it most of these answers are
    /// lost, and a lost answer means the golfer is asked again.
    func testAnswersRecordedAtOnceAreNotLost() {
        let ledger = makeLedger()
        let teeAt = ContractDate.date(from: "2026-10-03T08:00:00+10:00")!

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            ledger.recordAsked(slotID: "the-coast:2026-10-03:0800:tee-\(index)", teeAt: teeAt)
        }

        XCTAssertEqual(ledger.askedSlotIDs.count, 64)
    }

    func testResetForgetsEverything() {
        let ledger = makeLedger()
        ledger.recordAsked(slot: B4Fixtures.slot())
        ledger.reset()
        XCTAssertTrue(ledger.askedSlotIDs.isEmpty)
    }

    /// It is not the payload cache, and it must not be: that file is thrown
    /// away and rewritten on every refresh, and answers are not tee times.
    func testItStoresOneKeyInUserDefaultsAndNothingElse() {
        let ledger = makeLedger()
        ledger.recordAsked(slot: B4Fixtures.slot())

        let stored = defaults.dictionaryRepresentation()
            .keys.filter { $0.hasPrefix("tees.") }
        XCTAssertEqual(stored, [BookingPromptLedger.storageKey])
    }
}
