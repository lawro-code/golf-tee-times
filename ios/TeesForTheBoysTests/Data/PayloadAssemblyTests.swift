import XCTest
@testable import TeesData
import TeesContract

/// Rows shaped exactly the way PostgREST renders the views, so a test that
/// passes here is a test about the data and not about a convenient dictionary.
///
/// Every helper in the B tickets' shared test bundle is prefixed `B2`.
enum B2Rows {

    static func course(
        slug: String,
        name: String? = nil,
        holes: Int = 18,
        par: Int? = 72,
        sortOrder: Int = 0,
        requiresRegistration: Bool = false,
        overrides: [String: Any] = [:]
    ) -> [String: Any] {
        var row: [String: Any] = [
            "slug": slug,
            "name": name ?? "\(slug.capitalized) Golf Club",
            "region": "Eastern Suburbs",
            "host": "\(slug).miclub.com.au",
            "fee_group_id": "3050666",
            "holes": holes,
            "par": par.map { $0 as Any } ?? NSNull(),
            "length_metres": NSNull(),
            "drive_minutes_from_bondi": 20,
            "requires_registration": requiresRegistration,
            "address": NSNull(),
            "notes": "",
            "sort_order": sortOrder,
            "active": true,
        ]
        for (key, value) in overrides { row[key] = value }
        return row
    }

    /// `teeAt` defaults to the `+10:00` spelling a fixture uses; pass the
    /// `+00:00`-with-fractional-seconds spelling to imitate Supabase.
    static func slot(
        courseSlug: String = "warringah",
        date: String = "2026-10-03",
        time: String = "06:16",
        tee: String = "1st-tee-social",
        bookingType: String = "1st Tee Social",
        teeAt: String? = nil,
        holes: Int = 18,
        priceMin: Any = NSNull(),
        priceMax: Any = NSNull(),
        priceTiers: [[String: Any]] = [],
        spots: Int = 2,
        totalSpots: Int = 4,
        lastSeenAt: String = "2026-10-01T07:30:00+10:00",
        overrides: [String: Any] = [:]
    ) -> [String: Any] {
        let hhmm = time.replacingOccurrences(of: ":", with: "")
        var row: [String: Any] = [
            "id": "\(courseSlug):\(date):\(hhmm):\(tee)",
            "course_slug": courseSlug,
            "course_name": "\(courseSlug.capitalized) Golf Club",
            "region": "Northern Beaches",
            "drive_minutes_from_bondi": 32,
            "par": 70,
            "length_metres": NSNull(),
            "requires_registration": false,
            "tee_date": date,
            "tee_time": "\(time):00",
            "tee_at": teeAt ?? "\(date)T\(time):00+10:00",
            "spots_available": spots,
            "total_spots": totalSpots,
            "holes": holes,
            "price_min": priceMin,
            "price_max": priceMax,
            "price_tiers": priceTiers,
            "booking_type": bookingType,
            "booking_url":
                "https://\(courseSlug).miclub.com.au/guests/bookings/ViewPublicTimesheet.msp?selectedDate=\(date)",
            "first_seen_at": lastSeenAt,
            "last_seen_at": lastSeenAt,
        ]
        for (key, value) in overrides { row[key] = value }
        return row
    }

    static func courseDay(
        courseSlug: String = "warringah",
        date: String = "2026-10-03",
        ok: Bool = true,
        slotCount: Int = 1,
        error: Any = NSNull(),
        lastAttemptAt: String = "2026-10-01T07:30:00+10:00",
        lastSuccessAt: Any = "2026-10-01T07:30:00+10:00"
    ) -> [String: Any] {
        [
            "course_slug": courseSlug,
            "tee_date": date,
            "ok": ok,
            "slot_count": slotCount,
            "error": error,
            "last_attempt_at": lastAttemptAt,
            "last_success_at": lastSuccessAt,
        ]
    }

    /// The bytes PostgREST would put on the wire for those rows.
    static func json(_ rows: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: rows)
    }

    static func rawRows(_ collection: String, _ rows: [Any]) throws -> RawRows {
        try RawRows(collection: collection, json: try json(rows))
    }

    /// The fifteen-course roster, near enough: the count is what matters when
    /// the question is "did one bad row take the other fourteen with it".
    static var fifteenCourses: [[String: Any]] {
        (0..<15).map { course(slug: "course-\($0)", sortOrder: $0) }
    }
}

/// The half of B2 that has to survive bad data.
///
/// Assembly reuses the Stage 0 decoder rather than carrying its own, so these
/// tests double as proof that the frozen leniency is actually reached from the
/// live read path — the `price_min: "55.00"` case is worth nothing if the
/// network path quietly bypasses it.
final class PayloadAssemblyTests: XCTestCase {

    private func assemble(
        courses: [Any] = B2Rows.fifteenCourses,
        slots: [Any] = [],
        courseDays: [Any] = [],
        mode: ContractPayload.Mode = .full,
        days: Int = 5,
        contractVersion: String = Contract.version,
        now: Date = Date(timeIntervalSince1970: 1_790_000_000)
    ) throws -> ContractPayload {
        try PayloadAssembly.payload(
            courses: try B2Rows.rawRows("courses", courses),
            slots: try B2Rows.rawRows("slots", slots),
            courseDays: try B2Rows.rawRows("course_days", courseDays),
            mode: mode,
            days: days,
            contractVersion: contractVersion,
            generatedAt: nil,
            now: now)
    }

    // MARK: - One bad row does not blank the rest

    /// CONTRACT.md's rule, and the reason this ticket exists: one club changing
    /// its HTML must not blank out the other fourteen.
    func testOneCorruptCourseStillYieldsTheOtherFourteen() throws {
        var courses = B2Rows.fifteenCourses
        courses[7].removeValue(forKey: "slug")

        let payload = try assemble(courses: courses)

        XCTAssertEqual(payload.courses.count, 14, "fourteen good rows must survive one bad one")
        XCTAssertEqual(payload.issues.count, 1, "exactly one row was bad: \(payload.issues)")
        XCTAssertEqual(payload.issues.first?.collection, "courses")
        XCTAssertEqual(payload.issues.first?.index, 7, "the issue names the row that failed")
        XCTAssertFalse(payload.courses.contains { $0.slug.isEmpty })
    }

    func testACorruptSlotDropsOnlyItself() throws {
        let slots: [Any] = [
            B2Rows.slot(time: "06:16"),
            B2Rows.slot(time: "06:24", overrides: ["tee_at": "not a timestamp"]),
            B2Rows.slot(time: "06:32"),
            "this row is not even an object",
        ]

        let payload = try assemble(slots: slots)

        XCTAssertEqual(payload.slots.count, 2)
        XCTAssertEqual(payload.issues.count, 2)
        XCTAssertEqual(Set(payload.issues.map(\.collection)), ["slots"])
        XCTAssertEqual(payload.issues.map(\.index), [1, 3])
    }

    func testACorruptCourseDayDropsOnlyItself() throws {
        let days: [Any] = [
            B2Rows.courseDay(courseSlug: "warringah"),
            B2Rows.courseDay(courseSlug: "bexley"),
            ["course_slug": "long-reef"],        // no tee_date, no last_attempt_at
        ]

        let payload = try assemble(courseDays: days)

        XCTAssertEqual(payload.courseDays.count, 2)
        XCTAssertEqual(payload.issues.map(\.collection), ["course_days"])
        XCTAssertEqual(payload.issues.first?.index, 2)
    }

    // MARK: - Prices

    /// 282 of the golden fixture's 1755 slots publish no fee. That is ordinary
    /// data, and a slot that loses its row here is inventory the app never
    /// shows.
    func testNullPriceIsOrdinaryDataNotAFailure() throws {
        let payload = try assemble(slots: [B2Rows.slot(priceMin: NSNull(), priceMax: NSNull())])

        XCTAssertEqual(payload.slots.count, 1)
        XCTAssertNil(payload.slots[0].priceMin)
        XCTAssertNil(payload.slots[0].priceMax)
        XCTAssertTrue(payload.slots[0].priceIsUnknown)
        XCTAssertTrue(payload.issues.isEmpty, "a null price is not an issue")
    }

    /// Postgres `numeric` reaches some clients as a string. Both spellings have
    /// to land on the same Double or a price filter behaves differently
    /// depending on which client library the row came through.
    func testNumericStringPriceDecodesToANumber() throws {
        let payload = try assemble(slots: [
            B2Rows.slot(time: "06:16", priceMin: "55.00", priceMax: "72.50"),
            B2Rows.slot(time: "06:24", priceMin: 55.0, priceMax: 72.5),
        ])

        XCTAssertEqual(payload.slots.count, 2)
        XCTAssertEqual(payload.slots[0].priceMin, 55.0)
        XCTAssertEqual(payload.slots[0].priceMax, 72.5)
        XCTAssertEqual(payload.slots[0].priceMin, payload.slots[1].priceMin)
        XCTAssertTrue(payload.issues.isEmpty)
    }

    func testPriceTiersSurviveWithTheirLabels() throws {
        let payload = try assemble(slots: [
            B2Rows.slot(priceMin: 25.0, priceMax: 55.0, priceTiers: [
                ["label": "Adult", "amount": 55.0],
                ["label": "Senior", "amount": 42.0],
                ["label": "Junior", "amount": "25.00"],
            ])
        ])

        XCTAssertEqual(payload.slots[0].priceTiers.count, 3)
        XCTAssertEqual(payload.slots[0].priceTiers.last?.amount, 25.0)
        XCTAssertEqual(payload.slots[0].priceTiers.map(\.label), ["Adult", "Senior", "Junior"])
    }

    // MARK: - Identity and holes

    /// Warringah sends a 1st Tee and a 10th Tee group out at the same minute.
    /// Collapsing them lost 141 of its 289 tee times before the contract froze.
    func testTwoTeeStartsAtTheSameMinuteStayTwoSlots() throws {
        let payload = try assemble(slots: [
            B2Rows.slot(time: "06:16", tee: "1st-tee-social", bookingType: "1st Tee Social"),
            B2Rows.slot(time: "06:16", tee: "10th-tee-social", bookingType: "10th Tee Social"),
        ])

        XCTAssertEqual(payload.slots.count, 2)
        XCTAssertEqual(Set(payload.slots.map(\.id)).count, 2, "the tee is part of the id")
        XCTAssertEqual(Set(payload.slots.map(\.teeTime)), ["06:16:00"])
        XCTAssertEqual(
            Set(payload.slots.map(\.bookingType)), ["1st Tee Social", "10th Tee Social"])
    }

    /// Bankstown, Beverley Park and Brighton Lakes are 18-hole courses that
    /// also sell 9-hole tee times. Holes defaults to 18 in the filters, so
    /// copying the course's count here shows a golfer 18 when they booked 9.
    func testNineHoleBookingOnAnEighteenHoleCourseKeepsNine() throws {
        let payload = try assemble(
            courses: [B2Rows.course(slug: "bankstown", holes: 18)],
            slots: [
                B2Rows.slot(courseSlug: "bankstown", time: "07:00", tee: "social-9", holes: 9),
                B2Rows.slot(courseSlug: "bankstown", time: "07:08", tee: "social", holes: 18),
            ])

        XCTAssertEqual(payload.courses.first?.holes, 18, "the course is still an 18-hole course")
        XCTAssertEqual(payload.slots.first(where: { $0.id.hasSuffix("social-9") })?.holes, 9)
        XCTAssertEqual(payload.slots.first(where: { $0.id.hasSuffix(":social") })?.holes, 18)
    }

    /// A URL the club typed badly is still a tee time worth showing; only the
    /// tap-through is lost. `booking_url` decodes to a String for exactly this
    /// reason — as a `URL` the row would fail and the tee time would vanish.
    func testMalformedBookingURLKeepsTheRow() throws {
        let payload = try assemble(slots: [
            B2Rows.slot(time: "06:16", tee: "a", overrides: ["booking_url": "https://%"]),
            B2Rows.slot(time: "06:24", tee: "b", overrides: ["booking_url": 12345]),
        ])

        XCTAssertEqual(payload.slots.count, 2, "neither row is lost to its url")
        XCTAssertTrue(payload.issues.isEmpty)
        XCTAssertEqual(payload.slots[0].bookingURLString, "https://%")
        XCTAssertNil(payload.slots[0].bookingURL, "unparseable, so there is nothing to tap through to")
        XCTAssertEqual(payload.slots[1].bookingURLString, "",
                       "a url that arrives as a number leaves the row intact and empty")
        XCTAssertNil(payload.slots[1].bookingURL)
    }

    // MARK: - Time

    /// Supabase returns `+00:00` with fractional seconds; a fixture carries
    /// `+10:00`. Both are the same instant and both have to parse.
    func testBothTimestampSpellingsParseToTheSameInstant() throws {
        let payload = try assemble(slots: [
            B2Rows.slot(time: "06:16", tee: "a", teeAt: "2026-10-02T20:16:00.123456+00:00"),
            B2Rows.slot(time: "06:16", tee: "b", teeAt: "2026-10-03T06:16:00+10:00"),
        ])

        XCTAssertEqual(payload.slots.count, 2, "both spellings decode")
        // Same instant, give or take the fractional seconds Supabase sends and
        // a fixture does not.
        XCTAssertEqual(
            payload.slots[0].teeAt.timeIntervalSince(payload.slots[1].teeAt),
            0.123456,
            accuracy: 0.0005)
    }

    // MARK: - generated_at

    /// The banner says how old the tee times are. Stamping `Date()` would make
    /// a six-hour-old scrape read as fresh the moment it downloaded.
    func testGeneratedAtIsTheNewestLastSeenAtNotNow() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let payload = try assemble(
            slots: [
                B2Rows.slot(time: "06:16", tee: "a", lastSeenAt: "2026-10-01T07:10:00+10:00"),
                B2Rows.slot(time: "06:24", tee: "b", lastSeenAt: "2026-10-01T07:30:00+10:00"),
                B2Rows.slot(time: "06:32", tee: "c", lastSeenAt: "2026-10-01T06:50:00+10:00"),
            ],
            now: now)

        XCTAssertEqual(ContractDate.date(from: payload.generatedAt),
                       ContractDate.date(from: "2026-10-01T07:30:00+10:00"))
        XCTAssertNotEqual(ContractDate.date(from: payload.generatedAt), now)
    }

    /// A course that scraped fine with nothing free still tells us when we
    /// looked, which is the whole point of `course_day_scrapes`.
    func testGeneratedAtFallsBackToTheScrapeAttemptWhenThereAreNoSlots() throws {
        let payload = try assemble(courseDays: [
            B2Rows.courseDay(courseSlug: "long-reef", ok: true, slotCount: 0,
                             lastAttemptAt: "2026-10-01T08:05:00+10:00",
                             lastSuccessAt: "2026-10-01T08:05:00+10:00")
        ])

        XCTAssertEqual(ContractDate.date(from: payload.generatedAt),
                       ContractDate.date(from: "2026-10-01T08:05:00+10:00"))
        XCTAssertTrue(payload.slots.isEmpty)
        XCTAssertEqual(payload.courseDays.first?.ok, true)
    }

    func testAnExplicitGeneratedAtWins() throws {
        let stamped = ContractDate.date(from: "2026-10-01T09:00:00+10:00")
        let payload = try PayloadAssembly.payload(
            courses: try B2Rows.rawRows("courses", B2Rows.fifteenCourses),
            slots: try B2Rows.rawRows("slots", [B2Rows.slot()]),
            courseDays: try B2Rows.rawRows("course_days", []),
            mode: .fast,
            days: 3,
            generatedAt: stamped)

        XCTAssertEqual(ContractDate.date(from: payload.generatedAt), stamped)
        XCTAssertEqual(payload.mode, .fast)
        XCTAssertEqual(payload.days, 3)
    }

    // MARK: - The one rejection

    /// A version mismatch is the only thing that throws the whole payload away.
    /// Half-understood data is worse than none.
    func testContractVersionMismatchRejectsTheWholePayload() throws {
        XCTAssertThrowsError(
            try assemble(slots: [B2Rows.slot()], contractVersion: "0.9.0")
        ) { error in
            XCTAssertEqual(
                error as? DataError,
                .contractVersionMismatch(expected: Contract.version, found: "0.9.0"))
        }
    }

    func testAPayloadDocumentWithTheWrongVersionIsRejected() throws {
        let document: [String: Any] = [
            "contract_version": "2.0.0",
            "generated_at": "2026-10-01T07:30:00+10:00",
            "mode": "full",
            "days": 5,
            "courses": [],
            "slots": [B2Rows.slot()],
            "course_days": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: document)

        XCTAssertThrowsError(try PayloadAssembly.decode(payloadJSON: data)) { error in
            XCTAssertEqual(
                error as? DataError,
                .contractVersionMismatch(expected: Contract.version, found: "2.0.0"))
        }
    }

    // MARK: - Broken responses, as opposed to broken rows

    func testABodyThatIsNotAnArrayIsARejectedResponse() throws {
        let body = Data(#"{"message":"permission denied for view open_slots"}"#.utf8)

        XCTAssertThrowsError(try RawRows(collection: "slots", json: body)) { error in
            guard case .decoding(let reason)? = error as? DataError else {
                return XCTFail("expected .decoding, got \(error)")
            }
            XCTAssertTrue(reason.contains("slots"), reason)
        }
    }

    func testEmptyCollectionsAreAPayloadNotAnError() throws {
        let payload = try assemble(courses: [], slots: [], courseDays: [])

        XCTAssertTrue(payload.courses.isEmpty)
        XCTAssertTrue(payload.slots.isEmpty)
        XCTAssertTrue(payload.issues.isEmpty)
        XCTAssertEqual(payload.contractVersion, Contract.version)
    }

    // MARK: - Pages

    func testAppendedPagesKeepTheirOrder() throws {
        var rows = RawRows(collection: "slots")
        rows.append(try B2Rows.rawRows("slots", [B2Rows.slot(time: "06:16", tee: "a")]))
        rows.append(try B2Rows.rawRows("slots", [B2Rows.slot(time: "06:24", tee: "b")]))

        XCTAssertEqual(rows.count, 2)
        let payload = try PayloadAssembly.payload(
            courses: RawRows(collection: "courses"),
            slots: rows,
            courseDays: RawRows(collection: "course_days"),
            mode: .full,
            days: 5)
        XCTAssertEqual(payload.slots.map(\.teeTime), ["06:16:00", "06:24:00"])
    }
}
