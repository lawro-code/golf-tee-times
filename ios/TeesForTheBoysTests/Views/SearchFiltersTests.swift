import XCTest
@testable import TeesViews

/// `SearchFilters` has no clock, no bundle and no view, so every one of these
/// is an exact assertion on a boundary rather than a sample near one. The
/// bucket edges in particular are product decisions, and this file is where
/// changing one has to be said out loud.
final class SearchFiltersTests: XCTestCase {

    // MARK: - The default

    func testStandardIsOnePlayerEighteenHolesAndNothingElse() {
        let f = SearchFilters.standard
        XCTAssertEqual(f.players, 1)
        XCTAssertEqual(f.holes, .eighteen, "CONTRACT.md §2: holes defaults to 18")
        XCTAssertTrue(f.days.isEmpty)
        XCTAssertTrue(f.timesOfDay.isEmpty)
        XCTAssertTrue(f.courseSlugs.isEmpty)
        XCTAssertNil(f.maxPrice)
        XCTAssertNil(f.maxDriveMinutes)
        XCTAssertTrue(f.isStandard)
    }

    func testDefaultInitIsTheStandardFilters() {
        XCTAssertEqual(SearchFilters(), .standard)
    }

    /// A stepper bound to 1...4 cannot send a 7; a watch decoded from a future
    /// build could. Clamping here means `SlotQuery` never has to defend itself.
    func testPlayersIsClampedToOneThroughFour() {
        XCTAssertEqual(SearchFilters(players: 0).players, 1)
        XCTAssertEqual(SearchFilters(players: -3).players, 1)
        XCTAssertEqual(SearchFilters(players: 4).players, 4)
        XCTAssertEqual(SearchFilters(players: 9).players, 4)
    }

    // MARK: - The badge

    /// The one that matters: a fresh launch shows no badge even though
    /// `holes` is set, because 18 is the default rather than a choice.
    func testEighteenHolesDoesNotCountTowardsTheBadge() {
        XCTAssertEqual(SearchFilters.standard.activeCount, 0)
        XCTAssertEqual(SearchFilters(holes: .eighteen).activeCount, 0)
        XCTAssertEqual(SearchFilters(holes: .nine).activeCount, 1)
        XCTAssertEqual(SearchFilters(holes: .any).activeCount, 1)
    }

    func testEachFacetCountsOnceHoweverManyValuesItHolds() {
        XCTAssertEqual(SearchFilters(days: ["2026-10-03"]).activeCount, 1)
        XCTAssertEqual(
            SearchFilters(days: ["2026-10-03", "2026-10-04", "2026-10-10"]).activeCount, 1,
            "three days is one active filter, not three")
        XCTAssertEqual(SearchFilters(timesOfDay: [.morning, .twilight]).activeCount, 1)
        XCTAssertEqual(SearchFilters(courseSlugs: ["bayview", "long-reef"]).activeCount, 1)
    }

    func testPlayersCountsOnlyAboveOne() {
        XCTAssertEqual(SearchFilters(players: 1).activeCount, 0)
        XCTAssertEqual(SearchFilters(players: 2).activeCount, 1)
    }

    func testCeilingsCountWhenSet() {
        XCTAssertEqual(SearchFilters(maxPrice: 60).activeCount, 1)
        XCTAssertEqual(SearchFilters(maxDriveMinutes: 30).activeCount, 1)
    }

    func testEverythingAtOnce() {
        let f = SearchFilters(
            days: ["2026-10-03"],
            timesOfDay: [.morning],
            players: 3,
            holes: .nine,
            maxPrice: 60,
            maxDriveMinutes: 30,
            courseSlugs: ["woollahra"])
        XCTAssertEqual(f.activeCount, 7)
        XCTAssertFalse(f.isStandard)
    }

    // MARK: - Time-of-day buckets

    /// `tee_time` is `HH:MM:SS` — PostgREST renders a Postgres `time` with
    /// seconds. Code written against `"HH:MM"` compiles and silently never
    /// matches, so the seconds form is what every case below uses.
    func testBucketBoundariesAreExact() {
        XCTAssertTrue(SearchFilters.TimeOfDay.earlyMorning.matches(teeTime: "00:00:00"))
        XCTAssertTrue(SearchFilters.TimeOfDay.earlyMorning.matches(teeTime: "06:59:00"))
        XCTAssertFalse(SearchFilters.TimeOfDay.earlyMorning.matches(teeTime: "07:00:00"))

        XCTAssertTrue(SearchFilters.TimeOfDay.morning.matches(teeTime: "07:00:00"))
        XCTAssertTrue(SearchFilters.TimeOfDay.morning.matches(teeTime: "10:59:00"))
        XCTAssertFalse(SearchFilters.TimeOfDay.morning.matches(teeTime: "11:00:00"))

        XCTAssertTrue(SearchFilters.TimeOfDay.midday.matches(teeTime: "11:00:00"))
        XCTAssertTrue(SearchFilters.TimeOfDay.midday.matches(teeTime: "13:59:00"))
        XCTAssertFalse(SearchFilters.TimeOfDay.midday.matches(teeTime: "14:00:00"))

        XCTAssertTrue(SearchFilters.TimeOfDay.afternoon.matches(teeTime: "14:00:00"))
        XCTAssertTrue(SearchFilters.TimeOfDay.afternoon.matches(teeTime: "16:59:00"))
        XCTAssertFalse(SearchFilters.TimeOfDay.afternoon.matches(teeTime: "17:00:00"))

        XCTAssertTrue(SearchFilters.TimeOfDay.twilight.matches(teeTime: "17:00:00"))
        XCTAssertTrue(SearchFilters.TimeOfDay.twilight.matches(teeTime: "23:59:00"))
    }

    /// Every minute of the day lands in exactly one bucket. If a boundary is
    /// ever nudged, this is the test that catches the overlap or the hole.
    func testBucketsPartitionTheDay() {
        for hour in 0..<24 {
            let teeTime = String(format: "%02d:30:00", hour)
            let hits = SearchFilters.TimeOfDay.allCases.filter { $0.matches(teeTime: teeTime) }
            XCTAssertEqual(hits.count, 1, "\(teeTime) matched \(hits.count) buckets")
        }
    }

    func testMalformedTeeTimeMatchesNothing() {
        for bad in ["", "half six", "25:00:00", "07:61:00", "0700"] {
            for bucket in SearchFilters.TimeOfDay.allCases {
                XCTAssertFalse(bucket.matches(teeTime: bad), "\(bucket) matched \(bad)")
            }
        }
    }

    func testBucketCopy() {
        XCTAssertEqual(SearchFilters.TimeOfDay.earlyMorning.title, "Early")
        XCTAssertEqual(SearchFilters.TimeOfDay.earlyMorning.subtitle, "before 7am")
        XCTAssertEqual(SearchFilters.TimeOfDay.morning.title, "Morning")
        XCTAssertEqual(SearchFilters.TimeOfDay.morning.subtitle, "7\u{2013}11am")
        XCTAssertEqual(SearchFilters.TimeOfDay.midday.title, "Midday")
        XCTAssertEqual(SearchFilters.TimeOfDay.midday.subtitle, "11am\u{2013}2pm")
        XCTAssertEqual(SearchFilters.TimeOfDay.afternoon.title, "Afternoon")
        XCTAssertEqual(SearchFilters.TimeOfDay.afternoon.subtitle, "2\u{2013}5pm")
        XCTAssertEqual(SearchFilters.TimeOfDay.twilight.title, "Twilight")
        XCTAssertEqual(SearchFilters.TimeOfDay.twilight.subtitle, "after 5pm")
        XCTAssertEqual(SearchFilters.TimeOfDay.allCases.count, 5)
    }

    // MARK: - Holes

    func testHolesFilterMatchesTheBookingsHoleCount() {
        XCTAssertTrue(SearchFilters.HolesFilter.nine.matches(9))
        XCTAssertFalse(SearchFilters.HolesFilter.nine.matches(18))
        XCTAssertTrue(SearchFilters.HolesFilter.eighteen.matches(18))
        XCTAssertFalse(SearchFilters.HolesFilter.eighteen.matches(9))
        XCTAssertTrue(SearchFilters.HolesFilter.any.matches(9))
        XCTAssertTrue(SearchFilters.HolesFilter.any.matches(18))
    }

    func testHolesCopy() {
        XCTAssertEqual(SearchFilters.HolesFilter.nine.title, "9 holes")
        XCTAssertEqual(SearchFilters.HolesFilter.eighteen.title, "18 holes")
        XCTAssertEqual(SearchFilters.HolesFilter.any.title, "Either")
        XCTAssertEqual(SearchFilters.HolesFilter.allCases.count, 3)
    }

    // MARK: - Codable

    /// A watch is a saved `SearchFilters`. The raw values are therefore a
    /// storage format, and renaming a case silently orphans everyone's watches.
    func testRawValuesAreStableStorage() {
        XCTAssertEqual(SearchFilters.HolesFilter.nine.rawValue, "nine")
        XCTAssertEqual(SearchFilters.HolesFilter.eighteen.rawValue, "eighteen")
        XCTAssertEqual(SearchFilters.HolesFilter.any.rawValue, "any")
        XCTAssertEqual(SearchFilters.TimeOfDay.earlyMorning.rawValue, "earlyMorning")
    }

    /// The reason the clamp exists, in the initialiser's own words: "a stepper
    /// bound to 1...4 cannot produce a 7, but a decoded watch from a future
    /// build could." A watch is stored `SearchFilters`, so decoding is the
    /// threat model — and a `players` of 9 matches no slot in the contract
    /// (`total_spots` tops out at 4), which is an empty list a golfer cannot
    /// explain.
    func testFiltersDecodedFromStorageClampPlayersTheSameWayTheInitialiserDoes() throws {
        let tooMany = Data(#"""
        {"days":[],"timesOfDay":[],"players":9,"holes":"eighteen","courseSlugs":[]}
        """#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(SearchFilters.self, from: tooMany).players, 4,
            "a stored watch from another build decoded straight past the clamp")

        let tooFew = Data(#"""
        {"days":[],"timesOfDay":[],"players":0,"holes":"eighteen","courseSlugs":[]}
        """#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(SearchFilters.self, from: tooFew).players, 1)
    }

    func testRoundTripsThroughJSON() throws {
        let original = SearchFilters(
            days: ["2026-10-03", "2026-10-10"],
            timesOfDay: [.morning, .twilight],
            players: 3,
            holes: .nine,
            maxPrice: 59.5,
            maxDriveMinutes: 30,
            courseSlugs: ["bayview"])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(SearchFilters.self, from: data), original)
    }
}
