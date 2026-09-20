import TeesContract
import TeesData
import TeesViews
import XCTest
@testable import TeesForTheBoys

/// End-to-end coverage, through to the banner text a golfer actually reads,
/// for the scenario described in the "scraper dead for about a week" defect
/// report: a returning user, with a real cache on disk from before the
/// outage, opens the app once the GitHub Action has stopped firing for long
/// enough that `SupabaseSlotsRemote`'s bounded `course_day_scrapes` window
/// (today .. today+4) no longer contains any row at all.
///
/// `TeeTimeStoreTests.testALongScraperOutageDoesNotOverwriteRealDataWithAnEmptyWindow`
/// already proves the store itself keeps the real payload. This test proves
/// the fix actually reaches the screen: `AppSession` wires that surviving
/// payload into `SearchStore`, and `FreshnessSummary.make` — fed the
/// survived, still-non-empty `courseDays` — must say "Tee times last updated
/// N days ago", never the first-launch copy "Tee times haven't loaded yet"
/// (`FreshnessSummary.swift`'s own `testNoCourseDaysAtAllIsStaleAndSilentAboutClubs`
/// is the assertion that exact banner exists for a genuinely-empty
/// `courseDays`; this test is the proof a week-long outage must not land in
/// that same empty state for a device that already had real data).
@MainActor
final class AppSessionScraperOutageFreshnessTests: XCTestCase {

    private struct FakeOutageRemote: SlotsFetching {
        let payload: ContractPayload
        func fetchPayload() async throws -> ContractPayload { payload }
    }

    private struct FakeSeededCache: PayloadCaching {
        let seeded: CachedPayload?
        func load() throws -> CachedPayload? { seeded }
        func save(_ payload: ContractPayload, fetchedAt: Date) throws {}
        func clear() throws {}
    }

    override func setUp() {
        super.setUp()
        SupabaseConfiguration.configure(url: URL(string: "https://stub.supabase.co")!, anonKey: "stub-anon-key")
    }

    private func awaitSettled(_ store: TeeTimeStore) async {
        for _ in 0..<20_000 {
            let stillRefreshing = await store.snapshot.isRefreshing
            if !stillRefreshing { return }
            await Task.yield()
        }
    }

    func testAWeekLongScraperOutageReportsLastUpdatedNotNeverLoaded() async {
        // `SearchStore` (constructed by `AppSession` with no override) reads
        // the real wall clock for its freshness calculation, while
        // `TeeTimeStore` here is given an injected one — so `scrapedAt` is
        // pinned relative to `Date()`, not to a fixed instant, to keep both
        // clocks agreeing on "about nine days ago" regardless of when this
        // test runs.
        let now = Date()
        let scrapedAt = now.addingTimeInterval(-9 * 24 * 3600)

        let course = Course(
            slug: "long-reef", name: "Long Reef Golf Club", region: "Northern Beaches",
            host: "long-reef.miclub.com.au", feeGroupID: "1", holes: 18, par: 70,
            lengthMetres: nil, driveMinutesFromBondi: 20, requiresRegistration: false,
            address: nil, notes: "", sortOrder: 1)
        let healthyDay = CourseDay(
            courseSlug: "long-reef", teeDate: "2026-09-13", ok: true, slotCount: 3,
            error: nil, lastAttemptAt: scrapedAt, lastSuccessAt: scrapedAt)
        // The one real success on record before the outage began — this is
        // what a device that "has used the app for months" has on disk.
        let cache = FakeSeededCache(seeded: CachedPayload(
            payload: ContractPayload(
                generatedAt: "2026-09-13T06:00:00+10:00",
                courses: [course], slots: [], courseDays: [healthyDay]),
            fetchedAt: scrapedAt))

        // The live read, a week later: courses come back (undated query),
        // course_day_scrapes and open_slots do not — the query window has
        // moved entirely past the scraper's last write. A normal 200, not a
        // thrown error.
        let outagePayload = ContractPayload(
            generatedAt: "2026-09-20T06:00:00+10:00",
            courses: [course], slots: [], courseDays: [])
        let remote = FakeOutageRemote(payload: outagePayload)
        let store = TeeTimeStore(remote: remote, cache: cache, now: { now })

        let session = AppSession(makeTeeTimeStore: { store })
        await session.start()
        await awaitSettled(store)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertNil(session.configurationFailure, "precondition: start() must actually reach store.start()")
        XCTAssertNotNil(session.searchStore.payload, "the real pre-outage payload must still be on screen")

        let banner = session.searchStore.freshness.bannerText
        XCTAssertNotEqual(
            banner, "Tee times haven't loaded yet",
            "a week-long scraper outage must not read the same as a device that has never fetched anything")
        XCTAssertEqual(
            banner, "Tee times last updated 9 days ago",
            "the banner must name how long the real, surviving data has been sitting there")
    }
}
