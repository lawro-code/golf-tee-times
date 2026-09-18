import XCTest
import TeesContract
@testable import TeesViews

/// CONTRACT.md §5 in test form: **a club that failed and a club with nothing
/// free are not the same thing.** `minimal.json` carries one of each — Castle
/// Cove returned an error, Long Reef scraped perfectly and had zero open tee
/// times — so the two can be told apart without inventing data.
final class FreshnessSummaryTests: XCTestCase {

    private var payload: ContractPayload!

    /// The fixture's own timestamp: every `last_success_at` in `minimal.json`
    /// is 2026-10-01T07:30:00+10:00.
    private let scrapedAt = Date(timeIntervalSince1970: 1_790_803_800)

    override func setUpWithError() throws {
        payload = try ContractLoader.fixture("minimal")
    }

    private func summary(now: Date, staleAfter: TimeInterval = 3 * 3600) -> FreshnessSummary {
        FreshnessSummary.make(
            courseDays: payload.courseDays,
            courses: payload.courses,
            now: now,
            staleAfter: staleAfter)
    }

    func testTheFixtureTimestampIsWhatWeThinkItIs() throws {
        let success = try XCTUnwrap(payload.courseDays.compactMap(\.lastSuccessAt).max())
        XCTAssertEqual(success.timeIntervalSince1970, scrapedAt.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - The distinction

    func testFailedAndHealthyButEmptyAreReportedSeparately() {
        let s = summary(now: scrapedAt.addingTimeInterval(600))

        XCTAssertEqual(s.failedCourseSlugs, ["castle-cove"],
                       "Castle Cove returned an error: we could not look")
        XCTAssertEqual(s.healthyButEmptyCourseSlugs, ["long-reef"],
                       "Long Reef scraped fine and had nothing free: we looked")
        XCTAssertFalse(s.failedCourseSlugs.contains("long-reef"))
        XCTAssertFalse(s.healthyButEmptyCourseSlugs.contains("castle-cove"))
    }

    /// The banner names the club, because "Couldn't reach Castle Cove" and
    /// "Castle Cove has nothing free" lead a golfer to opposite decisions.
    func testBannerNamesTheFailure() throws {
        let s = summary(now: scrapedAt.addingTimeInterval(600))
        let banner = try XCTUnwrap(s.bannerText)
        XCTAssertEqual(banner, "Couldn't reach Castle Cove")
    }

    /// And a club we reached that simply had nothing is not a banner at all —
    /// it is an empty-state sentence.
    func testHealthyButEmptyIsNotAWarning() throws {
        let s = summary(now: scrapedAt.addingTimeInterval(600))
        XCTAssertEqual(s.emptyClubsText, "Long Reef has nothing free")
        XCTAssertFalse(try XCTUnwrap(s.bannerText).contains("Long Reef"))
    }

    func testNothingEmptyMeansNoEmptyText() {
        let s = FreshnessSummary.make(
            courseDays: [Self.day("bayview", ok: true, slots: 2, success: scrapedAt)],
            courses: payload.courses,
            now: scrapedAt)
        XCTAssertNil(s.emptyClubsText)
    }

    // MARK: - Staleness

    func testStalenessBoundaryIsExact() {
        XCTAssertFalse(summary(now: scrapedAt.addingTimeInterval(3 * 3600)).isStale,
                       "exactly three hours old is not yet stale")
        XCTAssertTrue(summary(now: scrapedAt.addingTimeInterval(3 * 3600 + 1)).isStale)
    }

    func testStaleBannerSaysHowOld() throws {
        let s = summary(now: scrapedAt.addingTimeInterval(4 * 3600))
        let banner = try XCTUnwrap(s.bannerText)
        XCTAssertTrue(banner.hasPrefix("Tee times last updated 4 hours ago"), banner)
        XCTAssertTrue(banner.contains("Couldn't reach Castle Cove"), banner)
    }

    func testNeverReachedAnythingIsStale() {
        let s = FreshnessSummary.make(
            courseDays: [Self.day("castle-cove", ok: false, slots: 0, success: nil)],
            courses: payload.courses,
            now: scrapedAt)
        XCTAssertTrue(s.isStale)
        XCTAssertNil(s.lastSuccessAt)
        XCTAssertEqual(
            s.bannerText,
            "Tee times haven't loaded yet \u{00B7} Couldn't reach Castle Cove")
    }

    /// Everything reached, nothing old: no banner. The screen says nothing
    /// rather than reassuring anyone.
    func testFullyFreshHasNoBanner() {
        let s = FreshnessSummary.make(
            courseDays: [
                Self.day("bayview", ok: true, slots: 3, success: scrapedAt),
                Self.day("long-reef", ok: true, slots: 1, success: scrapedAt)
            ],
            courses: payload.courses,
            now: scrapedAt.addingTimeInterval(60))
        XCTAssertNil(s.bannerText)
        XCTAssertFalse(s.isStale)
        XCTAssertTrue(s.isFullyFresh)
    }

    /// A club we reached with nothing free is still fully fresh — we know the
    /// answer, and the answer is "nothing". Hand-built course days rather than
    /// the fixture's, because `minimal.json` always carries Castle Cove's
    /// failure and that would drown the thing being tested.
    func testHealthyButEmptyIsStillFullyFresh() {
        let s = FreshnessSummary.make(
            courseDays: [
                Self.day("bayview", ok: true, slots: 2, success: scrapedAt),
                Self.day("long-reef", ok: true, slots: 0, success: scrapedAt)
            ],
            courses: payload.courses,
            now: scrapedAt.addingTimeInterval(60))
        XCTAssertTrue(s.isFullyFresh)
        XCTAssertNil(s.bannerText, "an empty club is not a warning")
        XCTAssertEqual(s.healthyButEmptyCourseSlugs, ["long-reef"])
        XCTAssertEqual(s.emptyClubsText, "Long Reef has nothing free")
    }

    func testLastSuccessIsTheNewestOne() {
        let s = FreshnessSummary.make(
            courseDays: [
                Self.day("bayview", ok: true, slots: 1, success: scrapedAt),
                Self.day("long-reef", ok: true, slots: 1,
                         success: scrapedAt.addingTimeInterval(1800))
            ],
            courses: payload.courses,
            now: scrapedAt.addingTimeInterval(1800))
        XCTAssertEqual(s.lastSuccessAt, scrapedAt.addingTimeInterval(1800))
    }

    // MARK: - Edge cases in the aggregation

    /// A club that failed on one day and was merely empty on another is a
    /// failure. The stronger claim has to win or the banner under-reports.
    func testAClubThatFailedOnAnyDayCountsAsFailed() {
        let s = FreshnessSummary.make(
            courseDays: [
                Self.day("bayview", teeDate: "2026-10-03", ok: true, slots: 0, success: scrapedAt),
                Self.day("bayview", teeDate: "2026-10-04", ok: false, slots: 0, success: nil)
            ],
            courses: payload.courses,
            now: scrapedAt)
        XCTAssertEqual(s.failedCourseSlugs, ["bayview"])
        XCTAssertTrue(s.healthyButEmptyCourseSlugs.isEmpty)
    }

    /// A day that failed still carries the timestamp of the last time we did
    /// reach that club, and that timestamp is what the banner is for.
    ///
    /// This is not a hypothetical shape: `scraper/supabase_writer.py` sends
    /// failed days as a separate request with `last_success_at` omitted
    /// precisely so "a club having a bad afternoon" cannot erase it, and the
    /// frozen `public.course_freshness` view reads
    /// `max(d.last_success_at)` across every day, `ok` or not.
    ///
    /// The failure this guards against is the one the banner exists for: the
    /// scrape falls over everywhere, the app still shows the tee times it
    /// already has, and the banner has to say *how old they are* rather than
    /// "we have never loaded any", which is false and reads as a broken app.
    func testAFailedDayStillCountsTheLastSuccessfulScrapeItRemembers() throws {
        let now = scrapedAt.addingTimeInterval(40 * 60)
        let s = FreshnessSummary.make(
            courseDays: [
                Self.day("bayview", ok: false, slots: 0, success: scrapedAt),
                Self.day("long-reef", ok: false, slots: 0, success: scrapedAt)
            ],
            courses: payload.courses,
            now: now)

        XCTAssertEqual(
            s.lastSuccessAt, scrapedAt,
            "a failed day's remembered success was thrown away")
        XCTAssertFalse(s.isStale, "40 minutes old is not stale")
        XCTAssertEqual(s.bannerText, "Couldn't reach Bayview and Long Reef")
        XCTAssertFalse(
            try XCTUnwrap(s.bannerText).contains("haven't loaded"),
            "the data is 40 minutes old, not absent")
    }

    /// "Nothing free" is a claim about a club, not about one of its days.
    /// Every golf club is fully booked on some Saturday and wide open on the
    /// Sunday, and `public.course_freshness` agrees — it reports
    /// `sum(slot_count)` over the future days, per course.
    ///
    /// Reading it per day puts "Bayview has nothing free" on a screen that is
    /// listing Bayview tee times.
    func testAClubWithTeeTimesOnAnotherDayIsNotReportedAsHavingNothingFree() {
        let s = FreshnessSummary.make(
            courseDays: [
                Self.day("bayview", teeDate: "2026-10-03", ok: true, slots: 0, success: scrapedAt),
                Self.day("bayview", teeDate: "2026-10-04", ok: true, slots: 6, success: scrapedAt)
            ],
            courses: payload.courses,
            now: scrapedAt.addingTimeInterval(60))

        XCTAssertTrue(
            s.healthyButEmptyCourseSlugs.isEmpty,
            "a club with six tee times on Sunday does not have nothing free")
        XCTAssertNil(s.emptyClubsText)
    }

    /// The contradictory row: the scrape says it went fine but names no moment
    /// it succeeded. It must not be read as freshness — claiming the data is
    /// current on the strength of a row that cannot say when is exactly the
    /// lie the banner exists to prevent.
    func testAnOkDayWithNoSuccessTimestampCannotMakeTheDataLookFresh() {
        let s = FreshnessSummary.make(
            courseDays: [Self.day("bayview", ok: true, slots: 3, success: nil)],
            courses: payload.courses,
            now: scrapedAt)

        XCTAssertNil(s.lastSuccessAt)
        XCTAssertTrue(s.isStale)
        XCTAssertEqual(s.bannerText, "Tee times haven't loaded yet")
        XCTAssertFalse(s.isFullyFresh)
    }

    /// Both arrays are sorted, so the banner text is the same string every
    /// run. An unsorted set would make this test flaky rather than wrong.
    func testSlugArraysAreSortedAndDeduplicated() {
        let s = FreshnessSummary.make(
            courseDays: [
                Self.day("woollahra", ok: false, slots: 0, success: nil),
                Self.day("bayview", ok: false, slots: 0, success: nil),
                Self.day("bayview", teeDate: "2026-10-04", ok: false, slots: 0, success: nil),
                Self.day("castle-cove", ok: false, slots: 0, success: nil)
            ],
            courses: payload.courses,
            now: scrapedAt)
        XCTAssertEqual(s.failedCourseSlugs, ["bayview", "castle-cove", "woollahra"])
        XCTAssertEqual(s.failedCourseNames, ["Bayview", "Castle Cove", "Woollahra"])
    }

    /// A slug with no course row is still a club we failed on. Dropping it
    /// would under-report; a readable fallback keeps the banner honest.
    func testUnknownSlugGetsAReadableFallbackName() {
        let s = FreshnessSummary.make(
            courseDays: [Self.day("some-new-club", ok: false, slots: 0, success: nil)],
            courses: [],
            now: scrapedAt)
        XCTAssertEqual(s.failedCourseNames, ["Some New Club"])
    }

    func testNoCourseDaysAtAllIsStaleAndSilentAboutClubs() {
        let s = FreshnessSummary.make(courseDays: [], courses: payload.courses, now: scrapedAt)
        XCTAssertTrue(s.isStale)
        XCTAssertTrue(s.failedCourseSlugs.isEmpty)
        XCTAssertTrue(s.healthyButEmptyCourseSlugs.isEmpty)
        XCTAssertEqual(s.bannerText, "Tee times haven't loaded yet")
    }

    // MARK: - The placeholder

    /// Before a load, "we have not looked yet" is what the loading state says.
    /// Saying it twice, once as a staleness warning, is noise.
    func testUnknownIsQuiet() {
        XCTAssertNil(FreshnessSummary.unknown.bannerText)
        XCTAssertNil(FreshnessSummary.unknown.emptyClubsText)
        XCTAssertFalse(FreshnessSummary.unknown.isStale)
        XCTAssertNil(FreshnessSummary.unknown.lastSuccessAt)
    }

    // MARK: - Copy

    func testNameListCapsAtTwoAndCounts() {
        XCTAssertEqual(FreshnessSummary.nameList([]), "")
        XCTAssertEqual(FreshnessSummary.nameList(["Castle Cove"]), "Castle Cove")
        XCTAssertEqual(
            FreshnessSummary.nameList(["Castle Cove", "Bayview"]), "Castle Cove and Bayview")
        XCTAssertEqual(
            FreshnessSummary.nameList(["Castle Cove", "Bayview", "Long Reef"]),
            "Castle Cove, Bayview and 1 more")
        XCTAssertEqual(
            FreshnessSummary.nameList(["A", "B", "C", "D", "E"]), "A, B and 3 more")
    }

    func testEmptyClubsTextAgreesWithItselfOnPlurals() {
        let one = FreshnessSummary.make(
            courseDays: [Self.day("long-reef", ok: true, slots: 0, success: scrapedAt)],
            courses: payload.courses, now: scrapedAt)
        XCTAssertEqual(one.emptyClubsText, "Long Reef has nothing free")

        let two = FreshnessSummary.make(
            courseDays: [
                Self.day("long-reef", ok: true, slots: 0, success: scrapedAt),
                Self.day("bayview", ok: true, slots: 0, success: scrapedAt)
            ],
            courses: payload.courses, now: scrapedAt)
        XCTAssertEqual(two.emptyClubsText, "Bayview and Long Reef have nothing free")
    }

    /// The scrape runs every 20 minutes, so a number more precise than whole
    /// minutes would be claiming accuracy the data does not have.
    func testRelativeAgeUsesWholeUnits() {
        let t = scrapedAt
        XCTAssertEqual(FreshnessSummary.relativeAge(from: t, to: t), "just now")
        XCTAssertEqual(FreshnessSummary.relativeAge(from: t, to: t.addingTimeInterval(60)), "just now")
        XCTAssertEqual(FreshnessSummary.relativeAge(from: t, to: t.addingTimeInterval(90)), "1 minute ago")
        XCTAssertEqual(FreshnessSummary.relativeAge(from: t, to: t.addingTimeInterval(1500)), "25 minutes ago")
        XCTAssertEqual(FreshnessSummary.relativeAge(from: t, to: t.addingTimeInterval(3600)), "1 hour ago")
        XCTAssertEqual(FreshnessSummary.relativeAge(from: t, to: t.addingTimeInterval(4 * 3600)), "4 hours ago")
        XCTAssertEqual(FreshnessSummary.relativeAge(from: t, to: t.addingTimeInterval(86_400)), "1 day ago")
        XCTAssertEqual(FreshnessSummary.relativeAge(from: t, to: t.addingTimeInterval(3 * 86_400)), "3 days ago")
    }

    /// A phone whose clock jumps backwards produces a negative age. It must
    /// read as current, not wrap into "-1 minutes ago".
    func testClockSkewBackwardsReadsAsCurrent() {
        XCTAssertEqual(
            FreshnessSummary.relativeAge(from: scrapedAt, to: scrapedAt.addingTimeInterval(-7200)),
            "just now")
    }

    // MARK: - Helpers

    private static func day(
        _ slug: String,
        teeDate: String = "2026-10-03",
        ok: Bool,
        slots: Int,
        success: Date?
    ) -> CourseDay {
        CourseDay(
            courseSlug: slug,
            teeDate: teeDate,
            ok: ok,
            slotCount: slots,
            error: ok ? nil : "boom",
            lastAttemptAt: Date(timeIntervalSince1970: 1_790_803_800),
            lastSuccessAt: success)
    }
}
