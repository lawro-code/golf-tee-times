import SwiftUI
import XCTest
import TeesContract
@testable import TeesViews

/// The filter bar and the sheet behind it, asserted on the values they are
/// built from.
///
/// A chip is a button, and there is no ViewInspector in this project to reach
/// its closure — so the chip's title, its selected state and its spoken value
/// are pure functions of `SearchFilters` (`FilterField`), and what a control in
/// the sheet does to the filters is a named transformation (`FilterMutation`).
/// Both are asserted here; the views that call them are three lines each.
@MainActor
final class FilterBarTests: XCTestCase {

    private let today = "2026-10-03"
    private let tomorrow = "2026-10-04"
    private let laterDay = "2026-10-10"

    // MARK: - What a chip says when nothing is set

    /// An unset chip shows the filter's name. Holes is the deliberate
    /// exception: CONTRACT.md §2 makes 18 a real choice rather than an absence
    /// of one, so that chip always states a number and a first-run user can see
    /// that 18 is already picked for them.
    func testAnUnsetChipShowsItsNameExceptHoles() {
        let filters = SearchFilters.standard

        XCTAssertEqual(FilterField.day.chipTitle(filters: filters, today: today), "Day")
        XCTAssertEqual(FilterField.time.chipTitle(filters: filters, today: today), "Time")
        XCTAssertEqual(FilterField.players.chipTitle(filters: filters, today: today), "Players")
        XCTAssertEqual(FilterField.price.chipTitle(filters: filters, today: today), "Price")
        XCTAssertEqual(FilterField.drive.chipTitle(filters: filters, today: today), "Drive")
        XCTAssertEqual(FilterField.holes.chipTitle(filters: filters, today: today), "18 holes")
    }

    /// The bar's selected states and `SearchFilters.activeCount` have to agree.
    /// If they drift, the badge says "1 filter" while no chip looks set.
    func testNoChipLooksSelectedOnAFreshLaunch() {
        let filters = SearchFilters.standard
        XCTAssertEqual(filters.activeCount, 0)
        for field in FilterField.allCases {
            XCTAssertFalse(field.isSelected(in: filters), "\(field.name) should not read as set")
        }
    }

    // MARK: - What a chip says once it is set

    func testASingleDayChipShowsTheRelativeDayTitle() {
        var filters = SearchFilters.standard
        filters.days = [today]
        XCTAssertEqual(FilterField.day.chipTitle(filters: filters, today: today), "Today")

        filters.days = [tomorrow]
        XCTAssertEqual(FilterField.day.chipTitle(filters: filters, today: today), "Tomorrow")

        filters.days = [laterDay]
        XCTAssertEqual(FilterField.day.chipTitle(filters: filters, today: today), "Sat 10 Oct")
    }

    /// Picking three days is one active filter, not three, and the chip says so
    /// as a count rather than trying to list them.
    func testSeveralDaysCollapseToACount() {
        var filters = SearchFilters.standard
        filters.days = [today, tomorrow, laterDay]

        XCTAssertEqual(FilterField.day.chipTitle(filters: filters, today: today), "3 days")
        XCTAssertTrue(FilterField.day.isSelected(in: filters))
        XCTAssertEqual(filters.activeCount, 1)
    }

    func testTimeChipShowsOneBucketByNameAndSeveralAsACount() {
        var filters = SearchFilters.standard
        filters.timesOfDay = [.earlyMorning]
        XCTAssertEqual(FilterField.time.chipTitle(filters: filters, today: today), "Early")

        filters.timesOfDay = [.earlyMorning, .twilight]
        XCTAssertEqual(FilterField.time.chipTitle(filters: filters, today: today), "2 times")
    }

    func testPlayersPriceAndDriveChipsShowTheirValues() {
        var filters = SearchFilters.standard
        filters.players = 4
        filters.maxPrice = 60
        filters.maxDriveMinutes = 30

        XCTAssertEqual(FilterField.players.chipTitle(filters: filters, today: today), "4 players")
        XCTAssertEqual(FilterField.price.chipTitle(filters: filters, today: today), "Under $60")
        XCTAssertEqual(FilterField.drive.chipTitle(filters: filters, today: today), "Under 30 min")
    }

    /// 18 is the default and does not light up; 9 and Either do. Same rule as
    /// `activeCount`, asserted on both sides so they cannot drift apart.
    func testOnlyANonDefaultHoleChoiceReadsAsSelected() {
        var filters = SearchFilters.standard
        XCTAssertFalse(FilterField.holes.isSelected(in: filters))

        filters.holes = .nine
        XCTAssertTrue(FilterField.holes.isSelected(in: filters))
        XCTAssertEqual(FilterField.holes.chipTitle(filters: filters, today: today), "9 holes")
        XCTAssertEqual(filters.activeCount, 1)

        filters.holes = .any
        XCTAssertTrue(FilterField.holes.isSelected(in: filters))
        XCTAssertEqual(FilterField.holes.chipTitle(filters: filters, today: today), "Either")
    }

    // MARK: - What VoiceOver hears

    /// An unset filter says "any" rather than staying silent. Six chips that
    /// all read "button" is a row nobody can use without looking at it.
    func testAnUnsetChipStillSpeaksAValue() {
        let filters = SearchFilters.standard

        XCTAssertEqual(FilterField.day.spokenValue(filters: filters, today: today), "Any day")
        XCTAssertEqual(FilterField.time.spokenValue(filters: filters, today: today), "Any time")
        XCTAssertEqual(FilterField.players.spokenValue(filters: filters, today: today), "1 player")
        XCTAssertEqual(FilterField.holes.spokenValue(filters: filters, today: today), "18 holes")
        XCTAssertEqual(FilterField.price.spokenValue(filters: filters, today: today), "Any price")
        XCTAssertEqual(FilterField.drive.spokenValue(filters: filters, today: today), "Any drive")
    }

    /// Spoken out of context, a relative day is useless — "Today" read aloud
    /// three hours later means nothing. The spoken value names the day.
    func testASingleDaySpeaksTheLongDateNotTheRelativeOne() {
        var filters = SearchFilters.standard
        filters.days = [today]
        XCTAssertEqual(
            FilterField.day.spokenValue(filters: filters, today: today),
            "Saturday 3 October")
    }

    /// Set order is not stable, so the spoken list is put back into the
    /// declared order of the buckets rather than whatever the `Set` hands over.
    func testSeveralTimesSpeakInTheirDeclaredOrder() {
        var filters = SearchFilters.standard
        filters.timesOfDay = [.twilight, .earlyMorning, .midday]
        XCTAssertEqual(
            FilterField.time.spokenValue(filters: filters, today: today),
            "Early, Midday, Twilight")
    }

    // MARK: - What the controls in the sheet do

    func testTogglingADayAddsThenRemovesIt() {
        var filters = SearchFilters.standard

        filters = FilterMutation.toggling(day: today, in: filters)
        XCTAssertEqual(filters.days, [today])

        filters = FilterMutation.toggling(day: tomorrow, in: filters)
        XCTAssertEqual(filters.days, [today, tomorrow])

        filters = FilterMutation.toggling(day: today, in: filters)
        XCTAssertEqual(filters.days, [tomorrow])
    }

    func testTogglingATimeOfDayAddsThenRemovesIt() {
        var filters = SearchFilters.standard

        filters = FilterMutation.toggling(time: .morning, in: filters)
        XCTAssertEqual(filters.timesOfDay, [.morning])

        filters = FilterMutation.toggling(time: .morning, in: filters)
        XCTAssertTrue(filters.timesOfDay.isEmpty)
    }

    /// A tee time never seats more than four, and the control only offers 1–4 —
    /// but the clamp is asserted anyway, because a watch decoded from a future
    /// build could carry anything.
    func testPlayersIsClampedToOneThroughFour() {
        XCTAssertEqual(FilterMutation.playerOptions, [1, 2, 3, 4])
        XCTAssertEqual(FilterMutation.setting(players: 3, in: .standard).players, 3)
        XCTAssertEqual(FilterMutation.setting(players: 0, in: .standard).players, 1)
        XCTAssertEqual(FilterMutation.setting(players: 9, in: .standard).players, 4)
    }

    func testSettingHolesReplacesTheChoice() {
        let filters = FilterMutation.setting(holes: .nine, in: .standard)
        XCTAssertEqual(filters.holes, .nine)
        XCTAssertEqual(FilterMutation.setting(holes: .eighteen, in: filters).holes, .eighteen)
    }

    /// The top of the slider is "any price", not "the most expensive round in
    /// today's data". Without this, tomorrow's dearer green fee is silently
    /// unreachable by a filter a golfer believes is wide open.
    func testTheTopOfThePriceSliderMeansAnyPriceNotACeiling() {
        let capped = FilterMutation.setting(maxPrice: 60, ceiling: 110, in: .standard)
        XCTAssertEqual(capped.maxPrice, 60)

        let wideOpen = FilterMutation.setting(maxPrice: 110, ceiling: 110, in: capped)
        XCTAssertNil(wideOpen.maxPrice)
        XCTAssertEqual(wideOpen.activeCount, 0)
    }

    func testTheTopOfTheDriveSliderMeansAnyDrive() {
        let capped = FilterMutation.setting(maxDriveMinutes: 30, ceiling: 45, in: .standard)
        XCTAssertEqual(capped.maxDriveMinutes, 30)

        let wideOpen = FilterMutation.setting(maxDriveMinutes: 45, ceiling: 45, in: capped)
        XCTAssertNil(wideOpen.maxDriveMinutes)
    }

    func testSliderLabelsReadAsSentences() {
        XCTAssertEqual(FilterMutation.priceLabel(nil), "Any price")
        XCTAssertEqual(FilterMutation.priceLabel(60), "Under $60")
        XCTAssertEqual(FilterMutation.driveLabel(nil), "Any drive")
        XCTAssertEqual(FilterMutation.driveLabel(30), "Under 30 min from Bondi")
    }

    // MARK: - The slider's ends

    /// Taken from the data rather than hardcoded. `minimal.json` runs $25–$70
    /// and the frozen fifteen are 10–45 minutes from Bondi.
    func testSliderBoundsComeFromThePayload() throws {
        let payload = try ContractLoader.fixture("minimal")
        let bounds = FilterBounds.make(slots: payload.slots, courses: payload.courses)

        XCTAssertEqual(bounds.minPrice, 25)
        XCTAssertEqual(bounds.maxPrice, 70)
        XCTAssertEqual(bounds.minDriveMinutes, 10)
        XCTAssertEqual(bounds.maxDriveMinutes, 45)
    }

    /// A payload where every club declined to publish a fee still has to give
    /// the slider two usable ends.
    func testSliderBoundsFallBackWhenNothingIsPriced() throws {
        let payload = try ContractLoader.fixture("minimal")
        let unpriced = payload.slots.filter(\.priceIsUnknown)
        XCTAssertFalse(unpriced.isEmpty, "the fixture changed shape")

        let bounds = FilterBounds.make(slots: unpriced, courses: payload.courses)
        XCTAssertEqual(bounds, .fallback)
    }

    /// A slider whose ends are equal traps its thumb.
    func testSliderEndsAreNeverEqual() {
        let bounds = FilterBounds(minPrice: 40, maxPrice: 40, minDriveMinutes: 20, maxDriveMinutes: 20)
        XCTAssertGreaterThan(bounds.maxPrice, bounds.minPrice)
        XCTAssertGreaterThan(bounds.maxDriveMinutes, bounds.minDriveMinutes)
    }

    // MARK: - The sheet's footer

    /// The live count. It is the only summary the sheet gives of what the
    /// controls above just did, so its zero and its singular both matter.
    func testFooterCountReadsCorrectlyAtZeroOneAndMany() {
        XCTAssertEqual(FilterSheet.footerTitle(resultCount: 0), "No tee times match")
        XCTAssertEqual(FilterSheet.footerTitle(resultCount: 1), "Show 1 tee time")
        XCTAssertEqual(FilterSheet.footerTitle(resultCount: 143), "Show 143 tee times")
    }

    // MARK: - The day sheet with zero slots

    /// Every course can scrape cleanly and still have nothing open on any
    /// day — `payload.slots` empty, so `availableDays` is too. The sheet has
    /// to say that, rather than showing the ordinary "no day chosen" hint
    /// above a silently empty list, which reads as a broken screen instead
    /// of a deliberate "nothing to filter by yet".
    func testDayHintExplainsAnEmptyListInsteadOfGoingSilent() {
        XCTAssertEqual(
            FilterSheet.dayHint(availableDays: []),
            "No tee times are open on any day right now, so there's nothing to filter by yet.")
        XCTAssertEqual(
            FilterSheet.dayHint(availableDays: ["2026-10-03"]),
            "No day chosen means every day we have.")
    }

    // MARK: - Clearing

    /// The Clear control exists only while there is something to clear, and
    /// resetting really resets — including the remembered hole count, or a
    /// golfer taps Clear and still sees a filtered list.
    func testResetTakesEveryChipBackToItsDefault() {
        let store = SearchStore(preferences: InMemoryViewsStore(), fixture: "minimal")
        store.load()

        var filters = SearchFilters.standard
        filters.days = [today]
        filters.players = 4
        filters.holes = .nine
        filters.maxPrice = 40
        store.filters = filters
        XCTAssertEqual(store.filters.activeCount, 4)

        store.resetFilters()

        XCTAssertEqual(store.filters.activeCount, 0)
        XCTAssertEqual(store.filters, .standard)
        for field in FilterField.allCases {
            XCTAssertFalse(field.isSelected(in: store.filters), "\(field.name) survived a reset")
        }
    }

    // MARK: - Construction

    func testBarAndSheetConstructWithTheirPublicInits() {
        let store = SearchStore.previewStore()

        let bar: any View = FilterBar(store: store)
        XCTAssertTrue(bar is FilterBar)

        for field in FilterField.allCases {
            let sheet: any View = FilterSheet(store: store, field: field)
            XCTAssertTrue(sheet is FilterSheet, "\(field.name) sheet failed to build")
        }
    }
}

// MARK: - Tester's pass, ticket C2

/// The sheet's controls, tested for what they leave behind as much as for what
/// they change.
///
/// Every test above starts from `SearchFilters.standard`, which means a
/// `FilterMutation` that rebuilt the struct from scratch instead of editing a
/// copy would pass all of them — and would silently throw away the 3 players
/// and 9 holes a golfer had already chosen the moment they opened the Day
/// sheet. These start from a search with every field set.
@MainActor
final class FilterSheetControlTests: XCTestCase {

    /// Every field deliberately away from its default.
    private var fullySet: SearchFilters {
        var filters = SearchFilters.standard
        filters.days = ["2026-10-03", "2026-10-04"]
        filters.timesOfDay = [.morning, .twilight]
        filters.players = 3
        filters.holes = .nine
        filters.maxPrice = 40
        filters.maxDriveMinutes = 20
        filters.courseSlugs = ["warringah"]
        return filters
    }

    /// Asserts that a mutation touched its own field and nothing else.
    private func assertOnlyOneFieldMoved(
        from before: SearchFilters,
        to after: SearchFilters,
        changed: PartialKeyPath<SearchFilters>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if changed != \SearchFilters.days {
            XCTAssertEqual(after.days, before.days, "days moved", file: file, line: line)
        }
        if changed != \SearchFilters.timesOfDay {
            XCTAssertEqual(
                after.timesOfDay, before.timesOfDay, "times moved", file: file, line: line)
        }
        if changed != \SearchFilters.players {
            XCTAssertEqual(after.players, before.players, "players moved", file: file, line: line)
        }
        if changed != \SearchFilters.holes {
            XCTAssertEqual(after.holes, before.holes, "holes moved", file: file, line: line)
        }
        if changed != \SearchFilters.maxPrice {
            XCTAssertEqual(after.maxPrice, before.maxPrice, "price moved", file: file, line: line)
        }
        if changed != \SearchFilters.maxDriveMinutes {
            XCTAssertEqual(
                after.maxDriveMinutes, before.maxDriveMinutes,
                "drive moved", file: file, line: line)
        }
        // No chip owns the course list, so nothing in this sheet may touch it.
        XCTAssertEqual(
            after.courseSlugs, before.courseSlugs, "courses moved", file: file, line: line)
    }

    func testTickingADayKeepsTheRestOfTheSearch() {
        let before = fullySet
        let after = FilterMutation.toggling(day: "2026-10-10", in: before)

        XCTAssertEqual(after.days, ["2026-10-03", "2026-10-04", "2026-10-10"])
        assertOnlyOneFieldMoved(from: before, to: after, changed: \SearchFilters.days)
    }

    func testTickingATimeOfDayKeepsTheRestOfTheSearch() {
        let before = fullySet
        let after = FilterMutation.toggling(time: .morning, in: before)

        XCTAssertEqual(after.timesOfDay, [.twilight])
        assertOnlyOneFieldMoved(from: before, to: after, changed: \SearchFilters.timesOfDay)
    }

    func testChoosingPlayersKeepsTheRestOfTheSearch() {
        let before = fullySet
        let after = FilterMutation.setting(players: 4, in: before)

        XCTAssertEqual(after.players, 4)
        assertOnlyOneFieldMoved(from: before, to: after, changed: \SearchFilters.players)
    }

    func testChoosingHolesKeepsTheRestOfTheSearch() {
        let before = fullySet
        let after = FilterMutation.setting(holes: .any, in: before)

        XCTAssertEqual(after.holes, .any)
        assertOnlyOneFieldMoved(from: before, to: after, changed: \SearchFilters.holes)
    }

    func testMovingThePriceSliderKeepsTheRestOfTheSearch() {
        let before = fullySet
        let after = FilterMutation.setting(maxPrice: 65, ceiling: 110, in: before)

        XCTAssertEqual(after.maxPrice, 65)
        assertOnlyOneFieldMoved(from: before, to: after, changed: \SearchFilters.maxPrice)
    }

    func testMovingTheDriveSliderKeepsTheRestOfTheSearch() {
        let before = fullySet
        let after = FilterMutation.setting(maxDriveMinutes: 35, ceiling: 45, in: before)

        XCTAssertEqual(after.maxDriveMinutes, 35)
        assertOnlyOneFieldMoved(from: before, to: after, changed: \SearchFilters.maxDriveMinutes)
    }

    /// The top of a slider means "any", and so does anything past it. The
    /// bounds are measured from the payload on screen, so a ceiling can outlive
    /// the data it came from — a cheaper reload, or a value restored from a
    /// richer day. Landing above the top has to mean the same thing as landing
    /// on it, or the chip reads "Under $200" over a filter that filters nothing.
    func testAValuePastTheTopOfASliderAlsoMeansAny() {
        XCTAssertNil(
            FilterMutation.setting(maxPrice: 200, ceiling: 110, in: .standard).maxPrice)
        XCTAssertNil(
            FilterMutation.setting(maxDriveMinutes: 90, ceiling: 45, in: .standard)
                .maxDriveMinutes)
    }

    // MARK: - The ends of the sliders

    /// `minimal.json` runs $25-$70 and the frozen fifteen are 10-45 minutes
    /// out: every one of those is already a multiple of the slider's step, so
    /// the fixture on its own cannot tell a rounded bound from a raw one. Real
    /// green fees are not that tidy, and a bound that lands inside the data
    /// puts a round the club published out of the slider's reach.
    func testSliderBoundsRoundOutwardToTheStep() {
        let slots = [pricedSlot(id: "a", price: 27.50), pricedSlot(id: "b", price: 68.10)]
        let courses = [course(slug: "a", drive: 12), course(slug: "b", drive: 43)]

        let bounds = FilterBounds.make(slots: slots, courses: courses)

        XCTAssertEqual(bounds.minPrice, 25)
        XCTAssertEqual(bounds.maxPrice, 70)
        XCTAssertEqual(bounds.minDriveMinutes, 10)
        XCTAssertEqual(bounds.maxDriveMinutes, 45)

        // The point of the rounding, stated as the property it protects.
        XCTAssertLessThanOrEqual(bounds.minPrice, 27.50)
        XCTAssertGreaterThanOrEqual(bounds.maxPrice, 68.10)
        XCTAssertLessThanOrEqual(bounds.minDriveMinutes, 12)
        XCTAssertGreaterThanOrEqual(bounds.maxDriveMinutes, 43)
    }

    /// A slider needs two ends and there are two sliders. Prices with no drive
    /// times gives only half of that, and half a `FilterBounds` is a drive
    /// slider whose bottom is zero minutes from Bondi.
    func testSliderBoundsFallBackWhenNoClubPublishesADriveTime() {
        let slots = [pricedSlot(id: "a", price: 40)]

        XCTAssertEqual(
            FilterBounds.make(slots: slots, courses: [course(slug: "a", drive: nil)]),
            .fallback)
        XCTAssertEqual(FilterBounds.make(slots: slots, courses: []), .fallback)
    }

    /// One club publishing one fee is an ordinary Tuesday. Floor and ceiling
    /// land on the same number, and a slider whose ends are equal traps its
    /// thumb where a golfer cannot move it.
    func testASinglePublishedFeeStillGivesASliderWithTwoEnds() {
        let bounds = FilterBounds.make(
            slots: [pricedSlot(id: "a", price: 30), pricedSlot(id: "b", price: 30)],
            courses: [course(slug: "a", drive: 20), course(slug: "b", drive: 20)])

        XCTAssertEqual(bounds.minPrice, 30)
        XCTAssertGreaterThanOrEqual(bounds.maxPrice, bounds.minPrice + FilterBounds.priceStep)
        XCTAssertEqual(bounds.minDriveMinutes, 20)
        XCTAssertGreaterThanOrEqual(
            bounds.maxDriveMinutes, bounds.minDriveMinutes + FilterBounds.driveStep)
    }

    // MARK: - The bar itself

    /// The bar renders `FilterField.allCases` straight through, so the enum's
    /// order is the order of the chips across the top of the screen. Day comes
    /// first because it is the question a golfer answers first.
    func testTheChipsAreInTheOrderTheBarRendersThem() {
        XCTAssertEqual(FilterField.allCases, [.day, .time, .players, .holes, .price, .drive])
    }

    // A chip states its value in text and its state in colour — `FilterBar`
    // now builds every chip from `TeesFilterChip`, whose own test suite
    // (`TeesFilterChipTests`) measures the selected/unselected contrast in
    // both colour schemes directly, so that assertion is not repeated here.

    // MARK: - Fabricated data

    // Built by hand rather than taken from a fixture: the point of these is
    // prices and drive times the fixtures deliberately do not contain.

    private func pricedSlot(id: String, price: Double) -> Slot {
        Slot(
            id: id,
            courseSlug: id,
            courseName: "\(id) Golf Club",
            region: "Test",
            driveMinutesFromBondi: nil,
            par: 72,
            requiresRegistration: false,
            teeDate: "2026-10-03",
            teeTime: "08:00:00",
            teeAt: ContractDate.date(from: "2026-10-03T08:00:00+10:00")!,
            spotsAvailable: 4,
            totalSpots: 4,
            holes: 18,
            priceMin: price,
            priceMax: price,
            priceTiers: [PriceTier(label: "Social", amount: price)],
            bookingType: "1st Tee",
            bookingURLString: "https://example.com/book")
    }

    private func course(slug: String, drive: Int?) -> Course {
        Course(
            slug: slug,
            name: "\(slug) Golf Club",
            region: "Test",
            host: "example.com",
            feeGroupID: "1",
            holes: 18,
            par: 72,
            driveMinutesFromBondi: drive,
            requiresRegistration: false,
            address: nil,
            notes: "",
            sortOrder: 0)
    }
}
