import TeesContract
import XCTest
@testable import TeesDesign

/// The `.course-header` meta run.
///
/// The interesting behaviour is subtraction: what the header does when a fact
/// is missing. A segment whose source is nil has to disappear completely — not
/// render empty, and not leave the `·` that was going to sit beside it.
final class TeesCourseHeaderTests: XCTestCase {

    // MARK: - Fixtures

    private static func course(
        slug: String = "warringah",
        name: String = "Warringah Golf Club",
        region: String = "Northern Beaches",
        holes: Int = 18,
        driveMinutesFromBondi: Int? = 32,
        requiresRegistration: Bool = false
    ) -> Course {
        Course(
            slug: slug,
            name: name,
            region: region,
            host: "warringah.miclub.com.au",
            feeGroupID: "3000000",
            holes: holes,
            par: 70,
            driveMinutesFromBondi: driveMinutesFromBondi,
            requiresRegistration: requiresRegistration,
            address: nil,
            notes: "",
            sortOrder: 1)
    }

    /// A slot from the same club, so the two initialisers can be compared.
    private static func slot(
        from course: Course,
        holes: Int = 18
    ) -> Slot {
        Slot(
            id: "\(course.slug):2026-09-18:0616:1st-tee-social",
            courseSlug: course.slug,
            courseName: course.name,
            region: course.region,
            driveMinutesFromBondi: course.driveMinutesFromBondi,
            par: course.par,
            requiresRegistration: course.requiresRegistration,
            teeDate: "2026-09-18",
            teeTime: "06:16:00",
            teeAt: Date(timeIntervalSince1970: 1_789_000_000),
            spotsAvailable: 2,
            totalSpots: 4,
            holes: holes,
            priceMin: 48,
            priceMax: 48,
            priceTiers: [PriceTier(label: "Social", amount: 48)],
            bookingType: "1st Tee Social",
            bookingURLString: "https://\(course.host)/guests/bookings/x")
    }

    // MARK: - The full run

    /// Drive time first, because that is the filter golfers actually apply.
    func testTheFullMetaRunIsDriveTimeThenHolesThenRegion() {
        let model = TeesCourseHeader.Model(course: Self.course())

        XCTAssertEqual(model.metaSegments, ["32 min from Bondi", "18 holes", "Northern Beaches"])
        XCTAssertEqual(model.metaDescription, "32 min from Bondi · 18 holes · Northern Beaches")
    }

    // MARK: - Segments that drop

    /// `drive_minutes_from_bondi` is optional in the contract. When it is
    /// missing the segment goes, and so does the separator that was going to
    /// sit beside it — a leading "· 18 holes" is the bug this test exists for.
    func testANilDriveTimeDropsTheSegmentAndLeavesNoStraySeparator() {
        let model = TeesCourseHeader.Model(course: Self.course(driveMinutesFromBondi: nil))

        XCTAssertEqual(model.metaSegments, ["18 holes", "Northern Beaches"])
        XCTAssertFalse(model.metaDescription.contains("Bondi"))

        XCTAssertFalse(model.metaDescription.hasPrefix("·"), "no separator before the first segment")
        XCTAssertFalse(model.metaDescription.hasSuffix("·"), "no separator after the last")
        XCTAssertFalse(model.metaDescription.contains("· ·"), "no separator with nothing between")
        XCTAssertEqual(
            model.metaDescription.components(separatedBy: "·").count, 2,
            "two segments take exactly one separator: \(model.metaDescription)")
    }

    /// A club we have not filled a region in for sends an empty string, not a
    /// nil. It drops the same way, because a separator either side of nothing
    /// is the same dangling `·`.
    func testABlankRegionDropsToo() {
        let model = TeesCourseHeader.Model(course: Self.course(region: "   "))

        XCTAssertEqual(model.metaSegments, ["32 min from Bondi", "18 holes"])
        XCTAssertFalse(model.metaDescription.hasSuffix("·"))
        XCTAssertFalse(model.metaDescription.hasSuffix(" "))
    }

    /// Every source missing leaves no run at all, and nothing to draw a
    /// separator between.
    func testEverySegmentMissingLeavesAnEmptyRunRatherThanSeparators() {
        let model = TeesCourseHeader.Model(
            course: Self.course(region: "", holes: 0, driveMinutesFromBondi: nil))

        XCTAssertTrue(model.metaSegments.isEmpty)
        XCTAssertEqual(model.metaDescription, "")
        XCTAssertFalse(model.metaDescription.contains("·"))
    }

    // MARK: - The two initialisers

    /// The list groups by slot, so a header gets built from whichever of the
    /// two the caller has. The name and the registration marker are the facts
    /// both carry, and they must not disagree — a club that is "Warringah Golf
    /// Club" in one header and something else in the next reads as two clubs.
    func testModelFromSlotAndModelFromCourseAgreeOnNameAndRegistration() {
        for requiresRegistration in [true, false] {
            let course = Self.course(requiresRegistration: requiresRegistration)
            let fromCourse = TeesCourseHeader.Model(course: course)
            let fromSlot = TeesCourseHeader.Model(slot: Self.slot(from: course))

            XCTAssertEqual(fromSlot.name, fromCourse.name)
            XCTAssertEqual(fromSlot.name, "Warringah Golf Club")
            XCTAssertEqual(fromSlot.requiresRegistration, fromCourse.requiresRegistration)
            XCTAssertEqual(fromSlot.requiresRegistration, requiresRegistration)
        }
    }

    /// The drive time and region come off the slot exactly as they come off the
    /// course, because the slot payload carries both.
    func testModelFromSlotKeepsTheSegmentsTheSlotActuallyCarries() {
        let model = TeesCourseHeader.Model(slot: Self.slot(from: Self.course()))

        XCTAssertEqual(model.metaSegments, ["32 min from Bondi", "Northern Beaches"])
        XCTAssertFalse(model.metaDescription.hasSuffix("·"))
    }

    /// **`slot.holes` is THE BOOKING's hole count, not the club's**
    /// (`CONTRACT.md` §2). Three 18-hole courses sell 9-hole tee times, so a
    /// header built from a 9-hole booking must not label the club as a 9-hole
    /// course — which is why the slot initialiser carries no holes segment at
    /// all. Whichever booking happened to build the header, the answer is the
    /// same.
    func testAHeaderBuiltFromANineHoleBookingNeverLabelsTheClubNineHoles() {
        let course = Self.course(holes: 18)
        let fromNineHoleBooking = TeesCourseHeader.Model(slot: Self.slot(from: course, holes: 9))
        let fromEighteenHoleBooking = TeesCourseHeader.Model(slot: Self.slot(from: course, holes: 18))

        XCTAssertFalse(
            fromNineHoleBooking.metaDescription.contains("9 holes"),
            "the booking is 9 holes; the club is not: \(fromNineHoleBooking.metaDescription)")
        XCTAssertEqual(
            fromNineHoleBooking.metaSegments, fromEighteenHoleBooking.metaSegments,
            "the header must not change with the booking that happened to build it")
    }

    /// A nil drive time drops out of a slot-built header too.
    func testANilDriveTimeDropsFromASlotBuiltHeader() {
        let course = Self.course(driveMinutesFromBondi: nil)
        let model = TeesCourseHeader.Model(slot: Self.slot(from: course))

        XCTAssertEqual(model.metaSegments, ["Northern Beaches"])
        XCTAssertFalse(model.metaDescription.contains("·"))
    }

    // MARK: - Value semantics

    func testTwoModelsFromTheSameCourseAreEqual() {
        let course = Self.course()
        XCTAssertEqual(TeesCourseHeader.Model(course: course), TeesCourseHeader.Model(course: course))
        XCTAssertNotEqual(
            TeesCourseHeader.Model(course: course),
            TeesCourseHeader.Model(course: Self.course(name: "Bexley Golf Club")))
    }

    /// The header and the row draw their separator from one constant, so a
    /// results list cannot end up with a gold middot in the heading and a
    /// hyphen in the rows beneath it.
    func testTheHeaderAndTheRowShareOneSeparator() {
        let model = TeesCourseHeader.Model(course: Self.course())

        XCTAssertEqual(TeesSlotRow.Model.separator, "·")
        XCTAssertTrue(model.metaDescription.contains(" \(TeesSlotRow.Model.separator) "))
        XCTAssertFalse(model.metaDescription.contains(" - "), "the separator is the gold middot, not a hyphen")
    }

    /// A slot-built header says nothing about holes at all — not the booking's
    /// number, and not a guess at the club's. The word is simply absent,
    /// whichever booking built it.
    func testASlotBuiltHeaderNeverMentionsHolesAtAll() {
        for holes in [9, 18] {
            let model = TeesCourseHeader.Model(slot: Self.slot(from: Self.course(), holes: holes))
            XCTAssertFalse(
                model.metaDescription.lowercased().contains("hole"),
                "a \(holes)-hole booking put a hole count in the club's header: \(model.metaDescription)")
        }
    }
}

// MARK: - The day heading

/// `TeesDayHeading`'s formatting rules — the fourth component D3 shipped, and
/// the one that arrived with no tests at all. `TeesDayHeading.swift` says
/// "`TeesDayHeadingTests` can pin it"; there is no such file.
///
/// **Why this suite is in this file.** D3 owns four components and three test
/// files, and a day-heading test file is not one of them. Rather than create a
/// file outside the ticket, the suite lives beside the other heading
/// component; move it to `TeesDayHeadingTests.swift` when someone owns that
/// path.
///
/// Every test here pins the reference date, because "Today" is only "Today" on
/// one day and a suite that formats against `Date()` passes for twenty-four
/// hours and then tells you nothing.
final class TeesDayHeadingTests: XCTestCase {

    // MARK: - Fixtures

    /// The courses are all in Sydney and `tee_date` is their local calendar
    /// date, so this is the zone every one of these assertions is written in.
    private static let sydney = TimeZone(identifier: "Australia/Sydney") ?? .current

    private static let utc = TimeZone(identifier: "UTC") ?? .current

    /// A fixed instant, written the way a human would write it, offset and all.
    private static func instant(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else {
            preconditionFailure("\(iso) is not an ISO-8601 instant")
        }
        return date
    }

    private static func title(
        _ teeDate: String,
        _ reference: Date,
        _ timeZone: TimeZone = TeesDayHeadingTests.sydney
    ) -> String {
        TeesDayHeading.Model(teeDate: teeDate, reference: reference, timeZone: timeZone).title
    }

    /// 19 September 2026 is a Saturday. Every fixed date below is anchored to
    /// it.
    private static let saturdayMorning = TeesDayHeadingTests.instant("2026-09-19T09:00:00+10:00")

    // MARK: - Today, tomorrow, and then dates

    /// Days 0 and 1 are the two the scraper refreshes every twenty minutes and
    /// the two a golfer is nearly always looking at, so they get words. Day 2
    /// onwards gets a date.
    func testTodayAndTomorrowComeBeforeTheDatedDays() {
        XCTAssertEqual(Self.title("2026-09-19", Self.saturdayMorning), "Today")
        XCTAssertEqual(Self.title("2026-09-20", Self.saturdayMorning), "Tomorrow")
        XCTAssertEqual(Self.title("2026-09-21", Self.saturdayMorning), "Monday 21 September")
        XCTAssertEqual(Self.title("2026-09-24", Self.saturdayMorning), "Thursday 24 September")
    }

    /// **"Today" means today at the course.** At 23:00 UTC on the 19th it is
    /// already 09:00 on the 20th in Sydney. A golfer on a stopover — or anyone
    /// whose phone is on the wrong zone — must still see the Sydney day; a
    /// heading formatted against the device calendar says "Tomorrow" for a
    /// round they could play this morning.
    func testTodayIsTodayInSydneyNotWhereverThePhoneIs() {
        let reference = Self.instant("2026-09-19T23:00:00Z")

        XCTAssertEqual(Self.sydney.identifier, "Australia/Sydney", "the fixture zone did not load")
        XCTAssertEqual(Self.title("2026-09-20", reference, Self.sydney), "Today")
        XCTAssertEqual(
            Self.title("2026-09-20", reference, Self.utc), "Tomorrow",
            "the same instant read in another zone is a different day; if this also says Today the zone is being ignored")
    }

    /// And the zone a caller gets without asking is Sydney's, not the device's.
    func testTheDefaultZoneIsTheCoursesZone() {
        let reference = Self.instant("2026-09-19T23:00:00Z")

        XCTAssertEqual(TeesDayHeading.Model(teeDate: "2026-09-20", reference: reference).title, "Today")
        XCTAssertEqual(TeesDayHeading.Model.courseTimeZone.identifier, "Australia/Sydney")
    }

    /// The heading turns over at midnight in Sydney, not twenty-four hours
    /// after whatever time it happens to be. An offset measured between two
    /// instants rather than two midnights calls tomorrow "Today" all evening.
    func testTheHeadingTurnsOverAtMidnightNotTwentyFourHoursOut() {
        let lateSaturday = Self.instant("2026-09-19T23:59:00+10:00")
        XCTAssertEqual(Self.title("2026-09-19", lateSaturday), "Today")
        XCTAssertEqual(
            Self.title("2026-09-20", lateSaturday), "Tomorrow",
            "one minute before midnight, tomorrow is still tomorrow")

        let earlySunday = Self.instant("2026-09-20T00:01:00+10:00")
        XCTAssertEqual(
            Self.title("2026-09-20", earlySunday), "Today",
            "one minute after midnight, tomorrow has become today")
        XCTAssertEqual(Self.title("2026-09-19", earlySunday), "Saturday 19 September")
    }

    /// A day that has been and gone is named, never "Yesterday" and never
    /// silently "Today". The list only ever holds days 0-5, so a past heading
    /// means the payload or the clock is wrong, and printing the date is what
    /// makes that visible instead of plausible.
    func testAPastDayIsNamedAndNeverSaysTodayOrTomorrow() {
        for (teeDate, expected) in [
            ("2026-09-18", "Friday 18 September"),
            ("2026-09-12", "Saturday 12 September"),
            ("2026-08-31", "Monday 31 August"),
        ] {
            let title = Self.title(teeDate, Self.saturdayMorning)
            XCTAssertEqual(title, expected)
            XCTAssertNotEqual(title, "Today")
            XCTAssertNotEqual(title, "Tomorrow")
        }
    }

    // MARK: - The name tables

    /// `weekdayNames` is indexed by `Calendar`'s weekday, which is 1 for
    /// Sunday, not 0 and not Monday. Off by one and every heading in the app
    /// names the wrong day — plausibly, which is the worst kind of wrong.
    func testTheWeekdayNamesLineUpWithTheCalendar() {
        let farBack = Self.instant("2020-01-01T00:00:00+11:00")
        let week = [
            ("2026-09-20", "Sunday 20 September"),
            ("2026-09-21", "Monday 21 September"),
            ("2026-09-22", "Tuesday 22 September"),
            ("2026-09-23", "Wednesday 23 September"),
            ("2026-09-24", "Thursday 24 September"),
            ("2026-09-25", "Friday 25 September"),
            ("2026-09-26", "Saturday 26 September"),
        ]

        for (teeDate, expected) in week {
            XCTAssertEqual(Self.title(teeDate, farBack), expected)
        }
        XCTAssertEqual(TeesDayHeading.Model.weekdayNames.count, 7)
        XCTAssertEqual(TeesDayHeading.Model.weekdayNames.first, "Sunday")
    }

    /// And the month table, which is indexed from 1 and stored from 0. A
    /// December tee time reading "November" is the same class of bug.
    func testEveryMonthNameIsTheRightWayRound() {
        let farBack = Self.instant("2020-01-01T00:00:00+11:00")
        let months = [
            ("2026-01-15", "Thursday 15 January"),
            ("2026-02-15", "Sunday 15 February"),
            ("2026-03-15", "Sunday 15 March"),
            ("2026-04-15", "Wednesday 15 April"),
            ("2026-05-15", "Friday 15 May"),
            ("2026-06-15", "Monday 15 June"),
            ("2026-07-15", "Wednesday 15 July"),
            ("2026-08-15", "Saturday 15 August"),
            ("2026-09-15", "Tuesday 15 September"),
            ("2026-10-15", "Thursday 15 October"),
            ("2026-11-15", "Sunday 15 November"),
            ("2026-12-15", "Tuesday 15 December"),
        ]

        for (teeDate, expected) in months {
            XCTAssertEqual(Self.title(teeDate, farBack), expected)
        }
        XCTAssertEqual(TeesDayHeading.Model.monthNames.count, 12)
    }

    /// The names are the app's own, not the device's. A `DateFormatter` reads
    /// the phone's locale, so the same tee date would head one golfer's list
    /// "Saturday 20 September" and another's "土曜日" — and the assertion above
    /// would be testing the simulator's settings rather than the app.
    func testTheDayAndMonthNamesAreEnglishRegardlessOfTheDevice() {
        let title = Self.title("2026-09-26", Self.saturdayMorning)

        XCTAssertEqual(title, "Saturday 26 September")
        XCTAssertTrue(
            title.allSatisfy { $0.isASCII },
            "a localised formatter has leaked into the heading: \(title)")
    }

    // MARK: - Sydney moves its clocks

    /// Sydney changes offset twice a year (`CONTRACT.md` §4) and one of those
    /// days is 23 hours long, the other 25. "Tomorrow" is a calendar fact, not
    /// 86,400 seconds: an offset computed by dividing an interval gets one of
    /// these two wrong every year.
    func testDaylightSavingDoesNotShiftTheHeadingByADay() {
        // Clocks forward on 4 October 2026: the 4th is 23 hours long.
        let beforeForward = Self.instant("2026-10-03T12:00:00+10:00")
        XCTAssertEqual(Self.title("2026-10-03", beforeForward), "Today")
        XCTAssertEqual(Self.title("2026-10-04", beforeForward), "Tomorrow")
        XCTAssertEqual(Self.title("2026-10-05", beforeForward), "Monday 5 October")

        // Clocks back on 5 April 2026: the 5th is 25 hours long.
        let beforeBack = Self.instant("2026-04-04T12:00:00+11:00")
        XCTAssertEqual(Self.title("2026-04-04", beforeBack), "Today")
        XCTAssertEqual(Self.title("2026-04-05", beforeBack), "Tomorrow")
        XCTAssertEqual(Self.title("2026-04-06", beforeBack), "Monday 6 April")
    }

    // MARK: - Dates that are not dates

    /// A string that is not a date falls back to itself. A results list with a
    /// raw `2026-13-05` in one heading is readable and obviously wrong; one
    /// that has dropped the heading, or rolled month 13 into next January, is
    /// neither.
    func testAStringThatIsNotADateFallsBackToItself() {
        for raw in [
            "not a date", "2026-13-05", "2026-00-10", "2026-09-00",
            "26-09-20", "2026/09/20", "2026-09", "2026-09-20T06:16:00",
        ] {
            XCTAssertEqual(
                Self.title(raw, Self.saturdayMorning), raw,
                "\"\(raw)\" should be handed back untouched, not interpreted")
        }
    }

    /// **A known defect, recorded rather than left to be rediscovered.**
    ///
    /// `Model.parse` range-checks the day against 1...31 but never against the
    /// month, and the heading it prints takes the day and month from the raw
    /// string while taking the weekday from whatever date `Calendar` rolled the
    /// impossible one into. So `2026-09-31` — September has 30 days — heads a
    /// list "Thursday 31 September", and `2026-02-30` reads "Monday 30
    /// February": a confident, plausible-looking heading for a day that has
    /// never existed, which is the exact failure the month-13 guard beside it
    /// was written to prevent.
    ///
    /// Not reachable from the contract today, because `tee_date` comes out of a
    /// Postgres `date` column. It is reachable from a hand-built payload or a
    /// fixture, and the fix is one line: validate the components against the
    /// calendar, or read the day and month back off the resolved date instead
    /// of the raw string.
    ///
    /// Non-strict, so it goes green the moment someone fixes it rather than
    /// swapping one red for another.
    func testADateThatDoesNotExistShouldNotRenderAsAConfidentHeading() {
        XCTExpectFailure(
            "TeesDayHeading.Model.parse does not check the day against the month; 2026-09-31 renders as \"Thursday 31 September\"",
            strict: false)

        XCTAssertEqual(Self.title("2026-09-31", Self.saturdayMorning), "2026-09-31")
        XCTAssertEqual(Self.title("2026-02-30", Self.saturdayMorning), "2026-02-30")
    }

    // MARK: - The default reference

    /// Every caller in the app uses the default, so the default has to be now —
    /// in Sydney. This is the one test that reads the clock, and it reads it
    /// once.
    func testTheDefaultReferenceIsNowAtTheCourse() throws {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.sydney
        let parts = calendar.dateComponents([.year, .month, .day], from: now)

        let today = String(
            format: "%04d-%02d-%02d",
            try XCTUnwrap(parts.year), try XCTUnwrap(parts.month), try XCTUnwrap(parts.day))

        XCTAssertEqual(TeesDayHeading.Model(teeDate: today).title, "Today", "for tee date \(today)")
    }
}
