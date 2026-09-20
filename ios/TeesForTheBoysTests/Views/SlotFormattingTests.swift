import XCTest
import TeesContract
@testable import TeesViews

/// Formatting is where the product decisions are — "$55–$110", "Price at
/// course", "2 of 4 spots" — and `ios/project.yml` is frozen, so a rendered
/// SwiftUI body cannot be inspected. These strings are therefore the only
/// place a screen's copy is actually checked.
final class SlotFormattingTests: XCTestCase {

    private var byID: [String: Slot] = [:]

    override func setUpWithError() throws {
        for slot in try ContractLoader.fixture("minimal").slots { byID[slot.id] = slot }
    }

    private func slot(_ id: String) throws -> Slot {
        try XCTUnwrap(byID[id], "\(id) is not in minimal.json")
    }

    // MARK: - Time

    func testTimeIsTwelveHourWithNoLeadingZero() throws {
        XCTAssertEqual(
            SlotFormatting.time(try slot("warringah:2026-10-03:0616:1st-tee-social")), "6:16 am")
        XCTAssertEqual(
            SlotFormatting.time(try slot("brighton-lakes:2026-10-10:1307:1st-tee-social")), "1:07 pm")
        XCTAssertEqual(
            SlotFormatting.time(try slot("woollahra:2026-10-04:1630:public-bookings")), "4:30 pm")
    }

    /// The two that a naive `hour % 12` gets wrong.
    func testMidnightAndNoon() {
        XCTAssertEqual(SlotFormatting.time(teeTime: "00:05:00"), "12:05 am")
        XCTAssertEqual(SlotFormatting.time(teeTime: "12:00:00"), "12:00 pm")
        XCTAssertEqual(SlotFormatting.time(teeTime: "12:59:00"), "12:59 pm")
        XCTAssertEqual(SlotFormatting.time(teeTime: "23:00:00"), "11:00 pm")
    }

    /// A tee time we cannot read is still a bookable round. Showing the raw
    /// value beats showing nothing.
    func testUnparseableTimeFallsBackToTheRawValue() {
        XCTAssertEqual(SlotFormatting.time(teeTime: "tee off at dawn"), "tee off at dawn")
    }

    /// Shaped like a time but out of range. The fallback is the raw string, not
    /// a rendered `"24:00 am"` — a row we cannot read has to look unreadable
    /// rather than plausible.
    func testAnOutOfRangeTimeIsShownRawRatherThanRendered() {
        XCTAssertEqual(SlotFormatting.time(teeTime: "24:00:00"), "24:00:00")
        XCTAssertEqual(SlotFormatting.time(teeTime: "07:60:00"), "07:60:00")
        XCTAssertEqual(SlotFormatting.time(teeTime: "-1:00:00"), "-1:00:00")
        XCTAssertEqual(SlotFormatting.time(teeTime: ""), "")
    }

    // MARK: - Price

    func testSinglePriceIsOneNumber() throws {
        XCTAssertEqual(SlotFormatting.price(try slot("woollahra:2026-10-03:0712:public-play")), "$45")
        XCTAssertEqual(
            SlotFormatting.price(try slot("bankstown:2026-10-03:1120:social-play-9-holes-only")),
            "$32")
    }

    /// The Coast publishes three tiers, $55 to $110.
    func testPriceRangeUsesAnEnDash() throws {
        XCTAssertEqual(
            SlotFormatting.price(try slot("the-coast:2026-10-03:0800:1st-tee")),
            "$55\u{2013}$110")
    }

    /// CONTRACT.md §3: one slot in six publishes no fee. That is ordinary data,
    /// so the label is plain rather than an error.
    func testUnpricedSlotSaysPriceAtCourse() throws {
        XCTAssertEqual(
            SlotFormatting.price(try slot("warringah:2026-10-03:0616:1st-tee-social")),
            SlotFormatting.priceAtCourse)
        XCTAssertEqual(SlotFormatting.priceAtCourse, "Price at course")
    }

    func testWholeDollarsDropTheCents() {
        XCTAssertEqual(SlotFormatting.money(55), "$55")
        XCTAssertEqual(SlotFormatting.money(55.004), "$55")
        XCTAssertEqual(SlotFormatting.money(55.5), "$55.50")
        XCTAssertEqual(SlotFormatting.money(0), "$0")
    }

    /// `Int(Double)` is a non-failable, trapping initialiser: it crashes on
    /// anything past `Int.max` (~9.22e18) and on NaN. A `price_min`/`price_max`
    /// this large is perfectly valid-shaped JSON that the decoder accepts
    /// (CONTRACT.md's lenient numeric-as-string rule included), so `money`
    /// must degrade to `priceAtCourse` rather than crash every screen that
    /// formats a price — the same guard `TeesPriceTierBadge.Model.wholeDollars`
    /// already has.
    func testAnAbsurdlyLargePriceDegradesRatherThanCrashing() throws {
        XCTAssertEqual(SlotFormatting.money(1e20), SlotFormatting.priceAtCourse)
        XCTAssertEqual(SlotFormatting.money(-1e20), SlotFormatting.priceAtCourse)
        XCTAssertEqual(SlotFormatting.money(.nan), SlotFormatting.priceAtCourse)
        XCTAssertEqual(SlotFormatting.money(.infinity), SlotFormatting.priceAtCourse)

        let huge = Self.priced(try slot("the-coast:2026-10-03:0800:1st-tee"), min: 1e20, max: nil)
        XCTAssertEqual(SlotFormatting.price(huge), SlotFormatting.priceAtCourse)
    }

    /// An en dash in the middle of a currency range is read as a hyphen or
    /// skipped, so the spoken form spells the range out.
    func testSpokenPriceAvoidsTheEnDash() throws {
        XCTAssertEqual(
            SlotFormatting.priceSpoken(try slot("the-coast:2026-10-03:0800:1st-tee")),
            "from $55 to $110")
        XCTAssertEqual(
            SlotFormatting.priceSpoken(try slot("warringah:2026-10-03:0616:1st-tee-social")),
            "price at course")
    }

    /// `price_max` below `price_min` is a club publishing its fee table oddly,
    /// not something to render as `"$110–$55"`. One number beats a backwards
    /// range, and the spoken form must not invent a "from … to …" either.
    func testABackwardsPriceRangeShowsOneNumberRatherThanAnInvertedRange() throws {
        let backwards = Self.priced(try slot("the-coast:2026-10-03:0800:1st-tee"), min: 110, max: 55)
        XCTAssertEqual(SlotFormatting.price(backwards), "$110")
        XCTAssertEqual(SlotFormatting.priceSpoken(backwards), "$110")

        let equal = Self.priced(try slot("the-coast:2026-10-03:0800:1st-tee"), min: 55, max: 55)
        XCTAssertEqual(SlotFormatting.price(equal), "$55")
    }

    /// A slot with a `price_max` and no `price_min` is missing the number the
    /// filter and the label both key on, so it is an unpriced slot — never
    /// `"$–$110"`.
    func testAMaxWithNoMinIsJustAnUnpricedSlot() throws {
        let halfPriced = Self.priced(try slot("the-coast:2026-10-03:0800:1st-tee"), min: nil, max: 110)
        XCTAssertEqual(SlotFormatting.price(halfPriced), SlotFormatting.priceAtCourse)
        XCTAssertTrue(SlotResult(slot: halfPriced).priceIsUnknown)
    }

    // MARK: - The round

    func testPlayers() throws {
        XCTAssertEqual(
            SlotFormatting.players(try slot("warringah:2026-10-03:0616:1st-tee-social")),
            "2 of 4 spots")
        XCTAssertEqual(
            SlotFormatting.players(try slot("woollahra:2026-10-03:0712:public-play")),
            "1 of 4 spots")
    }

    /// The hole count is the booking's. Bankstown is an 18-hole club with a
    /// par of 71 selling a 9-hole tee time: "9 holes · par 71".
    func testHolesAndParUsesTheBookingsHoleCount() throws {
        XCTAssertEqual(
            SlotFormatting.holesAndPar(try slot("warringah:2026-10-03:0616:1st-tee-social")),
            "18 holes \u{00B7} par 70")
        XCTAssertEqual(
            SlotFormatting.holesAndPar(try slot("bankstown:2026-10-03:1120:social-play-9-holes-only")),
            "9 holes \u{00B7} par 71")
    }

    func testParClauseIsDroppedWhenParIsUnknown() throws {
        let base = try slot("warringah:2026-10-03:0616:1st-tee-social")
        let noPar = Self.copy(base, par: nil, driveMinutes: base.driveMinutesFromBondi)
        XCTAssertEqual(SlotFormatting.holesAndPar(noPar), "18 holes")
    }

    func testDrive() throws {
        let base = try slot("warringah:2026-10-03:0616:1st-tee-social")
        XCTAssertEqual(SlotFormatting.drive(base), "32 min from Bondi")
        XCTAssertNil(
            SlotFormatting.drive(Self.copy(base, par: base.par, driveMinutes: nil)),
            "nil means show nothing, never show a zero")
    }

    // MARK: - Days

    func testTodayAndTomorrow() {
        XCTAssertEqual(SlotFormatting.dayTitle(for: "2026-10-03", today: "2026-10-03"), "Today")
        XCTAssertEqual(SlotFormatting.dayTitle(for: "2026-10-04", today: "2026-10-03"), "Tomorrow")
        XCTAssertEqual(SlotFormatting.dayTitle(for: "2026-10-10", today: "2026-10-03"), "Sat 10 Oct")
        XCTAssertEqual(SlotFormatting.dayTitle(for: "2026-10-02", today: "2026-10-03"), "Fri 2 Oct")
    }

    /// Sydney puts the clocks forward on 4 October 2026 — 02:00 becomes 03:00,
    /// so that day is 23 hours long. "Tomorrow" still has to mean the next
    /// calendar day, which is why this is calendar arithmetic in Sydney and not
    /// `addingTimeInterval(86_400)`.
    func testTomorrowSurvivesTheOctoberClockChange() {
        XCTAssertEqual(SlotFormatting.dayAfter("2026-10-03"), "2026-10-04")
        XCTAssertEqual(SlotFormatting.dayTitle(for: "2026-10-04", today: "2026-10-03"), "Tomorrow")
    }

    /// And the April change, where a day is 25 hours long.
    func testTomorrowSurvivesTheAprilClockChange() {
        XCTAssertEqual(SlotFormatting.dayAfter("2027-04-03"), "2027-04-04")
    }

    func testDayAfterCrossesMonthAndYearBoundaries() {
        XCTAssertEqual(SlotFormatting.dayAfter("2026-09-30"), "2026-10-01")
        XCTAssertEqual(SlotFormatting.dayAfter("2026-12-31"), "2027-01-01")
        XCTAssertNil(SlotFormatting.dayAfter("not a date"))
    }

    /// If "today" itself is unreadable, nothing is relative to it. Falling
    /// through to the absolute date is right; calling the next day "Tomorrow"
    /// off a date we could not parse would be worse than saying nothing.
    func testAnUnreadableTodayDegradesToAbsoluteDatesRatherThanGuessing() {
        XCTAssertEqual(SlotFormatting.dayTitle(for: "2026-10-04", today: "not a date"), "Sun 4 Oct")
        XCTAssertEqual(SlotFormatting.dayTitle(for: "2026-10-03", today: ""), "Sat 3 Oct")
    }

    func testUnparseableDateFallsBackToTheRawValue() {
        XCTAssertEqual(SlotFormatting.dayTitle(for: "yesterday", today: "2026-10-03"), "yesterday")
        XCTAssertEqual(SlotFormatting.spokenDayTitle(for: "yesterday"), "yesterday")
    }

    func testSpokenDayIsAbsoluteAndLong() {
        XCTAssertEqual(SlotFormatting.spokenDayTitle(for: "2026-10-03"), "Saturday 3 October")
        XCTAssertEqual(SlotFormatting.spokenDayTitle(for: "2026-09-19"), "Saturday 19 September")
    }

    // MARK: - Clubs

    func testShortCourseNameDropsTheSuffixTheFifteenActuallyUse() {
        XCTAssertEqual(SlotFormatting.shortCourseName("Bayview Golf Club"), "Bayview")
        XCTAssertEqual(SlotFormatting.shortCourseName("Castle Cove Country Club"), "Castle Cove")
        XCTAssertEqual(
            SlotFormatting.shortCourseName("Brighton Lakes Recreation Club"), "Brighton Lakes")
        XCTAssertEqual(SlotFormatting.shortCourseName("Long Reef"), "Long Reef")
        XCTAssertEqual(SlotFormatting.shortCourseName("Golf Club"), "Golf Club",
                       "a club whose whole name is the suffix keeps it")
    }

    /// Bayview makes you create a free public-member account before checkout.
    /// The surprise lands here rather than on the club's payment page.
    func testRegistrationNoteOnlyForClubsThatNeedOne() throws {
        XCTAssertEqual(
            SlotFormatting.registrationNote(for: try slot("bayview:2026-10-04:0945:1st-tee-social-play")),
            "Bayview needs a free club account before you can book")
        XCTAssertNil(
            SlotFormatting.registrationNote(for: try slot("woollahra:2026-10-03:0712:public-play")))
    }

    // MARK: - Accessibility

    /// A row is six small labels; read one at a time they are noise. One
    /// sentence carries the lot.
    func testAccessibilityLabelCarriesTheWholeRow() throws {
        XCTAssertEqual(
            SlotFormatting.accessibilityLabel(for: try slot("the-coast:2026-10-03:0800:1st-tee")),
            "The Coast Golf Club, 8:00 am, Saturday 3 October, 18 holes, par 71, "
            + "from $55 to $110, 4 of 4 spots.")
    }

    func testAccessibilityLabelKeepsTheUnpricedWording() throws {
        XCTAssertEqual(
            SlotFormatting.accessibilityLabel(
                for: try slot("warringah:2026-10-03:0616:1st-tee-social")),
            "Warringah Golf Club, 6:16 am, Saturday 3 October, 18 holes, par 70, "
            + "price at course, 2 of 4 spots.")
    }

    /// The registration warning is the one part of a row that changes whether
    /// a tap is worth making, so it is appended rather than dropped.
    func testAccessibilityLabelAppendsTheRegistrationWarning() throws {
        let spoken = SlotFormatting.accessibilityLabel(
            for: try slot("bayview:2026-10-04:0945:1st-tee-social-play"))
        XCTAssertTrue(
            spoken.hasSuffix("Bayview needs a free club account before you can book."),
            spoken)
        XCTAssertTrue(spoken.contains("9:45 am"), spoken)
        XCTAssertTrue(spoken.contains("Sunday 4 October"), spoken)
    }

    // MARK: - Helpers

    /// Rebuild a fixture slot with the two nullable display fields replaced.
    /// The contract's types are immutable, which is the right call — this is
    /// the cost of it. Both parameters are required rather than defaulted:
    /// `Int??` is exactly the shape that silently does the wrong thing when a
    /// caller passes a plain `nil`.
    /// The same, for the price pair. Both parameters are required for the same
    /// reason as above.
    private static func priced(_ slot: Slot, min: Double?, max: Double?) -> Slot {
        Slot(
            id: slot.id,
            courseSlug: slot.courseSlug,
            courseName: slot.courseName,
            region: slot.region,
            driveMinutesFromBondi: slot.driveMinutesFromBondi,
            par: slot.par,
            lengthMetres: slot.lengthMetres,
            requiresRegistration: slot.requiresRegistration,
            teeDate: slot.teeDate,
            teeTime: slot.teeTime,
            teeAt: slot.teeAt,
            spotsAvailable: slot.spotsAvailable,
            totalSpots: slot.totalSpots,
            holes: slot.holes,
            priceMin: min,
            priceMax: max,
            priceTiers: slot.priceTiers,
            bookingType: slot.bookingType,
            bookingURLString: slot.bookingURLString)
    }

    private static func copy(_ slot: Slot, par: Int?, driveMinutes: Int?) -> Slot {
        Slot(
            id: slot.id,
            courseSlug: slot.courseSlug,
            courseName: slot.courseName,
            region: slot.region,
            driveMinutesFromBondi: driveMinutes,
            par: par,
            lengthMetres: slot.lengthMetres,
            requiresRegistration: slot.requiresRegistration,
            teeDate: slot.teeDate,
            teeTime: slot.teeTime,
            teeAt: slot.teeAt,
            spotsAvailable: slot.spotsAvailable,
            totalSpots: slot.totalSpots,
            holes: slot.holes,
            priceMin: slot.priceMin,
            priceMax: slot.priceMax,
            priceTiers: slot.priceTiers,
            bookingType: slot.bookingType,
            bookingURLString: slot.bookingURLString)
    }
}
