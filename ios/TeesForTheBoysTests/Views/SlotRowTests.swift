import SwiftUI
import XCTest
import TeesContract
@testable import TeesViews

/// The results row.
///
/// A row is one accessibility element carrying one sentence, and the sentence
/// is the assertion: a golfer using VoiceOver has to be able to decide about a
/// tee time from it without reaching any of the six labels separately. Six
/// facts have to survive into that sentence — club, time, holes, par, price and
/// spots — and the ones that are easy to drop are exactly the ones CONTRACT.md
/// says must not be.
final class SlotRowTests: XCTestCase {

    private var slots: [Slot] = []

    override func setUpWithError() throws {
        slots = try ContractLoader.fixture("minimal").slots
        XCTAssertEqual(slots.count, 9, "the fixture changed shape; these tests assume 9 slots")
    }

    private func slot(_ id: String) throws -> Slot {
        try XCTUnwrap(slots.first { $0.id == id }, "no slot \(id) in minimal.json")
    }

    /// The label the row hands to VoiceOver. Asserting on it rather than on the
    /// rendered body is forced — `ios/project.yml` is frozen, so there is no
    /// ViewInspector — but it is also the right thing to assert: the string is
    /// the product decision.
    private func label(_ slot: Slot) -> String {
        SlotFormatting.accessibilityLabel(for: slot)
    }

    // MARK: - Everything the row shows reaches the label

    func testTheLabelCarriesClubTimeHolesParPriceAndSpots() throws {
        let bayview = try slot("bayview:2026-10-04:0945:1st-tee-social-play")
        let spoken = label(bayview)

        XCTAssertTrue(spoken.contains("Bayview Golf Club"), spoken)
        XCTAssertTrue(spoken.contains("9:45 am"), spoken)
        XCTAssertTrue(spoken.contains("18 holes"), spoken)
        XCTAssertTrue(spoken.contains("par 71"), spoken)
        XCTAssertTrue(spoken.contains("$70"), spoken)
        XCTAssertTrue(spoken.contains("2 of 4 spots"), spoken)
    }

    /// CONTRACT.md §2. Bankstown is an 18-hole club selling a 9-hole round, and
    /// the number in the row is the booking's, not the club's. Getting this
    /// wrong sends someone to nine holes when they asked for eighteen.
    func testANineHoleBookingAtAnEighteenHoleClubSaysNine() throws {
        let bankstown = try slot("bankstown:2026-10-03:1120:social-play-9-holes-only")
        XCTAssertEqual(bankstown.holes, 9)

        let spoken = label(bankstown)
        XCTAssertTrue(spoken.contains("9 holes"), spoken)
        XCTAssertFalse(spoken.contains("18 holes"), spoken)
    }

    /// CONTRACT.md §3. One slot in six publishes no fee. The row says so rather
    /// than showing a blank where a number goes, and never disappears.
    func testAnUnpricedSlotSaysPriceAtCourse() throws {
        let warringah = try slot("warringah:2026-10-03:0616:1st-tee-social")
        XCTAssertTrue(warringah.priceIsUnknown)

        XCTAssertEqual(SlotFormatting.price(warringah), "Price at course")
        XCTAssertTrue(label(warringah).localizedCaseInsensitiveContains("price at course"))
    }

    /// The registration warning is the one part of a row that changes whether a
    /// tap is worth making, so it is appended to the sentence rather than left
    /// as a visual-only badge.
    func testAClubNeedingAFreeAccountSaysSoInTheLabel() throws {
        let bayview = try slot("bayview:2026-10-04:0945:1st-tee-social-play")
        let note = try XCTUnwrap(SlotFormatting.registrationNote(for: bayview))

        XCTAssertTrue(note.contains("Bayview"), note)
        XCTAssertTrue(label(bayview).contains(note), label(bayview))
    }

    func testAClubNeedingNothingCarriesNoRegistrationNote() throws {
        let coast = try slot("the-coast:2026-10-03:0800:1st-tee")
        XCTAssertNil(SlotFormatting.registrationNote(for: coast))
    }

    /// A two-tee start is two rows, and the id is what keeps them apart in a
    /// `ForEach`. If the ids collided the list would drop one of Warringah's
    /// two 06:16 bookings on the floor.
    func testATwoTeeStartGivesTwoRowsWithDistinctIdentities() throws {
        let first = try slot("warringah:2026-10-03:0616:1st-tee-social")
        let tenth = try slot("warringah:2026-10-03:0616:10th-tee-social")

        XCTAssertEqual(SlotResult(slot: first).id, first.id)
        XCTAssertNotEqual(SlotResult(slot: first).id, SlotResult(slot: tenth).id)
        XCTAssertEqual(SlotFormatting.time(first), SlotFormatting.time(tenth))
    }

    /// Every row in the fixture produces a non-empty sentence that at minimum
    /// names the club and ends as a sentence. A row whose label came back blank
    /// would be invisible to VoiceOver while visible to everyone else.
    func testEveryRowInTheFixtureHasAUsableLabel() {
        for slot in slots {
            let spoken = label(slot)
            XCTAssertFalse(spoken.isEmpty, slot.id)
            XCTAssertTrue(spoken.contains(slot.courseName), slot.id)
            XCTAssertTrue(spoken.contains("\(slot.holes) holes"), slot.id)
            XCTAssertTrue(spoken.contains("spots"), slot.id)
            XCTAssertTrue(spoken.contains("."), slot.id)
        }
    }

    // MARK: - Construction

    /// `SearchScreen.resultsList` builds a row straight from `SlotResult`'s
    /// own `.slot` — `TeesSlotRow` (the on-brand card this list actually
    /// renders, `DesignSystem/Components/TeesSlotRow.swift`) takes a `Slot`,
    /// not a `SlotResult`, so this is the seam that has to keep agreeing.
    func testAResultUnwrapsToTheSameSlotItWasBuiltFrom() throws {
        let slot = try slot("the-coast:2026-10-03:0800:1st-tee")
        XCTAssertEqual(SlotResult(slot: slot).slot, slot)
    }
}

// MARK: - Tester's pass, ticket C2

/// The rows the fixtures do not contain.
///
/// Every slot in `minimal.json` publishes a par and every one of them is
/// either priced or plainly unpriced, so the suite above never sees the two
/// cases where a row has to leave something out rather than show it.
final class SlotRowEdgeCaseTests: XCTestCase {

    /// `par` is optional in the contract — a club that does not publish one is
    /// a decode away, and no fixture has it. The row shows holes and par on one
    /// line, so a missing par has to drop out of the sentence rather than land
    /// in it as a gap, a zero or the word nil.
    func testARowForAClubWithNoPublishedParStillReadsAsASentence() {
        let slot = slotWithNoPublishedPar()

        XCTAssertEqual(SlotFormatting.holesAndPar(slot), "18 holes")

        let spoken = SlotFormatting.accessibilityLabel(for: slot)
        XCTAssertTrue(spoken.contains("18 holes"), spoken)
        XCTAssertFalse(spoken.lowercased().contains("par"), spoken)
        XCTAssertFalse(spoken.lowercased().contains("nil"), spoken)
        XCTAssertTrue(spoken.hasSuffix("."), spoken)
        XCTAssertTrue(spoken.contains("2 of 4 spots"), spoken)
    }

    /// The row picks its price style from `slot.priceIsUnknown`; the day
    /// section sinks unpriced rows using `SlotResult.priceIsUnknown`; the
    /// golfer reads `SlotFormatting.price`. Three spellings of one fact, and if
    /// any two disagree a row sinks to the bottom of its day while still
    /// showing a number — or shows "Price at course" in the style meant for a
    /// price.
    func testTheRowTheOrderingAndTheCopyAgreeOnAnUnknownPrice() throws {
        for slot in try ContractLoader.fixture("minimal").slots {
            XCTAssertEqual(SlotResult(slot: slot).priceIsUnknown, slot.priceIsUnknown, slot.id)
            XCTAssertEqual(
                SlotFormatting.price(slot) == SlotFormatting.priceAtCourse,
                slot.priceIsUnknown,
                "\(slot.id): the row's text and the ordering flag disagree")
        }
    }

    private func slotWithNoPublishedPar() -> Slot {
        Slot(
            id: "riverbank:2026-10-03:0800:1st-tee",
            courseSlug: "riverbank",
            courseName: "Riverbank Golf Club",
            region: "Test",
            driveMinutesFromBondi: 20,
            par: nil,
            requiresRegistration: false,
            teeDate: "2026-10-03",
            teeTime: "08:00:00",
            teeAt: ContractDate.date(from: "2026-10-03T08:00:00+10:00")!,
            spotsAvailable: 2,
            totalSpots: 4,
            holes: 18,
            priceMin: 55,
            priceMax: 55,
            priceTiers: [PriceTier(label: "Social", amount: 55)],
            bookingType: "1st Tee",
            bookingURLString: "https://example.com/book")
    }
}
