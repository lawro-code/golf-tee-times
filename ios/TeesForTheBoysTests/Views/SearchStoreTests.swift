import XCTest
import TeesContract
@testable import TeesViews

/// The store is the only stateful thing in the track, so it gets the tests the
/// screens cannot have. Every one of them injects both seams — a clock and a
/// key-value store — so nothing here reads the real time or the simulator's
/// defaults.
@MainActor
final class SearchStoreTests: XCTestCase {

    /// 2099-10-03T00:00:00+10:00 — inside `minimal.json`'s first day, and
    /// deliberately ahead of every one of that day's tee times (earliest is
    /// 06:16) so this fixed clock does not itself age a fixture slot into the
    /// past and filter it out of `SlotQuery.apply`.
    private let day1Morning = Date(timeIntervalSince1970: 4_094_632_800)

    private func store(
        preferences: ViewsKeyValueStore = InMemoryViewsStore(),
        fixture: String = "minimal",
        now: Date? = nil
    ) -> SearchStore {
        let instant = now ?? day1Morning
        return SearchStore(preferences: preferences, fixture: fixture, now: { instant })
    }

    // MARK: - Loading

    func testStartsIdleAndEmpty() {
        let s = store()
        XCTAssertEqual(s.state, .idle)
        XCTAssertNil(s.payload)
        XCTAssertTrue(s.sections.isEmpty)
        XCTAssertEqual(s.resultCount, 0)
        XCTAssertTrue(s.courses.isEmpty)
        XCTAssertFalse(s.isOffline)
    }

    func testLoadingMinimalFillsEverythingDerived() {
        let s = store()
        s.load()

        XCTAssertEqual(s.state, .loaded)
        XCTAssertEqual(s.payload?.slots.count, 9)
        XCTAssertEqual(s.courses.count, 15, "the roster is frozen at fifteen")
        // Default filters are 18 holes, so the four 9-hole bookings drop out.
        XCTAssertEqual(s.resultCount, 5)
        XCTAssertEqual(s.sections.map(\.date), ["2099-10-03", "2099-10-04", "2099-10-10"])
        XCTAssertEqual(
            s.sections.reduce(0) { $0 + $1.results.count }, s.resultCount,
            "resultCount and the sections must agree")
    }

    /// A fixture name that is not in the bundle is a programmer error, not a
    /// crash. It lands in `.failed` carrying `ContractLoader`'s own message, so
    /// the error says which fixture.
    func testMissingFixtureLandsInFailedRatherThanCrashing() throws {
        let s = store(fixture: "not-a-fixture")
        s.load()

        guard case .failed(let message) = s.state else {
            return XCTFail("expected .failed, got \(s.state)")
        }
        XCTAssertTrue(message.contains("not-a-fixture"), message)
        XCTAssertNil(s.payload)
        XCTAssertTrue(s.sections.isEmpty)
        XCTAssertEqual(s.resultCount, 0)
        XCTAssertEqual(s.freshness, .unknown)
    }

    func testGoldenLoadsToo() {
        let s = store(fixture: "golden", now: Date(timeIntervalSince1970: 1_789_000_000))
        s.load()
        XCTAssertEqual(s.state, .loaded)
        XCTAssertEqual(s.payload?.slots.count, 1755)
    }

    // MARK: - Holes, remembered

    /// CONTRACT.md §2 and the "remembers what the user last chose" requirement,
    /// in one round trip.
    func testHolesDefaultsToEighteen() {
        XCTAssertEqual(store().filters.holes, .eighteen)
    }

    func testHolesIsReadFromPreferencesOnInit() {
        let prefs = InMemoryViewsStore(seed: [ViewsPreferences.Key.holes: "nine"])
        XCTAssertEqual(store(preferences: prefs).filters.holes, .nine)
    }

    func testChangingHolesPersistsItForTheNextLaunch() {
        let prefs = InMemoryViewsStore()
        let first = store(preferences: prefs)
        first.load()
        XCTAssertEqual(first.filters.holes, .eighteen)

        first.filters.holes = .nine
        XCTAssertEqual(ViewsPreferences.holes(from: prefs), .nine, "the write did not reach the store")

        // Next launch, same phone.
        let second = store(preferences: prefs)
        second.load()
        XCTAssertEqual(second.filters.holes, .nine)
        XCTAssertEqual(second.resultCount, 4, "and it is actually filtering on it")
    }

    /// A second load must land on the same state rather than appending to it
    /// or half-clearing it. Stage 2 swaps the fixture read for a refresh, and a
    /// refresh that doubled the list would only show up here.
    func testLoadingTwiceLandsOnTheSameState() {
        let s = store()
        s.load()
        let firstPass = s.sections.map { ($0.date, $0.results.map(\.id)) }

        s.load()

        XCTAssertEqual(s.state, .loaded)
        XCTAssertEqual(s.resultCount, 5)
        XCTAssertEqual(s.sections.map(\.date), firstPass.map(\.0))
        XCTAssertEqual(s.sections.map { $0.results.map(\.id) }, firstPass.map(\.1))
    }

    /// Persistence is a write to the golfer's phone, and the store guards it
    /// behind `oldValue.holes != filters.holes`. Every other filter is a
    /// session choice: picking a day must not write anything, and reading the
    /// preference at launch must not write it back either.
    func testOnlyAHolesChangeReachesPersistence() {
        let spy = RecordingViewsStore()
        let s = store(preferences: spy)
        s.load()
        XCTAssertTrue(spy.writes.isEmpty, "launching wrote to the store: \(spy.writes)")

        s.filters.days = ["2099-10-10"]
        s.filters.players = 3
        s.filters.maxPrice = 60
        XCTAssertTrue(spy.writes.isEmpty, "a session filter was persisted: \(spy.writes)")

        s.filters.holes = .nine
        XCTAssertEqual(spy.writes.map(\.value), ["nine"])
        XCTAssertEqual(spy.writes.map(\.key), [ViewsPreferences.Key.holes])
    }

    // MARK: - Filters drive the derived state

    func testSettingFiltersRecomputesSections() {
        let s = store()
        s.load()
        XCTAssertEqual(s.resultCount, 5)

        s.filters.holes = .any
        XCTAssertEqual(s.resultCount, 9)

        s.filters.days = ["2099-10-10"]
        XCTAssertEqual(s.resultCount, 2)
        XCTAssertEqual(s.sections.map(\.date), ["2099-10-10"])
    }

    /// The store is the only caller that knows whether a price filter is on, so
    /// it is the only place that can ask for the sink.
    func testAPriceFilterSinksUnpricedSlotsWithoutDroppingThem() throws {
        let s = store()
        s.load()
        s.filters = SearchFilters(days: ["2099-10-03"], holes: .any, maxPrice: 60)

        let day = try XCTUnwrap(s.sections.first)
        XCTAssertEqual(day.results.count, 5)
        XCTAssertEqual(day.results.suffix(2).map(\.id), [
            "warringah:2099-10-03:0616:10th-tee-social",
            "warringah:2099-10-03:0616:1st-tee-social"
        ])
    }

    func testResetGoesBackToStandard() {
        let s = store()
        s.load()
        s.filters = SearchFilters(days: ["2099-10-10"], players: 4, holes: .nine, maxPrice: 40)
        XCTAssertNotEqual(s.resultCount, 5)

        s.resetFilters()
        XCTAssertEqual(s.filters, .standard)
        XCTAssertEqual(s.filters.activeCount, 0)
        XCTAssertEqual(s.resultCount, 5)
    }

    /// Reset means reset. A golfer who taps Clear and still gets a nine-hole
    /// list has been told the button does nothing.
    func testResetAlsoReturnsHolesToEighteenAndPersistsThat() {
        let prefs = InMemoryViewsStore(seed: [ViewsPreferences.Key.holes: "nine"])
        let s = store(preferences: prefs)
        s.load()
        XCTAssertEqual(s.filters.holes, .nine)

        s.resetFilters()
        XCTAssertEqual(s.filters.holes, .eighteen)
        XCTAssertEqual(ViewsPreferences.holes(from: prefs), .eighteen)
    }

    // MARK: - Today

    /// Sydney, not the device's zone. A golfer checking from a Melbourne
    /// lounge is still booking a Sydney morning.
    func testTodayIsSydneyWallClock() {
        XCTAssertEqual(store(now: day1Morning).today, "2099-10-03")
    }

    /// The instant that separates the two zones: 2099-10-04T00:30 in Sydney is
    /// 2099-10-03T14:30 in UTC. Sydney says the 4th, UTC says the 3rd, and a
    /// store formatting in UTC would put a golfer a day behind.
    func testTodayRollsOverOnSydneyMidnightNotUTCMidnight() {
        let justAfterSydneyMidnight = Date(timeIntervalSince1970: 4_094_721_000)
        XCTAssertEqual(store(now: justAfterSydneyMidnight).today, "2099-10-04")
    }

    func testSectionTitlesFollowTheInjectedClock() {
        let s = store(now: day1Morning)
        s.load()
        s.filters.holes = .any
        XCTAssertEqual(s.sections.map(\.title), ["Today", "Tomorrow", "Sat 10 Oct"])
    }

    // MARK: - Day rollover

    /// The confirmed regression: nothing ever re-derived `sections` after
    /// launch, so a golfer who opened the app once and left it sitting —
    /// no filter touched, no reload, no relaunch — sailed through local
    /// midnight with yesterday's section titles frozen in place.
    ///
    /// The clock starts at 23:58 on 2099-10-03 and moves two hours forward
    /// with nothing else touched — exactly the shipped app between
    /// refreshes. No fixture slot's `tee_at` falls inside that two-hour
    /// window (`minimal.json`'s Oct-4 round is `bayview` at 09:45, hours
    /// later), so which rounds match must not change at all — isolating the
    /// one thing that must: `today` moves from "2099-10-03" to "2099-10-04",
    /// and the still-present, still-in-the-same-place 2099-10-04 section's
    /// title has to move with it, from "Tomorrow" to "Today".
    func testSectionsReflectTheClockEvenWithoutATouchedFilterOrReload() {
        let clock = MutableClock(ContractDate.date(from: "2099-10-03T23:58:00+10:00")!)
        let s = SearchStore(preferences: InMemoryViewsStore(), fixture: "minimal", now: { clock.date })
        s.load()

        XCTAssertEqual(s.today, "2099-10-03")
        XCTAssertEqual(s.sections.map(\.date), ["2099-10-04", "2099-10-10"])
        XCTAssertEqual(s.sections.first(where: { $0.date == "2099-10-04" })?.title, "Tomorrow")
        XCTAssertEqual(s.resultCount, 2)

        // Two hours later. No filter touched, no `load()`/`apply()` call —
        // the only thing that changes is the clock.
        clock.date = clock.date.addingTimeInterval(2 * 3600)

        XCTAssertEqual(s.today, "2099-10-04", "today was already computed fresh and never had this bug")
        XCTAssertEqual(
            s.resultCount, 2,
            "no slot's tee_at falls inside the two hours that passed; only the day changed, not the matches")
        XCTAssertEqual(
            s.sections.first(where: { $0.date == "2099-10-04" })?.title, "Today",
            "2099-10-04 is today now; this section must not still read 'Tomorrow'")
    }

    // MARK: - Freshness

    func testFreshnessIsComputedFromTheLoadedPayload() {
        // The fixture was scraped at 2099-10-01T07:30+10:00; the clock here is
        // two days later, so it is well past stale.
        let s = store()
        s.load()
        XCTAssertTrue(s.freshness.isStale)
        XCTAssertEqual(s.freshness.failedCourseSlugs, ["castle-cove"])
        XCTAssertEqual(s.freshness.healthyButEmptyCourseSlugs, ["long-reef"])
        XCTAssertNotNil(s.freshness.bannerText)
    }

    func testFreshnessIsQuietWhenTheClockSitsOnTheScrape() {
        let s = store(now: Date(timeIntervalSince1970: 4_094_487_000 + 600))
        s.load()
        XCTAssertFalse(s.freshness.isStale)
        XCTAssertEqual(s.freshness.bannerText, "Couldn't reach Castle Cove")
    }

    /// The real cadence: days 0-2 rescrape every 20 minutes
    /// (`scrape-fast.yml`), days 3-4 only every ~12h at the full run
    /// (`scrape.yml` + `cadence.py`'s `FULL_RUN_HOURS`). A payload always mixes
    /// both. Filtering down to a stale-only day must surface that day's own
    /// staleness — not borrow freshness from a day-0-2 row nobody is looking
    /// at. Before the fix, `freshness` was computed from the whole payload
    /// regardless of `filters.days`/`filters.courseSlugs`, so this failed.
    func testFreshnessReflectsTheSelectedDayNotTheWholePayload() {
        let now = Date(timeIntervalSince1970: 4_094_632_800) // matches `day1Morning`
        let freshDay = "2099-10-03"
        let staleDay = "2099-10-07"

        let payload = ContractPayload(
            generatedAt: "2099-10-03T00:00:00+10:00",
            courses: [],
            slots: [],
            courseDays: [
                CourseDay(
                    courseSlug: "bayview", teeDate: freshDay, ok: true, slotCount: 1,
                    error: nil, lastAttemptAt: now, lastSuccessAt: now.addingTimeInterval(-5 * 60)),
                CourseDay(
                    courseSlug: "bayview", teeDate: staleDay, ok: true, slotCount: 1,
                    error: nil, lastAttemptAt: now, lastSuccessAt: now.addingTimeInterval(-4 * 3600))
            ])

        let s = store(now: now)
        s.apply(payload: payload)

        // Unfiltered: the recent day-0 row keeps the aggregate looking fresh.
        XCTAssertFalse(s.freshness.isStale)

        // A golfer narrows to the day that's actually only checked every ~12h.
        s.filters.days = [staleDay]
        XCTAssertTrue(
            s.freshness.isStale,
            "filtering to a day last scraped 4 hours ago must show as stale, " +
            "even though an unrelated day elsewhere in the payload is fresh")
        XCTAssertEqual(s.freshness.lastSuccessAt, now.addingTimeInterval(-4 * 3600))
    }

    // MARK: - Previews

    func testPreviewStoreIsLoadedAndSelfContained() {
        let s = SearchStore.previewStore()
        XCTAssertEqual(s.state, .loaded)
        XCTAssertEqual(s.courses.count, 15)
        XCTAssertFalse(s.sections.isEmpty)
    }

    func testPreviewStoreCanUseGolden() {
        let s = SearchStore.previewStore(fixture: "golden")
        XCTAssertEqual(s.state, .loaded)
        XCTAssertEqual(s.payload?.slots.count, 1755)
    }

    // MARK: - Offline

    func testOfflineIsJustAFlagTheStoreCarries() {
        let s = store()
        s.isOffline = true
        XCTAssertTrue(s.isOffline)
    }
}

/// A clock a test can move forward mid-run, so it can assert on what the
/// store does when time passes with nothing else touched — the exact shape
/// of the day-rollover regression, which no fixed instant can exercise.
/// `@unchecked Sendable`: only ever touched from the main actor in a test,
/// same as every other seam here, but the `now: () -> Date` closure it backs
/// is not itself actor-isolated.
private final class MutableClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

/// An `InMemoryViewsStore` that also remembers what was written to it, so a
/// test can assert on writes that did *not* happen. Top level rather than
/// nested so it carries no actor isolation of its own.
private final class RecordingViewsStore: ViewsKeyValueStore {
    struct Write: Equatable {
        let key: String
        let value: String?
    }

    private var values: [String: String] = [:]
    private(set) var writes: [Write] = []

    func string(forKey key: String) -> String? { values[key] }

    func set(_ value: String?, forKey key: String) {
        writes.append(Write(key: key, value: value))
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }
}
