import TeesContract
import XCTest
@testable import TeesViews

/// The sentences are the feature, so they are what is pinned here.
///
/// A watch a golfer cannot read back is a watch they cannot trust, and the
/// button's accessibility label *is* `sentence` — so a wording regression is an
/// accessibility regression at the same time. Every assertion below is an exact
/// string for that reason: "contains Saturday" would pass on
/// "Alert me when a a Saturday opens".
///
/// `today` is 16 September 2026, a Wednesday, in most tests. That is far enough
/// from 19 September, a Saturday, that the day is named by weekday rather than
/// collapsing to "tomorrow" — which has its own test.
final class WatchDraftTests: XCTestCase {

    private let today = "2026-09-16"          // Wednesday
    private let saturday = "2026-09-19"
    private let sunday = "2026-09-20"
    private let monday = "2026-09-21"
    private let tuesday = "2026-09-22"

    private static let courses = [
        course("the-coast", "The Coast Golf Club"),
        course("bondi", "Bondi Golf Club"),
        course("moore-park", "Moore Park Golf Course")
    ]

    private static func course(_ slug: String, _ name: String) -> Course {
        Course(
            slug: slug, name: name, region: "Eastern Suburbs",
            host: "\(slug).miclub.com.au", feeGroupID: "1", holes: 18, par: 70,
            driveMinutesFromBondi: 12, requiresRegistration: false,
            address: nil, notes: "", sortOrder: 0
        )
    }

    private func draft(_ filters: SearchFilters, today: String? = nil) -> WatchDraft {
        WatchDraft(filters: filters, courses: Self.courses, today: today ?? self.today)
    }

    // MARK: - 1. The untouched filter set

    /// The one sentence the ticket names outright. A first-time user who taps
    /// the button without touching a filter gets a real watch, so it needs real
    /// words — never "Alert me when opens".
    func testAStandardFilterSetStillMakesAWholeSentence() {
        let watch = draft(.standard)
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens")
        XCTAssertEqual(watch.emptySentence, "No tee times \u{2014} alert me when one opens.")
        XCTAssertTrue(SearchFilters.standard.isStandard)
    }

    // MARK: - 2. Time, day and one club

    func testATimeADayAndOneClubReadAsOneSentence() {
        let watch = draft(
            SearchFilters(
                days: [saturday], timesOfDay: [.morning], courseSlugs: ["the-coast"])
        )
        XCTAssertEqual(
            watch.sentence,
            "Alert me when a morning tee time opens on Saturday at The Coast")
        XCTAssertEqual(
            watch.emptySentence,
            "No morning tee times on Saturday at The Coast \u{2014} alert me when one opens.")
    }

    /// "Golf Club" is stripped, the way every other label in the track strips
    /// it. The club is "The Coast", not "The Coast Golf Club", in a sentence
    /// somebody reads a dozen times.
    func testTheClubIsNamedTheWayTheRestOfTheAppNamesIt() {
        let watch = draft(SearchFilters(courseSlugs: ["moore-park"]))
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens at Moore Park")
    }

    // MARK: - 3. Several clubs, and none

    func testSeveralClubsAreCountedRatherThanListed() {
        // A strict subset of the fixture's roster — selecting *every* course
        // is a different case, covered below, where the count must not
        // appear at all.
        let watch = draft(SearchFilters(courseSlugs: ["the-coast", "bondi"]))
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens at 2 clubs")
    }

    /// Regression test for the defect where ticking every course on the
    /// roster read as a bounded "at N clubs" watch instead of the unfiltered
    /// default it actually behaves as.
    ///
    /// `private.watch_matches`
    /// (supabase/migrations/alerts_0010_watch_lifecycle.sql) treats a null
    /// `course_slugs` column as "every course" and an explicit list naming
    /// every real slug matches identically — so a golfer who ticks every box
    /// to be thorough must be told the same thing as a golfer who ticks
    /// nothing at all.
    func testSelectingEveryCourseOnTheRosterReadsAsNoClubFilterAtAll() {
        let everyCourse = Set(Self.courses.map(\.slug))
        let watch = draft(SearchFilters(courseSlugs: everyCourse))
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens")
        XCTAssertEqual(watch.emptySentence, "No tee times \u{2014} alert me when one opens.")
    }

    func testNoClubSelectedMeansTheClubIsNotMentionedAtAll() {
        let watch = draft(SearchFilters(timesOfDay: [.twilight]))
        XCTAssertEqual(watch.sentence, "Alert me when a twilight tee time opens")
    }

    /// A saved watch pointing at a slug no longer in the frozen fifteen keeps
    /// its club in the sentence. Losing it silently would tell the golfer their
    /// watch covers every club, which is the opposite of what it does.
    func testAnUnknownSlugKeepsItsPlaceInTheSentence() {
        let watch = draft(SearchFilters(courseSlugs: ["long-reef"]))
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens at long-reef")
    }

    // MARK: - 4. Holes — the CONTRACT.md §2 default

    func testEighteenHolesIsTheDefaultAndIsNeverMentioned() {
        let watch = draft(SearchFilters(holes: .eighteen))
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens")
    }

    func testNineHolesIsAChoiceAndIsAlwaysMentioned() {
        let watch = draft(SearchFilters(holes: .nine))
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens, 9 holes")
    }

    func testEitherHoleCountSaysSoRatherThanGoingQuiet() {
        let watch = draft(SearchFilters(timesOfDay: [.midday], holes: .any))
        XCTAssertEqual(watch.sentence, "Alert me when a midday tee time opens, 9 or 18 holes")
    }

    // MARK: - 5. Price

    func testAPriceCeilingIsNamedInDollars() {
        let watch = draft(SearchFilters(maxPrice: 60))
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens, under $60")
    }

    func testAnAwkwardPriceKeepsItsCents() {
        let watch = draft(SearchFilters(maxPrice: 62.5))
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens, under $62.50")
    }

    // MARK: - 6. Players and drive

    func testPlayersAreMentionedOnlyAboveOne() {
        XCTAssertEqual(
            draft(SearchFilters(players: 1)).sentence,
            "Alert me when any tee time opens")
        XCTAssertEqual(
            draft(SearchFilters(players: 3)).sentence,
            "Alert me when any tee time opens, for 3 players")
    }

    /// Drive time is not in the ticket's list of qualifiers, but `SearchFilters`
    /// lets a golfer set one and `activeCount` counts it. A sentence that
    /// dropped it would describe a watch the golfer did not create.
    func testADriveCeilingIsNotQuietlyDropped() {
        let watch = draft(SearchFilters(maxDriveMinutes: 30))
        XCTAssertEqual(
            watch.sentence, "Alert me when any tee time opens, within 30 min of Bondi")
    }

    // MARK: - 7. Days

    func testTwoDaysAreJoinedWithOr() {
        let watch = draft(SearchFilters(days: [sunday, saturday]))
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens on Saturday or Sunday")
    }

    func testThreeDaysTakeACommaAndNoOxfordComma() {
        let watch = draft(SearchFilters(days: [monday, saturday, sunday]))
        XCTAssertEqual(
            watch.sentence,
            "Alert me when any tee time opens on Saturday, Sunday or Monday")
    }

    func testFourDaysAreCountedRatherThanRecited() {
        let watch = draft(SearchFilters(days: [saturday, sunday, monday, tuesday]))
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens on 4 days")
    }

    /// The only thing the injected `today` is for. An alert that says "Friday"
    /// on Friday morning is worse than one that says "today".
    func testTodayAndTomorrowSaySoInsteadOfNamingTheWeekday() {
        XCTAssertEqual(
            draft(SearchFilters(days: ["2026-09-18"]), today: "2026-09-18").sentence,
            "Alert me when any tee time opens today")
        XCTAssertEqual(
            draft(SearchFilters(days: ["2026-09-19"]), today: "2026-09-18").sentence,
            "Alert me when any tee time opens tomorrow")
    }

    /// "on today or Sunday" is not English, so the preposition goes as soon as a
    /// relative day is in the list.
    func testARelativeDayDropsThePreposition() {
        let watch = draft(SearchFilters(days: ["2026-09-18", "2026-09-20"]), today: "2026-09-18")
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens today or Sunday")
    }

    func testAnUnparseableDayIsStillNamed() {
        let watch = draft(SearchFilters(days: ["not-a-date"]))
        XCTAssertEqual(watch.sentence, "Alert me when any tee time opens on not-a-date")
    }

    // MARK: - 8. Time buckets

    func testTheArticleFollowsTheBucketRatherThanBeingHardcoded() {
        XCTAssertEqual(
            draft(SearchFilters(timesOfDay: [.earlyMorning])).sentence,
            "Alert me when an early tee time opens")
        XCTAssertEqual(
            draft(SearchFilters(timesOfDay: [.afternoon])).sentence,
            "Alert me when an afternoon tee time opens")
        XCTAssertEqual(
            draft(SearchFilters(timesOfDay: [.morning])).sentence,
            "Alert me when a morning tee time opens")
    }

    /// Buckets come out in clock order however the `Set` happens to be ordered
    /// in memory — otherwise the same watch would read differently run to run.
    func testSeveralBucketsAreListedInClockOrder() {
        let watch = draft(SearchFilters(timesOfDay: [.twilight, .earlyMorning, .morning]))
        XCTAssertEqual(
            watch.sentence, "Alert me when an early, morning or twilight tee time opens")
    }

    func testTheSentenceDoesNotDependOnSetOrdering() {
        let first = draft(SearchFilters(days: [saturday, sunday, monday])).sentence
        for _ in 0..<20 {
            XCTAssertEqual(draft(SearchFilters(days: [monday, sunday, saturday])).sentence, first)
        }
    }

    // MARK: - 9. All of it at once

    func testEveryFilterAtOnceStillReadsAsOneSentence() {
        let watch = draft(
            SearchFilters(
                days: [saturday],
                timesOfDay: [.morning],
                players: 2,
                holes: .nine,
                maxPrice: 60,
                maxDriveMinutes: 30,
                courseSlugs: ["the-coast"]
            )
        )
        XCTAssertEqual(
            watch.sentence,
            "Alert me when a morning tee time opens on Saturday at The Coast, "
                + "9 holes, under $60, for 2 players, within 30 min of Bondi")
        XCTAssertEqual(
            watch.emptySentence,
            "No morning tee times on Saturday at The Coast, "
                + "9 holes, under $60, for 2 players, within 30 min of Bondi "
                + "\u{2014} alert me when one opens.")
    }

    /// The safety net under all of the above: whatever the combination, neither
    /// sentence is empty, neither ends mid-clause, and the empty one is a
    /// sentence rather than a fragment.
    func testNoCombinationOfFiltersProducesAHalfFormedSentence() {
        let days: [Set<String>] = [[], [saturday], [saturday, sunday]]
        let times: [Set<SearchFilters.TimeOfDay>] = [[], [.morning], [.earlyMorning, .twilight]]
        let clubs: [Set<String>] = [[], ["the-coast"], ["the-coast", "bondi"]]
        let holes: [SearchFilters.HolesFilter] = [.eighteen, .nine, .any]
        let prices: [Double?] = [nil, 45]

        for day in days {
            for time in times {
                for club in clubs {
                    for hole in holes {
                        for price in prices {
                            let watch = draft(
                                SearchFilters(
                                    days: day, timesOfDay: time, players: 2,
                                    holes: hole, maxPrice: price, courseSlugs: club))
                            XCTAssertTrue(watch.sentence.hasPrefix("Alert me when "))
                            XCTAssertFalse(watch.sentence.contains("  "))
                            XCTAssertFalse(watch.sentence.hasSuffix(","))
                            XCTAssertFalse(watch.sentence.hasSuffix(" or"))
                            XCTAssertTrue(watch.emptySentence.hasPrefix("No "))
                            XCTAssertTrue(watch.emptySentence.hasSuffix("alert me when one opens."))
                            XCTAssertFalse(watch.emptySentence.contains("  "))
                        }
                    }
                }
            }
        }
    }

    // MARK: - 10. Identity

    /// The adjust sheet edits a watch that already exists, so the edited draft
    /// has to be the same watch. A fresh id here would leave Stage 2 saving a
    /// second alert every time somebody changed their mind.
    func testAdjustingAWatchKeepsItsIdentityAndRebuildsBothSentences() {
        let original = draft(SearchFilters(timesOfDay: [.morning]))
        let edited = original.updating(filters: SearchFilters(timesOfDay: [.twilight]))

        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.sentence, "Alert me when a twilight tee time opens")
        XCTAssertEqual(edited.emptySentence, "No twilight tee times \u{2014} alert me when one opens.")
        // The original is a value and is untouched, which is what makes Cancel
        // free: there is nothing to roll back.
        XCTAssertEqual(original.sentence, "Alert me when a morning tee time opens")
    }

    func testTwoWatchesBuiltSeparatelyAreDifferentWatches() {
        let first = draft(.standard)
        let second = draft(.standard)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.sentence, second.sentence)
    }
}
