import TeesContract
import XCTest
@testable import TeesViews

/// The detour, and the two things about it that can be got wrong silently: the
/// days it offers, and whether Save edits the watch or replaces it.
@MainActor
final class AlertAdjustSheetTests: XCTestCase {

    private func draft(_ filters: SearchFilters = .standard, today: String = "2026-09-16")
        -> WatchDraft
    {
        WatchDraft(filters: filters, courses: [], today: today)
    }

    // MARK: - The days it offers

    /// Six days: today plus five. That is what the scraper covers — "full" is
    /// days 0-5 — so offering a seventh would let a golfer watch a day nobody
    /// is looking at.
    func testTheSheetOffersTheSixDaysTheScraperActuallyCovers() {
        XCTAssertEqual(
            AlertAdjustSheet.candidateDays(from: "2026-09-16"),
            [
                "2026-09-16", "2026-09-17", "2026-09-18",
                "2026-09-19", "2026-09-20", "2026-09-21"
            ])
    }

    /// Sydney's clocks go forward on 4 October 2026 and that day is 23 hours
    /// long. Walking wall-clock date strings is what makes this come out right;
    /// adding 86,400 seconds six times would land on 3 October twice.
    func testTheDayWindowSurvivesTheOctoberClockChange() {
        let days = AlertAdjustSheet.candidateDays(from: "2026-10-02")
        XCTAssertEqual(
            days,
            [
                "2026-10-02", "2026-10-03", "2026-10-04",
                "2026-10-05", "2026-10-06", "2026-10-07"
            ])
        XCTAssertEqual(Set(days).count, days.count, "No day may appear twice")
    }

    func testTheDayWindowCrossesAMonthBoundary() {
        XCTAssertEqual(
            AlertAdjustSheet.candidateDays(from: "2026-09-28").last, "2026-10-03")
    }

    /// A date that will not parse yields today and stops, rather than an empty
    /// picker or a crash.
    func testAnUnreadableTodayStillOffersToday() {
        XCTAssertEqual(AlertAdjustSheet.candidateDays(from: "not-a-date"), ["not-a-date"])
    }

    // MARK: - Save edits, Cancel costs nothing

    /// Save hands back the same watch with different filters. A new identity
    /// here would leave a golfer who adjusted an alert with two of them.
    func testSavingAnAdjustedWatchEditsItRatherThanCreatingASecondOne() {
        let original = draft(SearchFilters(timesOfDay: [.morning]))
        let edited = original.updating(
            filters: SearchFilters(timesOfDay: [.earlyMorning], holes: .nine))

        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.sentence, "Alert me when an early tee time opens, 9 holes")
    }

    /// Cancel needs no rollback: the draft is a value, so editing a copy never
    /// touched the original.
    func testCancellingLeavesTheOriginalExactlyAsItWas() {
        let original = draft(SearchFilters(timesOfDay: [.morning], maxPrice: 60))
        _ = original.updating(filters: .standard)

        XCTAssertEqual(original.filters.timesOfDay, [.morning])
        XCTAssertEqual(original.filters.maxPrice, 60)
        XCTAssertEqual(
            original.sentence, "Alert me when a morning tee time opens, under $60")
    }

    /// The restatement at the top of the sheet is the same string the button
    /// shows, rebuilt on every edit — not a second phrasing that can drift.
    func testTheLiveRestatementIsTheSameSentenceTheButtonShows() {
        let watch = draft(.standard)
        var filters = watch.filters
        filters.timesOfDay = [.twilight]
        filters.players = 2

        XCTAssertEqual(
            watch.updating(filters: filters).sentence,
            "Alert me when a twilight tee time opens, for 2 players")
    }

    /// A draft with no price or drive ceiling is the common case, and the sheet
    /// has to hold a number for the sliders anyway. Building it must not trap.
    func testTheSheetBuildsFromAWatchWithNoPriceOrDriveCeiling() {
        let watch = draft(.standard)
        XCTAssertNil(watch.filters.maxPrice)
        XCTAssertNil(watch.filters.maxDriveMinutes)
        _ = AlertAdjustSheet(draft: watch, onSave: { _ in })
        XCTAssertEqual(AlertAdjustSheet.candidateDays(from: watch.today).count, 6)
    }
}
