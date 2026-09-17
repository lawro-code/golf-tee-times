import XCTest
@testable import TeesContract

/// These tests guard the frozen contract. Every one of them corresponds to a
/// property something downstream relies on — if one fails, the contract moved
/// and five tracks are now building on a different shape.
final class ContractTests: XCTestCase {

    private var sydney: TimeZone {
        TimeZone(identifier: "Australia/Sydney")!
    }

    // MARK: - Fixtures decode

    func testGoldenFixtureDecodesCleanly() throws {
        let payload = try ContractLoader.fixture("golden")
        XCTAssertEqual(payload.contractVersion, Contract.version)
        XCTAssertEqual(payload.courses.count, 15, "the roster is frozen at 15 courses")
        XCTAssertTrue(payload.issues.isEmpty, "a real scrape must decode without dropping rows: \(payload.issues)")
        XCTAssertGreaterThan(payload.slots.count, 500, "a live 5-day scrape of 15 courses is hundreds of slots")
    }

    func testMinimalFixtureDecodesCleanly() throws {
        let payload = try ContractLoader.fixture("minimal")
        XCTAssertEqual(payload.slots.count, 9)
        XCTAssertEqual(payload.courses.count, 15)
        XCTAssertTrue(payload.issues.isEmpty)
    }

    // MARK: - Slot identity

    func testSlotIDsAreUniqueAndWellFormed() throws {
        let payload = try ContractLoader.fixture("golden")
        let ids = Set(payload.slots.map(\.id))
        XCTAssertEqual(ids.count, payload.slots.count, "slot ids must be unique — exactly-once push depends on it")

        for slot in payload.slots {
            let parts = slot.id.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            XCTAssertEqual(parts.count, 4, "id \(slot.id) is not course:date:HHMM:tee")
            XCTAssertEqual(String(parts[0]), slot.courseSlug)
            XCTAssertEqual(String(parts[1]), slot.teeDate)
            let hhmm = String(slot.teeTime.prefix(2)) + String(slot.teeTime.dropFirst(3).prefix(2))
            XCTAssertEqual(String(parts[2]), hhmm)
        }
    }

    /// Warringah and Bexley run two-tee starts: a 1st Tee and a 10th Tee group
    /// go out at the same minute and are two separate bookings. Keying a slot
    /// on time alone silently halves those courses' inventory.
    func testTwoTeeStartsAreTwoDistinctSlots() throws {
        let payload = try ContractLoader.fixture("minimal")
        let sameMinute = payload.slots.filter {
            $0.courseSlug == "warringah" && $0.teeDate == "2026-10-03" && $0.teeTime == "06:16:00"
        }
        XCTAssertEqual(sameMinute.count, 2)
        XCTAssertEqual(Set(sameMinute.map(\.id)).count, 2)
        XCTAssertEqual(Set(sameMinute.map(\.bookingType)), ["1st Tee Social", "10th Tee Social"])
    }

    // MARK: - Time

    /// teeAt is resolved once, on the server, in Australia/Sydney. The client
    /// must never recompute it — but it can check that it agrees.
    func testTeeAtAgreesWithLocalDateAndTime() throws {
        let payload = try ContractLoader.fixture("golden")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sydney

        for slot in payload.slots.prefix(400) {
            let parts = slot.teeTime.split(separator: ":").compactMap { Int($0) }
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: slot.teeAt)
            XCTAssertEqual(components.hour, parts[0], "hour drifted for \(slot.id)")
            XCTAssertEqual(components.minute, parts[1], "minute drifted for \(slot.id)")

            let dateParts = slot.teeDate.split(separator: "-").compactMap { Int($0) }
            XCTAssertEqual(components.year, dateParts[0], "year drifted for \(slot.id)")
            XCTAssertEqual(components.month, dateParts[1], "month drifted for \(slot.id)")
            XCTAssertEqual(components.day, dateParts[2], "day drifted for \(slot.id)")
        }
    }

    /// Sydney puts the clocks forward on 4 October 2026. A slot on the 3rd and
    /// a slot on the 4th are an hour apart in offset, and both have to be right.
    func testDaylightSavingBoundary() throws {
        let payload = try ContractLoader.fixture("minimal")
        let before = try XCTUnwrap(payload.slots.first { $0.id == "woollahra:2026-10-03:0712:public-play" })
        let after = try XCTUnwrap(payload.slots.first { $0.id == "woollahra:2026-10-04:1630:public-bookings" })

        XCTAssertEqual(sydney.secondsFromGMT(for: before.teeAt), 10 * 3600, "3 October is AEST, +10")
        XCTAssertEqual(sydney.secondsFromGMT(for: after.teeAt), 11 * 3600, "4 October is AEDT, +11")
    }

    // MARK: - Holes

    /// Three 18-hole courses also sell 9-hole tee times, and the only place
    /// that is said is the booking type or the fee label. Holes defaults to 18
    /// in the app's filters, so getting this wrong shows a golfer 9 holes when
    /// they asked for 18.
    func testNineHoleBookingOnAnEighteenHoleCourse() throws {
        let payload = try ContractLoader.fixture("minimal")
        let nine = try XCTUnwrap(payload.slots.first { $0.id == "bankstown:2026-10-03:1120:social-play-9-holes-only" })
        let eighteen = try XCTUnwrap(payload.slots.first { $0.id == "bankstown:2026-10-10:0800:social-play" })
        let course = try XCTUnwrap(payload.courses.first { $0.slug == "bankstown" })

        XCTAssertEqual(course.holes, 18)
        XCTAssertEqual(nine.holes, 9, "the fee label says 9 holes; the course says 18")
        XCTAssertEqual(eighteen.holes, 18)
    }

    func testGoldenCarriesBothHoleCounts() throws {
        let payload = try ContractLoader.fixture("golden")
        let counts = Set(payload.slots.map(\.holes))
        XCTAssertEqual(counts, [9, 18], "holes is always 9 or 18, never anything else")
    }

    // MARK: - Price

    /// About one slot in six publishes no price at all. That is ordinary data,
    /// not an error, and a price filter must not silently drop it.
    func testSlotsWithNoPublishedPrice() throws {
        let payload = try ContractLoader.fixture("minimal")
        let unpriced = payload.slots.filter(\.priceIsUnknown)
        XCTAssertFalse(unpriced.isEmpty)
        for slot in unpriced {
            XCTAssertNil(slot.priceMin)
            XCTAssertNil(slot.priceMax)
            XCTAssertTrue(slot.priceTiers.isEmpty)
        }
    }

    func testPriceBoundsMatchTheTiers() throws {
        let payload = try ContractLoader.fixture("golden")
        for slot in payload.slots {
            let amounts = slot.priceTiers.map(\.amount)
            if amounts.isEmpty {
                XCTAssertNil(slot.priceMin, "\(slot.id) has bounds but no tiers")
            } else {
                let low = try XCTUnwrap(slot.priceMin, "\(slot.id) has tiers but no price_min")
                let high = try XCTUnwrap(slot.priceMax, "\(slot.id) has tiers but no price_max")
                XCTAssertEqual(low, amounts.min()!, accuracy: 0.001, "\(slot.id)")
                XCTAssertEqual(high, amounts.max()!, accuracy: 0.001, "\(slot.id)")
            }
        }
    }

    // MARK: - Courses

    func testCourseLengthIsNeverInvented() throws {
        let payload = try ContractLoader.fixture("golden")
        XCTAssertTrue(payload.courses.allSatisfy { $0.lengthMetres == nil },
                      "MiClub does not publish course length; a value here means someone made one up")
    }

    func testExactlyOneCourseNeedsRegistration() throws {
        let payload = try ContractLoader.fixture("golden")
        let flagged = payload.courses.filter(\.requiresRegistration)
        XCTAssertEqual(flagged.map(\.slug), ["bayview"])
    }

    func testEverySlotBelongsToACourseOnTheRoster() throws {
        let payload = try ContractLoader.fixture("golden")
        let roster = Set(payload.courses.map(\.slug))
        for slot in payload.slots {
            XCTAssertTrue(roster.contains(slot.courseSlug), "\(slot.id) references an unknown course")
        }
    }

    // MARK: - Scrape health

    func testCourseDaysDistinguishFailureFromEmptiness() throws {
        let payload = try ContractLoader.fixture("minimal")
        let failed = payload.courseDays.filter { !$0.ok }
        XCTAssertFalse(failed.isEmpty, "the fixture carries a club that failed outright")
        for day in failed {
            XCTAssertNotNil(day.error)
            XCTAssertNil(day.lastSuccessAt, "a failed day cannot claim a successful scrape time")
        }

        let empty = payload.courseDays.filter { $0.ok && $0.slotCount == 0 }
        XCTAssertFalse(empty.isEmpty, "the fixture carries a club that scraped fine with nothing free")
        for day in empty {
            XCTAssertNil(day.error)
            XCTAssertNotNil(day.lastSuccessAt)
        }
    }

    // MARK: - Decoding survives bad data

    func testOneMalformedSlotDoesNotLoseThePayload() throws {
        let json = """
        {
          "contract_version": "1.0.0",
          "generated_at": "2026-10-01T07:30:00+10:00",
          "mode": "full",
          "days": 5,
          "courses": [],
          "course_days": [],
          "slots": [
            {"id":"a:2026-10-03:0800:t","course_slug":"a","course_name":"A","region":"","drive_minutes_from_bondi":10,"par":72,"length_metres":null,"requires_registration":false,"tee_date":"2026-10-03","tee_time":"08:00:00","tee_at":"2026-10-03T08:00:00+10:00","spots_available":4,"total_spots":4,"holes":18,"price_min":50,"price_max":50,"price_tiers":[{"label":"Adult","amount":50}],"booking_type":"1st Tee","booking_url":"https://example.test/a"},
            {"id":"broken","tee_date":"nonsense"},
            {"id":"b:2026-10-03:0900:t","course_slug":"b","course_name":"B","region":"","drive_minutes_from_bondi":10,"par":72,"length_metres":null,"requires_registration":false,"tee_date":"2026-10-03","tee_time":"09:00:00","tee_at":"2026-10-03T09:00:00+10:00","spots_available":2,"total_spots":4,"holes":18,"price_min":null,"price_max":null,"price_tiers":[],"booking_type":"1st Tee","booking_url":"https://example.test/b"}
          ]
        }
        """
        let payload = try ContractLoader.decode(Data(json.utf8))
        XCTAssertEqual(payload.slots.count, 2, "the two good slots survive")
        XCTAssertEqual(payload.issues.count, 1, "the bad one is recorded, not swallowed")
        XCTAssertEqual(payload.issues.first?.collection, "slots")
        XCTAssertEqual(payload.issues.first?.index, 1)
    }

    func testAPriceThatArrivesAsAStringStillDecodes() throws {
        let json = slotPayload(priceMin: "\"55.00\"", priceMax: "\"55.00\"")
        let payload = try ContractLoader.decode(Data(json.utf8))
        XCTAssertEqual(payload.slots.first?.priceMin, 55.0)
    }

    func testAMalformedBookingURLDoesNotCrash() throws {
        let json = slotPayload(bookingURL: "\"\"")
        let payload = try ContractLoader.decode(Data(json.utf8))
        let slot = try XCTUnwrap(payload.slots.first)
        XCTAssertNil(slot.bookingURL, "an empty booking url reads as no url, not as a crash")
        XCTAssertEqual(slot.bookingURLString, "")
    }

    func testAPayloadFromAnotherContractVersionIsRejected() {
        let json = slotPayload(version: "\"9.9.9\"")
        XCTAssertThrowsError(try ContractLoader.decode(Data(json.utf8))) { error in
            guard case ContractLoader.Failure.versionMismatch = error else {
                return XCTFail("expected a version mismatch, got \(error)")
            }
        }
    }

    func testEmptyPayloadIsValidNotAnError() throws {
        let json = """
        {"contract_version":"1.0.0","generated_at":"2026-10-01T07:30:00+10:00","mode":"fast","days":3,"courses":[],"slots":[],"course_days":[]}
        """
        let payload = try ContractLoader.decode(Data(json.utf8))
        XCTAssertTrue(payload.slots.isEmpty)
        XCTAssertTrue(payload.issues.isEmpty)
    }

    func testPayloadRoundTrips() throws {
        let original = try ContractLoader.fixture("minimal")
        let reencoded = try JSONEncoder().encode(original)
        let again = try ContractLoader.decode(reencoded)
        XCTAssertEqual(again.slots.map(\.id), original.slots.map(\.id))
        XCTAssertEqual(again.slots.map(\.teeAt), original.slots.map(\.teeAt))
        XCTAssertEqual(again.slots.map(\.holes), original.slots.map(\.holes))
        XCTAssertEqual(again.slots.map(\.priceMin), original.slots.map(\.priceMin))
    }

    // MARK: - Helper

    private func slotPayload(
        version: String = "\"1.0.0\"",
        priceMin: String = "50",
        priceMax: String = "50",
        bookingURL: String = "\"https://example.test/a\""
    ) -> String {
        """
        {
          "contract_version": \(version),
          "generated_at": "2026-10-01T07:30:00+10:00",
          "mode": "full",
          "days": 5,
          "courses": [],
          "course_days": [],
          "slots": [
            {"id":"a:2026-10-03:0800:t","course_slug":"a","course_name":"A","region":"","drive_minutes_from_bondi":10,"par":72,"length_metres":null,"requires_registration":false,"tee_date":"2026-10-03","tee_time":"08:00:00","tee_at":"2026-10-03T08:00:00+10:00","spots_available":4,"total_spots":4,"holes":18,"price_min":\(priceMin),"price_max":\(priceMax),"price_tiers":[{"label":"Adult","amount":50}],"booking_type":"1st Tee","booking_url":\(bookingURL)}
          ]
        }
        """
    }
}
