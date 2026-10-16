import XCTest
import TeesContract
@testable import TeesViews

/// Everything here runs against `minimal.json`, which holds exactly one of
/// every awkward case the live scrape turned up. That is the point of the
/// fixture: these are not invented edge cases, they are Warringah's two-tee
/// start, Bankstown's 9-hole bookings at an 18-hole club, and Warringah's
/// missing prices.
final class SlotQueryTests: XCTestCase {

    private var slots: [Slot] = []

    /// The fixture's own dates. `minimal.json` is deterministic, so these are
    /// constants rather than anything derived from a clock.
    private let day1 = "2099-10-03"
    private let day2 = "2099-10-04"
    private let day3 = "2099-10-10"

    override func setUpWithError() throws {
        slots = try ContractLoader.fixture("minimal").slots
        XCTAssertEqual(slots.count, 9, "the fixture changed shape; these tests assume 9 slots")
    }

    private func ids(_ results: [SlotResult]) -> [String] { results.map(\.id) }

    /// `minimal.json`'s own slots (unlike the hand-built `row`/`slot` helpers
    /// below) carry real `tee_at` timestamps lifted from the fixture file —
    /// "2099-10-03" and friends — with no far-future escape hatch. Every call
    /// below that filters `slots` through `SlotQuery.apply` without pinning
    /// `now` was comparing the fixture against the real wall clock, which is
    /// exactly the bug this file's own comment on `row(...)` already names:
    /// "looked comfortably future when this was written." It did, then
    /// stopped. This anchors `now` before the fixture's earliest tee-off
    /// (`2099-10-03T06:16:00+10:00`) so these tests stay true regardless of
    /// which day they run on.
    private static let fixtureNow = Date(timeIntervalSince1970: 4_094_496_000)

    private func apply(_ filters: SearchFilters, to slots: [Slot]) -> [SlotResult] {
        SlotQuery.apply(filters, to: slots, now: Self.fixtureNow)
    }

    // MARK: - Holes

    /// CONTRACT.md §2. Bankstown is an 18-hole club that also sells 9-hole tee
    /// times, and the hole count that matters is the booking's.
    func testNineHoleBookingAtAnEighteenHoleClubIsExcludedByEighteen() {
        let eighteen = apply(SearchFilters(holes: .eighteen), to: slots)
        XCTAssertFalse(
            ids(eighteen).contains("bankstown:2099-10-03:1120:social-play-9-holes-only"),
            "a 9-hole booking survived an 18-hole filter")
        XCTAssertTrue(
            ids(eighteen).contains("bankstown:2099-10-10:0800:social-play"),
            "the same club's 18-hole booking must still be there")
        XCTAssertEqual(eighteen.count, 5)
    }

    func testNineHoleBookingAtAnEighteenHoleClubIsIncludedByNine() {
        let nine = apply(SearchFilters(holes: .nine), to: slots)
        XCTAssertTrue(
            ids(nine).contains("bankstown:2099-10-03:1120:social-play-9-holes-only"))
        XCTAssertTrue(
            ids(nine).contains("brighton-lakes:2099-10-10:1307:1st-tee-social"))
        XCTAssertFalse(ids(nine).contains("bankstown:2099-10-10:0800:social-play"))
        XCTAssertEqual(nine.count, 4)
    }

    func testAnyHolesKeepsEverything() {
        XCTAssertEqual(apply(SearchFilters(holes: .any), to: slots).count, 9)
    }

    // MARK: - The two-tee start

    /// CONTRACT.md §1. Warringah sends a 1st Tee group and a 10th Tee group out
    /// at 06:16 — two bookings, one minute. Keying on time alone collapsed 141
    /// of its 289 tee times once already.
    func testTwoTeeStartYieldsTwoDistinctRowsInAStableOrder() {
        let results = apply(
            SearchFilters(days: [day1], holes: .any, courseSlugs: ["warringah"]),
            to: slots)

        XCTAssertEqual(results.count, 2, "the two-tee start collapsed into one row")
        XCTAssertEqual(ids(results), [
            "warringah:2099-10-03:0616:10th-tee-social",
            "warringah:2099-10-03:0616:1st-tee-social"
        ], "same minute, so the order comes from booking_type then id")
        XCTAssertEqual(Set(ids(results)).count, 2)
    }

    /// The comparator is total, so shuffling the input cannot change the
    /// output. That is what makes the list stable across scrapes rather than
    /// stable-by-luck.
    func testOrderIsStableAcrossShuffledInput() {
        let expected = ids(apply(SearchFilters(holes: .any), to: slots))
        for _ in 0..<20 {
            let shuffled = apply(SearchFilters(holes: .any), to: slots.shuffled())
            XCTAssertEqual(ids(shuffled), expected)
        }
    }

    func testResultsAscendByTeeTime() {
        let results = apply(SearchFilters(holes: .any), to: slots)
        for (a, b) in zip(results, results.dropFirst()) {
            XCTAssertLessThanOrEqual(a.slot.teeAt, b.slot.teeAt)
        }
    }

    // MARK: - Missing data never hides inventory

    /// CONTRACT.md §3. Warringah's 06:16 pair publishes no fee. A $40 ceiling
    /// is well under every priced slot in the fixture, and the unpriced ones
    /// must survive it anyway.
    func testAMaxPriceFilterKeepsUnpricedSlots() {
        let results = apply(
            SearchFilters(holes: .any, maxPrice: 40), to: slots)
        let kept = ids(results)
        XCTAssertTrue(kept.contains("warringah:2099-10-03:0616:1st-tee-social"))
        XCTAssertTrue(kept.contains("warringah:2099-10-03:0616:10th-tee-social"))
        XCTAssertFalse(kept.contains("the-coast:2099-10-03:0800:1st-tee"),
                       "$55 is over a $40 ceiling and should be gone")
    }

    /// And they sink, within their own day, below everything we do have a price
    /// for — still ascending among themselves.
    func testUnpricedSlotsSinkBelowPricedOnesWithinTheirDay() {
        let filters = SearchFilters(days: [day1], holes: .any, maxPrice: 60)
        let sections = SlotQuery.sections(
            apply(filters, to: slots),
            today: day1,
            priceFilterActive: filters.maxPrice != nil)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(ids(sections[0].results), [
            // Priced, ascending by tee time.
            "woollahra:2099-10-03:0712:public-play",
            "the-coast:2099-10-03:0800:1st-tee",
            "bankstown:2099-10-03:1120:social-play-9-holes-only",
            // Then the unpriced pair — earlier in the day, last in the list.
            "warringah:2099-10-03:0616:10th-tee-social",
            "warringah:2099-10-03:0616:1st-tee-social"
        ])
    }

    /// Without a price filter the unpriced 06:16 pair sits where the clock puts
    /// it: first. Sinking is a consequence of asking about price, not a
    /// permanent demotion.
    func testUnpricedSlotsKeepTheirPlaceWhenNoPriceFilterIsActive() {
        let sections = SlotQuery.sections(
            apply(SearchFilters(days: [day1], holes: .any), to: slots),
            today: day1,
            priceFilterActive: false)

        XCTAssertEqual(ids(sections[0].results).prefix(2).map { $0 }, [
            "warringah:2099-10-03:0616:10th-tee-social",
            "warringah:2099-10-03:0616:1st-tee-social"
        ])
    }

    func testMaxPriceComparesAgainstPriceMin() {
        // The Coast publishes three tiers, $55 to $110. "Under $60" should
        // keep it: the cheapest way to play it is $55.
        let kept = ids(apply(SearchFilters(holes: .any, maxPrice: 60), to: slots))
        XCTAssertTrue(kept.contains("the-coast:2099-10-03:0800:1st-tee"))

        let gone = ids(apply(SearchFilters(holes: .any, maxPrice: 50), to: slots))
        XCTAssertFalse(gone.contains("the-coast:2099-10-03:0800:1st-tee"))
    }

    func testMaxPriceIsInclusive() {
        // Woollahra's 07:12 is exactly $45.
        let kept = ids(apply(SearchFilters(holes: .any, maxPrice: 45), to: slots))
        XCTAssertTrue(kept.contains("woollahra:2099-10-03:0712:public-play"))
    }

    /// The fixture's fifteen courses all have a drive time, so this one builds
    /// its own slot. A null drive is the same class of gap as a null price and
    /// gets the same treatment.
    func testANullDriveTimeNeverFailsADriveFilter() {
        let unknown = Self.slot(id: "unknown:2099-10-03:0700:default", driveMinutes: nil)
        let far = Self.slot(id: "far:2099-10-03:0700:default", driveMinutes: 90)

        let kept = ids(apply(
            SearchFilters(holes: .any, maxDriveMinutes: 20), to: [unknown, far]))
        XCTAssertEqual(kept, ["unknown:2099-10-03:0700:default"])
    }

    func testMaxDriveMinutesIsInclusive() {
        let exact = Self.slot(id: "exact:2099-10-03:0700:default", driveMinutes: 20)
        XCTAssertEqual(
            apply(SearchFilters(holes: .any, maxDriveMinutes: 20), to: [exact]).count, 1)
    }

    // MARK: - The other facets

    func testPlayersMatchesWhenEnoughSpotsAreFree() {
        let four = apply(SearchFilters(players: 4, holes: .any), to: slots)
        XCTAssertEqual(four.count, 4)
        for result in four {
            XCTAssertGreaterThanOrEqual(result.slot.spotsAvailable, 4)
        }

        let one = apply(SearchFilters(players: 1, holes: .any), to: slots)
        XCTAssertEqual(one.count, 9, "one player fits every slot in the fixture")
    }

    func testDaysFilter() {
        XCTAssertEqual(apply(SearchFilters(days: [day1], holes: .any), to: slots).count, 5)
        XCTAssertEqual(apply(SearchFilters(days: [day2], holes: .any), to: slots).count, 2)
        XCTAssertEqual(apply(SearchFilters(days: [day3], holes: .any), to: slots).count, 2)
        XCTAssertEqual(
            apply(SearchFilters(days: [day1, day3], holes: .any), to: slots).count, 7)
        XCTAssertEqual(
            apply(SearchFilters(days: ["2026-01-01"], holes: .any), to: slots).count, 0)
    }

    func testTimeOfDayFilterUsesTheSecondsFormTeeTime() {
        let early = apply(SearchFilters(timesOfDay: [.earlyMorning], holes: .any), to: slots)
        XCTAssertEqual(ids(early), [
            "warringah:2099-10-03:0616:10th-tee-social",
            "warringah:2099-10-03:0616:1st-tee-social"
        ])

        // 16:30 is afternoon, not twilight — the boundary is 17:00 and the
        // fixture sits deliberately close to it.
        let afternoon = apply(SearchFilters(timesOfDay: [.afternoon], holes: .any), to: slots)
        XCTAssertEqual(ids(afternoon), ["woollahra:2099-10-04:1630:public-bookings"])
        XCTAssertTrue(
            apply(SearchFilters(timesOfDay: [.twilight], holes: .any), to: slots).isEmpty)
    }

    func testCourseSlugsFilter() {
        let woollahra = apply(
            SearchFilters(holes: .any, courseSlugs: ["woollahra"]), to: slots)
        XCTAssertEqual(woollahra.count, 2)
        XCTAssertEqual(
            apply(SearchFilters(holes: .any, courseSlugs: []), to: slots).count, 9,
            "empty means all fifteen, not none")
    }

    func testFacetsCompose() {
        let results = apply(
            SearchFilters(
                days: [day1],
                timesOfDay: [.morning, .midday],
                players: 3,
                holes: .any,
                maxPrice: 60,
                maxDriveMinutes: 50,
                courseSlugs: ["bankstown", "the-coast", "woollahra"]),
            to: slots)
        XCTAssertEqual(ids(results), [
            "the-coast:2099-10-03:0800:1st-tee",
            "bankstown:2099-10-03:1120:social-play-9-holes-only"
        ], "woollahra's 07:12 has only one spot free and drops out on players")
    }

    // MARK: - Rows that must not survive, and rows that must

    /// A slot the club has already filled is not inventory. `spots_available`
    /// reaches zero the moment the last seat goes, and the default filter is
    /// one player — so a comparator written `<=` instead of `<` would put a
    /// fully booked tee time at the top of the list with a tap that goes
    /// nowhere.
    func testAFullyBookedSlotNeverShowsEvenForASinglePlayer() {
        let booked = Self.row(id: "booked:2099-10-03:0700:default", spotsAvailable: 0)
        let last = Self.row(id: "last:2099-10-03:0700:default", spotsAvailable: 1)

        XCTAssertEqual(
            ids(apply(SearchFilters(players: 1), to: [booked, last])),
            ["last:2099-10-03:0700:default"])
        XCTAssertTrue(apply(SearchFilters(players: 1), to: [booked]).isEmpty)
    }

    /// A cached payload is only ever all-future at the moment it was written
    /// (`open_slots` filters on `tee_at > now()` server-side); left on disk
    /// through an offline stretch, some of it teed off without anything on the
    /// client re-checking. A slot like that must not survive `apply` no matter
    /// what the facets say — not "hide it if the caller happens to filter by
    /// time", but gone, the same way a fully booked slot is gone.
    func testASlotThatHasAlreadyTeedOffIsExcludedEvenThoughItMatchesEveryFilter() {
        let cutoff = Date(timeIntervalSince1970: 1_790_000_000)
        let justPast = Self.row(
            id: "past:2099-10-03:0600:default", teeAt: cutoff.addingTimeInterval(-60))
        let stillToCome = Self.row(
            id: "future:2099-10-03:0700:default", teeAt: cutoff.addingTimeInterval(60))
        let exactlyNow = Self.row(id: "now:2099-10-03:0630:default", teeAt: cutoff)

        let kept = ids(SlotQuery.apply(
            SearchFilters(holes: .any), to: [justPast, stillToCome, exactlyNow], now: cutoff))

        XCTAssertEqual(
            kept, ["future:2099-10-03:0700:default"],
            "a slot whose tee time is at or before now rendered as a normal, bookable row")
    }

    /// Picking two buckets means "either", not "both" — an intersection is
    /// always empty, because no tee time is in two buckets at once. That is the
    /// kind of bug that shows up as "the filter returns nothing" rather than as
    /// a crash.
    func testSeveralTimeBucketsAreAUnionNotAnIntersection() {
        let results = apply(
            SearchFilters(timesOfDay: [.earlyMorning, .afternoon], holes: .any), to: slots)
        XCTAssertEqual(ids(results), [
            "warringah:2099-10-03:0616:10th-tee-social",
            "warringah:2099-10-03:0616:1st-tee-social",
            "woollahra:2099-10-04:1630:public-bookings"
        ])
    }

    /// A `tee_time` that will not parse is a corrupt row, not a club declining
    /// to publish something — so it is **not** covered by the §3 rule. It stays
    /// in an unfiltered list, because it is still a bookable round, and it
    /// drops out of a time filter, because we cannot honestly claim it is a
    /// morning. Both halves matter: silently keeping it in every bucket would
    /// show a golfer who asked for twilight a round at an unknown hour.
    func testARowWithAnUnreadableTeeTimeIsKeptUntilATimeFilterAsksAboutIt() {
        let corrupt = Self.row(id: "corrupt:2099-10-03:0700:default", teeTime: "tee off at dawn")

        XCTAssertEqual(
            ids(apply(SearchFilters(), to: [corrupt])),
            ["corrupt:2099-10-03:0700:default"],
            "an unfiltered list must not silently lose a row it cannot read")

        for bucket in SearchFilters.TimeOfDay.allCases {
            XCTAssertTrue(
                apply(SearchFilters(timesOfDay: [bucket]), to: [corrupt]).isEmpty,
                "\(bucket) claimed a tee time it cannot parse")
        }
    }

    /// CONTRACT.md §3 at its extreme. A ceiling no published fee can meet
    /// leaves exactly the rows whose price we do not know — 17% of the real
    /// inventory — rather than an empty screen.
    func testAPriceCeilingNothingCanMeetStillShowsTheUnpricedRows() {
        let results = apply(SearchFilters(holes: .any, maxPrice: 0), to: slots)
        XCTAssertEqual(ids(results), [
            "warringah:2099-10-03:0616:10th-tee-social",
            "warringah:2099-10-03:0616:1st-tee-social"
        ])
    }

    // MARK: - Sections

    func testSectionsAscendByDateAndCarryTheirTitle() {
        let sections = SlotQuery.sections(
            apply(SearchFilters(holes: .any), to: slots),
            today: day1,
            priceFilterActive: false)

        XCTAssertEqual(sections.map(\.date), [day1, day2, day3])
        XCTAssertEqual(sections.map(\.id), [day1, day2, day3])
        XCTAssertEqual(sections.map(\.title), ["Today", "Tomorrow", "Sat 10 Oct"])
        XCTAssertEqual(sections.map(\.results.count), [5, 2, 2])
    }

    func testSectionsSortTheirOwnResultsEvenIfHandedThemBackwards() {
        let backwards = apply(SearchFilters(days: [day1], holes: .any), to: slots).reversed()
        let sections = SlotQuery.sections(Array(backwards), today: day1, priceFilterActive: false)
        XCTAssertEqual(ids(sections[0].results), [
            "warringah:2099-10-03:0616:10th-tee-social",
            "warringah:2099-10-03:0616:1st-tee-social",
            "woollahra:2099-10-03:0712:public-play",
            "the-coast:2099-10-03:0800:1st-tee",
            "bankstown:2099-10-03:1120:social-play-9-holes-only"
        ])
    }

    func testNoResultsMeansNoSections() {
        XCTAssertTrue(SlotQuery.sections([], today: day1, priceFilterActive: false).isEmpty)
    }

    // MARK: - SlotResult

    func testResultIdIsTheSlotIdAndPriceFlagFollowsPriceMin() throws {
        let unpriced = try XCTUnwrap(slots.first { $0.priceMin == nil })
        let priced = try XCTUnwrap(slots.first { $0.priceMin != nil })
        XCTAssertEqual(SlotResult(slot: unpriced).id, unpriced.id)
        XCTAssertTrue(SlotResult(slot: unpriced).priceIsUnknown)
        XCTAssertFalse(SlotResult(slot: priced).priceIsUnknown)
    }

    // MARK: - Helpers

    /// A hand-built slot for the cases the fixture deliberately does not carry:
    /// a filled tee time and a corrupt `tee_time`. `minimal.json` is a
    /// well-formed scrape, so the only way to test a malformed row is to build
    /// one.
    private static func row(
        id: String,
        teeTime: String = "07:00:00",
        spotsAvailable: Int = 4,
        // `apply(_:to:now:)` defaults `now` to the real wall clock, and a test
        // that does not pass `now:` explicitly (most of the ones below) is
        // comparing this against whatever day it actually runs on. `2026
        // -10-03` looked comfortably future when this was written; a fixed
        // epoch decades out is what actually stays future.
        teeAt: Date = Date(timeIntervalSince1970: 9_000_000_000)
    ) -> Slot {
        Slot(
            id: id,
            courseSlug: String(id.split(separator: ":")[0]),
            courseName: "Test Golf Club",
            region: "Test",
            driveMinutesFromBondi: 20,
            par: 72,
            requiresRegistration: false,
            teeDate: "2099-10-03",
            teeTime: teeTime,
            teeAt: teeAt,
            spotsAvailable: spotsAvailable,
            totalSpots: 4,
            holes: 18,
            priceMin: 50,
            priceMax: 50,
            priceTiers: [],
            bookingType: "Default",
            bookingURLString: "https://example.com")
    }

    /// A hand-built slot for the two cases the fixture cannot express. `teeAt`
    /// is a bare epoch offset: the client never computes an instant from a
    /// wall-clock date, so there is nothing to parse here.
    private static func slot(id: String, driveMinutes: Int?) -> Slot {
        Slot(
            id: id,
            courseSlug: String(id.split(separator: ":")[0]),
            courseName: "Test Golf Club",
            region: "Test",
            driveMinutesFromBondi: driveMinutes,
            par: 72,
            requiresRegistration: false,
            teeDate: "2099-10-03",
            teeTime: "07:00:00",
            // Same reasoning as `row(id:teeTime:spotsAvailable:teeAt:)`'s own
            // default: this has to outlive real wall-clock time, not just
            // look future when written.
            teeAt: Date(timeIntervalSince1970: 9_000_000_000),
            spotsAvailable: 4,
            totalSpots: 4,
            holes: 18,
            priceMin: 50,
            priceMax: 50,
            priceTiers: [],
            bookingType: "Default",
            bookingURLString: "https://example.com")
    }
}
