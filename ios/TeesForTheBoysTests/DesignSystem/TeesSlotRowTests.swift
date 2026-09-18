import TeesContract
import XCTest
@testable import TeesDesign

/// The `.slot` card's formatting rules.
///
/// The row is the product — a golfer sees hundreds of these and almost nothing
/// else — so every string on it is decided in `Model.init(slot:)` and asserted
/// here rather than computed inside `body`, which this target has no way to
/// inspect.
final class TeesSlotRowTests: XCTestCase {

    // MARK: - Fixtures

    /// Built with the contract's own memberwise initialiser. `golden.json` is a
    /// resource of the TeesContract framework and is not reachable from this
    /// bundle.
    private static func slot(
        teeTime: String = "06:16:00",
        spotsAvailable: Int = 2,
        holes: Int = 18,
        par: Int? = 70,
        requiresRegistration: Bool = false,
        priceMin: Double? = 48,
        tiers: [PriceTier] = [PriceTier(label: "Social", amount: 48)]
    ) -> Slot {
        Slot(
            id: "warringah:2026-09-18:0616:1st-tee-social",
            courseSlug: "warringah",
            courseName: "Warringah Golf Club",
            region: "Northern Beaches",
            driveMinutesFromBondi: 32,
            par: par,
            requiresRegistration: requiresRegistration,
            teeDate: "2026-09-18",
            teeTime: teeTime,
            teeAt: Date(timeIntervalSince1970: 1_789_000_000),
            spotsAvailable: spotsAvailable,
            totalSpots: 4,
            holes: holes,
            priceMin: priceMin,
            priceMax: priceMin,
            priceTiers: tiers,
            bookingType: "1st Tee Social",
            bookingURLString: "https://warringah.miclub.com.au/guests/bookings/x")
    }

    // MARK: - Time

    /// `tee_time` is `HH:MM:SS` — that is how PostgREST renders a Postgres
    /// `time`, and the seconds are always there. A two-component parse turns
    /// `06:16:00` into nothing.
    func testTeeTimeParsesThreeComponentsNotTwo() {
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(teeTime: "06:16:00")).time, "6:16 am")
    }

    /// Midnight and noon are where 12-hour formatting breaks: `12 % 12` is 0,
    /// and a naive port renders them "0:00 pm" and "0:30 am".
    func testNoonAndMidnightAreTheCasesThatBreakTwelveHourTime() {
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(teeTime: "12:00:00")).time, "12:00 pm")
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(teeTime: "00:30:00")).time, "12:30 am")
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(teeTime: "00:00:00")).time, "12:00 am")
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(teeTime: "12:59:00")).time, "12:59 pm")
    }

    func testTimesAcrossTheDay() {
        let cases: [(String, String)] = [
            ("05:04:00", "5:04 am"),
            ("06:16:00", "6:16 am"),
            ("11:59:00", "11:59 am"),
            ("13:00:00", "1:00 pm"),
            ("16:45:00", "4:45 pm"),
            ("23:59:00", "11:59 pm"),
        ]

        for (raw, expected) in cases {
            XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(teeTime: raw)).time, expected, "\(raw)")
        }
    }

    /// Minutes are always two digits, so a column of times does not jitter.
    func testMinutesArePadded() {
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(teeTime: "07:05:00")).time, "7:05 am")
        XCTAssertFalse(TeesSlotRow.Model(slot: Self.slot(teeTime: "07:05:00")).time.contains("7:5 "))
    }

    /// A club that starts sending something else must not blank the row. The
    /// raw value on screen is readable; an empty time is not.
    func testAnUnparseableTimeFallsBackToItselfRatherThanVanishing() {
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(teeTime: "not a time")).time, "not a time")
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(teeTime: "25:00:00")).time, "25:00:00",
                       "an hour that cannot exist is passed through, not wrapped into 1am")
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(teeTime: "06:75:00")).time, "06:75:00")
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(teeTime: "0616")).time, "0616",
                       "a two-component parse is exactly the bug this guards")
    }

    // MARK: - Spots

    /// One spot left is the most urgent state a row has, and "1 spots" reads
    /// like a bug in the very moment a golfer is deciding whether to tap.
    func testOneSpotIsSingular() {
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(spotsAvailable: 1)).spotsLabel, "1 spot")
    }

    func testMoreThanOneSpotIsPlural() {
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(spotsAvailable: 2)).spotsLabel, "2 spots")
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(spotsAvailable: 4)).spotsLabel, "4 spots")
    }

    // MARK: - Holes and par

    /// `slot.holes` is THE BOOKING's hole count. Bankstown, Beverley Park and
    /// Brighton Lakes are 18-hole courses selling 9-hole tee times — 125 slots
    /// in the golden fixture — and holes defaults to 18 in the filters, so a
    /// row that substituted the course's number would show a golfer 18 holes
    /// when the club is selling 9. `CONTRACT.md` §2.
    func testANineHoleBookingNeverReportsEighteen() {
        let model = TeesSlotRow.Model(slot: Self.slot(holes: 9))

        XCTAssertTrue(model.detailLabel.contains("9 holes"), "got \(model.detailLabel)")
        XCTAssertFalse(model.detailLabel.contains("18"), "the booking is 9 holes; 18 is the course's number")
        XCTAssertTrue(model.accessibilityLabel.contains("9 holes"))
        XCTAssertFalse(model.accessibilityLabel.contains("18 holes"))
    }

    func testAnEighteenHoleBookingReportsEighteen() {
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(holes: 18, par: 70)).detailLabel, "18 holes · Par 70")
    }

    /// Par is optional in the contract. A missing one drops the segment — never
    /// "Par nil", and never "Par 0", which reads like a real number.
    func testANilParOmitsTheSegmentEntirely() {
        let model = TeesSlotRow.Model(slot: Self.slot(holes: 18, par: nil))

        XCTAssertEqual(model.detailLabel, "18 holes")
        XCTAssertFalse(model.detailLabel.lowercased().contains("par"))
        XCTAssertFalse(model.detailLabel.contains("nil"))
        XCTAssertFalse(model.detailLabel.contains("0"))
        XCTAssertFalse(model.detailLabel.hasSuffix("·"), "no separator with nothing after it")
        XCTAssertFalse(model.accessibilityLabel.lowercased().contains("par"))
    }

    /// A zero par is bad data, not a par. It is dropped the same way nil is.
    func testAZeroParIsTreatedAsNoPar() {
        XCTAssertEqual(TeesSlotRow.Model(slot: Self.slot(holes: 18, par: 0)).detailLabel, "18 holes")
    }

    /// The gold middot from `.course-meta-divider`, and only between segments.
    func testSegmentsAreSeparatedNotDecorated() {
        let both = TeesSlotRow.Model(slot: Self.slot(holes: 18, par: 70)).detailLabel
        XCTAssertEqual(both.components(separatedBy: "·").count, 2, "one separator between two segments")

        let one = TeesSlotRow.Model(slot: Self.slot(holes: 9, par: nil)).detailLabel
        XCTAssertFalse(one.contains("·"), "one segment needs no separator")
    }

    // MARK: - Price

    func testThePriceComesFromTheBadgeModel() {
        let priced = TeesSlotRow.Model(slot: Self.slot(
            priceMin: 48, tiers: [PriceTier(label: "Social", amount: 48)]))
        XCTAssertEqual(priced.price.headline, "$48")

        let unpriced = TeesSlotRow.Model(slot: Self.slot(priceMin: nil, tiers: []))
        XCTAssertTrue(unpriced.price.isUnknown)
        XCTAssertEqual(unpriced.price.headline, "Price at course")
    }

    // MARK: - Accessibility

    /// The row is a single accessibility element, so this string is the whole
    /// announcement — a golfer swiping a list never hears the labels
    /// separately. Everything they would read has to be in it.
    func testAccessibilityLabelCarriesTimeSpotsAndPrice() {
        let model = TeesSlotRow.Model(slot: Self.slot(
            teeTime: "06:16:00", spotsAvailable: 2, holes: 18, par: 70,
            priceMin: 48, tiers: [PriceTier(label: "Social", amount: 48)]))

        XCTAssertTrue(model.accessibilityLabel.contains("6:16 am"), "got \(model.accessibilityLabel)")
        XCTAssertTrue(model.accessibilityLabel.contains("2 spots"), "got \(model.accessibilityLabel)")
        XCTAssertTrue(model.accessibilityLabel.contains("$48"), "got \(model.accessibilityLabel)")
        XCTAssertTrue(model.accessibilityLabel.contains("18 holes"), "got \(model.accessibilityLabel)")
        XCTAssertTrue(model.accessibilityLabel.contains("Par 70"), "got \(model.accessibilityLabel)")
    }

    /// "·" is read aloud as "middle dot" by some voices and swallowed by
    /// others. The spoken string uses commas, which is also what buys the
    /// pause that makes the sentence land.
    func testTheSpokenSentenceUsesCommasNotTheGoldMiddot() {
        let model = TeesSlotRow.Model(slot: Self.slot())
        XCTAssertFalse(model.accessibilityLabel.contains("·"))
        XCTAssertTrue(model.accessibilityLabel.contains(", "))
    }

    /// An unpriced slot still says something. Silence where the price goes is
    /// the audible version of hiding the row.
    func testAnUnpricedSlotIsStillAnnounced() {
        let model = TeesSlotRow.Model(slot: Self.slot(priceMin: nil, tiers: []))
        XCTAssertTrue(model.accessibilityLabel.contains("price at course"), "got \(model.accessibilityLabel)")
    }

    /// The gold marker is a mark a screen reader cannot see, so the words go
    /// in the sentence.
    func testRegistrationIsSpokenBecauseTheMarkerCannotBe() {
        let marked = TeesSlotRow.Model(slot: Self.slot(requiresRegistration: true))
        XCTAssertTrue(marked.requiresRegistration)
        XCTAssertTrue(marked.accessibilityLabel.contains("registration"), "got \(marked.accessibilityLabel)")

        let unmarked = TeesSlotRow.Model(slot: Self.slot(requiresRegistration: false))
        XCTAssertFalse(unmarked.requiresRegistration)
        XCTAssertFalse(unmarked.accessibilityLabel.contains("registration"))
    }

    // MARK: - Value semantics

    /// Track C holds arrays of these in state and diffs them. Two rows built
    /// from the same slot have to compare equal or every scroll redraws
    /// everything.
    func testTwoModelsFromTheSameSlotAreEqual() {
        let slot = Self.slot()
        XCTAssertEqual(TeesSlotRow.Model(slot: slot), TeesSlotRow.Model(slot: slot))
        XCTAssertNotEqual(
            TeesSlotRow.Model(slot: slot),
            TeesSlotRow.Model(slot: Self.slot(spotsAvailable: 1)))
    }

    // MARK: - The whole sentence, not just its pieces

    /// `contains` passes on a sentence whose pieces are in the wrong order or
    /// run together. The row folds into one accessibility element, so this
    /// exact string is the entire announcement a golfer using VoiceOver gets —
    /// order, separators and all.
    func testTheSpokenSentenceIsTimeThenDetailThenSpotsThenPrice() {
        XCTAssertEqual(
            TeesSlotRow.Model(slot: Self.slot()).accessibilityLabel,
            "6:16 am, 18 holes, Par 70, 2 spots, $48")
    }

    /// The row the golden fixture is full of, where every rule could go wrong
    /// at once: a 9-hole booking at an 18-hole club, no published fee, noon
    /// (the hour 12-hour formatting breaks on), one spot left, and a club that
    /// makes you register before it will take a booking.
    func testTheHardestRealRowIsAnnouncedInFull() {
        let model = TeesSlotRow.Model(slot: Self.slot(
            teeTime: "12:00:00", spotsAvailable: 1, holes: 9, par: nil,
            requiresRegistration: true, priceMin: nil, tiers: []))

        XCTAssertEqual(
            model.accessibilityLabel,
            "12:00 pm, 9 holes, 1 spot, price at course, free registration required")
    }

    /// Registration comes last, after the facts a golfer is choosing on. It is
    /// a caveat, not a headline.
    func testRegistrationIsTheLastThingSaid() {
        let model = TeesSlotRow.Model(slot: Self.slot(requiresRegistration: true))
        XCTAssertTrue(
            model.accessibilityLabel.hasSuffix(", free registration required"),
            "got \(model.accessibilityLabel)")
    }

    // MARK: - The time is not the device's idea of a time

    /// Lower-case "am"/"pm", as `docs/app.js` writes them. A `DateFormatter`
    /// would say "AM" on an en_US simulator, "a.m." on en_GB and something else
    /// again on a phone set to another language — and a test asserting any of
    /// those would be asserting the simulator's settings rather than the app's
    /// behaviour. The hand-rolled formatter is why this string is the same on
    /// every phone.
    func testTheMeridiemIsLowercaseAndNotTheDevicesIdeaOfOne() {
        let morning = TeesSlotRow.Model(slot: Self.slot(teeTime: "06:16:00")).time
        let afternoon = TeesSlotRow.Model(slot: Self.slot(teeTime: "16:45:00")).time

        XCTAssertTrue(morning.hasSuffix(" am"), "got \(morning)")
        XCTAssertTrue(afternoon.hasSuffix(" pm"), "got \(afternoon)")
        XCTAssertFalse(morning.contains("AM"), "an uppercase meridiem is a DateFormatter leaking through")
        XCTAssertFalse(afternoon.contains("PM"), "an uppercase meridiem is a DateFormatter leaking through")
        XCTAssertFalse(morning.contains("."), "no \"a.m.\" either")
    }

    /// An hour or a minute that cannot exist is passed through rather than
    /// wrapped. 24:00 is the other end of the same guard as 25:00: a bare
    /// `% 24` turns it into midnight, which belongs to a different day from the
    /// one this row is filed under.
    func testHoursAndMinutesOutsideTheClockFallBackRatherThanWrapping() {
        for raw in ["24:00:00", "99:00:00", "06:60:00", "06:99:00", "-1:30:00", ":", "06::00"] {
            XCTAssertEqual(
                TeesSlotRow.Model(slot: Self.slot(teeTime: raw)).time, raw,
                "\"\(raw)\" should be passed through untouched")
        }
    }

    /// A row that cannot be timed is still a row with a price and a hole count
    /// on it. The fallback must not take the rest of the card down with it.
    func testAnUnparseableTimeDoesNotPoisonTheRestOfTheRow() {
        let model = TeesSlotRow.Model(slot: Self.slot(teeTime: "not a time", holes: 9, par: nil))

        XCTAssertEqual(model.time, "not a time")
        XCTAssertEqual(model.detailLabel, "9 holes")
        XCTAssertEqual(model.spotsLabel, "2 spots")
        XCTAssertEqual(model.price.headline, "$48")
        XCTAssertTrue(model.accessibilityLabel.hasPrefix("not a time, "), "got \(model.accessibilityLabel)")
    }
}
