import XCTest
@testable import TeesPush
import TeesContract

/// Reading the `tees` object the alert sender puts in `userInfo`, and deciding
/// where a tap on it goes.
///
/// The payload in ``senderJSON`` is the one E2 emits, byte for byte. It is
/// parsed with `JSONSerialization` rather than written as a Swift dictionary
/// on purpose: that is what APNs hands over — `NSNumber` for a JSON number,
/// `NSDictionary` for a nested object — and a decoder tested against tidy
/// Swift literals is a decoder that has not been tested.
final class AlertPayloadTests: XCTestCase {

    private static let senderJSON = """
        {
          "aps": {
            "alert": { "title": "The Coast, Sunday 7:58am", "body": "3 tee times just opened" },
            "sound": "default",
            "thread-id": "watch:6f1c1f0e-0c2e-4f1a-9b0f-2f2a5d9c1a77",
            "interruption-level": "time-sensitive"
          },
          "tees": {
            "v": 1,
            "watch_id": "6f1c1f0e-0c2e-4f1a-9b0f-2f2a5d9c1a77",
            "slot_ids": ["the-coast:2026-09-20:0758:public-play"],
            "primary_slot_id": "the-coast:2026-09-20:0758:public-play",
            "course_slug": "the-coast",
            "course_name": "The Coast Golf Club",
            "tee_at": "2026-09-20T07:58:00+10:00",
            "count": 3
          }
        }
        """

    private let watchID = "6f1c1f0e-0c2e-4f1a-9b0f-2f2a5d9c1a77"
    private let slotID = "the-coast:2026-09-20:0758:public-play"

    // MARK: - Building a userInfo

    private func userInfo(
        json: String = AlertPayloadTests.senderJSON
    ) throws -> [AnyHashable: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [AnyHashable: Any])
    }

    /// The sender's payload with one key in `tees` changed or removed.
    private func userInfo(
        overriding key: String, with value: Any?
    ) throws -> [AnyHashable: Any] {
        var info = try userInfo()
        var tees = try XCTUnwrap(info["tees"] as? [String: Any])
        if let value { tees[key] = value } else { tees.removeValue(forKey: key) }
        info["tees"] = tees
        return info
    }

    // MARK: - The payload the sender actually emits

    func testTheSenderPayloadDecodesFieldForField() throws {
        let payload = try XCTUnwrap(AlertPayload.decode(userInfo: try userInfo()))

        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.watchID, watchID)
        XCTAssertEqual(payload.slotIDs, [slotID])
        XCTAssertEqual(payload.primarySlotID, slotID)
        XCTAssertEqual(payload.courseSlug, "the-coast")
        XCTAssertEqual(payload.courseName, "The Coast Golf Club")
        XCTAssertEqual(payload.count, 3)
        XCTAssertEqual(payload.issues, [])
    }

    /// `tee_at` is an instant, and `+10:00` is Sydney in September. The
    /// expected date is built from UTC components rather than parsed from a
    /// string, so this fails if the offset is ever dropped on the floor —
    /// which is exactly what a hand-rolled second date parser would do.
    func testTeeAtIsTheAbsoluteInstantNotTheWallClock() throws {
        let payload = try XCTUnwrap(AlertPayload.decode(userInfo: try userInfo()))

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let expected = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026, month: 9, day: 19, hour: 21, minute: 58, second: 0)))

        XCTAssertEqual(payload.teeAt, expected)
    }

    /// Supabase spells the same instant with a `+00:00` offset and fractional
    /// seconds. `ContractDate` reads both; this proves nothing in this module
    /// quietly assumes the fixture spelling.
    func testTheSupabaseSpellingOfTeeAtParsesToTheSameInstant() throws {
        let fixtureSpelling = try XCTUnwrap(
            AlertPayload.decode(userInfo: try userInfo()))
        let supabaseSpelling = try XCTUnwrap(AlertPayload.decode(
            userInfo: try userInfo(overriding: "tee_at", with: "2026-09-19T21:58:00.000+00:00")))

        XCTAssertEqual(fixtureSpelling.teeAt, supabaseSpelling.teeAt)
    }

    // MARK: - Routing

    /// The rule: one match opens the tee time, several open the watch.
    func testCountDecidesWhereTheTapLands() throws {
        let cases: [(count: Int, expected: PushRoute)] = [
            (0, .slot(id: slotID)),
            (1, .slot(id: slotID)),
            (2, .watch(id: watchID)),
            (5, .watch(id: watchID)),
            (47, .watch(id: watchID)),
        ]

        for test in cases {
            let payload = try XCTUnwrap(
                AlertPayload.decode(userInfo: try userInfo(overriding: "count", with: test.count)),
                "count \(test.count) should still decode")
            XCTAssertEqual(payload.route, test.expected, "count \(test.count)")
        }
    }

    func testRoutingDegradesWhenAnIdIsMissing() {
        let cases: [(name: String, watch: String?, primary: String?, count: Int, expected: PushRoute?)] = [
            ("watch only, one match", watchID, nil, 1, .watch(id: watchID)),
            ("watch only, five matches", watchID, nil, 5, .watch(id: watchID)),
            ("slot only, five matches", nil, slotID, 5, .slot(id: slotID)),
            ("slot only, one match", nil, slotID, 1, .slot(id: slotID)),
            ("neither", nil, nil, 3, nil),
            ("both empty strings", "", "  ", 1, nil),
        ]

        for test in cases {
            XCTAssertEqual(
                PushRoute.route(
                    watchID: test.watch, primarySlotID: test.primary, count: test.count),
                test.expected,
                test.name)
        }
    }

    func testAPayloadWithNoPrimarySlotRoutesToTheWatch() throws {
        let payload = try XCTUnwrap(AlertPayload.decode(
            userInfo: try userInfo(overriding: "primary_slot_id", with: nil)))

        XCTAssertEqual(payload.route, .watch(id: watchID))
    }

    // MARK: - What gets rejected, and why

    func testRejections() throws {
        let cases: [(name: String, info: [AnyHashable: Any], expected: AlertPayloadIssue)] = [
            ("somebody else's notification", ["aps": ["alert": "hello"]], .noTeesObject),
            ("tees is not an object", try userInfoReplacingTees(with: "nope"), .teesNotAnObject),
            ("no version", try userInfo(overriding: "v", with: nil), .missingVersion),
            ("a version from the future", try userInfo(overriding: "v", with: 2),
             .unsupportedVersion(2)),
            ("no tee_at", try userInfo(overriding: "tee_at", with: nil),
             .missingField("tee_at")),
            ("no count", try userInfo(overriding: "count", with: nil), .missingField("count")),
        ]

        for test in cases {
            switch AlertPayload.read(userInfo: test.info) {
            case .success:
                XCTFail("\(test.name) should have been rejected")
            case .failure(let issue):
                XCTAssertEqual(issue, test.expected, test.name)
            }
            XCTAssertNil(AlertPayload.decode(userInfo: test.info), test.name)
        }
    }

    /// A `v` we do not know is ignored, not guessed at. The rest of the object
    /// is deliberately left readable to prove the rejection is the version and
    /// not something else in the payload.
    func testAnUnknownVersionIsIgnoredRatherThanInterpreted() throws {
        let info = try userInfo(overriding: "v", with: 99)

        XCTAssertNil(AlertPayload.decode(userInfo: info))
        XCTAssertNil(AlertPayload.decode(userInfo: info)?.route)
    }

    // MARK: - What survives with an issue recorded

    func testAnEmptySlotIDsArrayStillDecodes() throws {
        let payload = try XCTUnwrap(AlertPayload.decode(
            userInfo: try userInfo(overriding: "slot_ids", with: [String]())))

        XCTAssertEqual(payload.slotIDs, [])
        XCTAssertEqual(payload.issues, [])
        // Count, not the array, is what routing turns on.
        XCTAssertEqual(payload.route, .watch(id: watchID))
    }

    /// The confirmed defect: a malformed `tee_at` used to reject the whole
    /// payload even though routing never reads `tee_at` — only `watch_id`,
    /// `primary_slot_id` and `count`, all of which can be perfectly valid
    /// alongside a `tee_at` a sender rendered wrong. Both shapes here are what
    /// a Postgres `date` cast, or a timestamp template missing its offset,
    /// actually produce.
    func testAMalformedTeeAtIsAnIssueNotARejectionAndTheTapStillRoutes() throws {
        for badTeeAt in ["2026-09-20", "2026-09-20 07:58:00"] {
            let payload = try XCTUnwrap(
                AlertPayload.decode(userInfo: try userInfo(overriding: "tee_at", with: badTeeAt)),
                "tee_at \(badTeeAt) should still decode")

            XCTAssertNil(payload.teeAt, "tee_at \(badTeeAt)")
            XCTAssertEqual(
                payload.issues, [.malformedField(name: "tee_at", value: badTeeAt)],
                "tee_at \(badTeeAt)")
            XCTAssertEqual(payload.route, .watch(id: watchID), "tee_at \(badTeeAt)")
        }
    }

    func testAMissingCourseNameIsAnIssueNotARejection() throws {
        let payload = try XCTUnwrap(AlertPayload.decode(
            userInfo: try userInfo(overriding: "course_name", with: nil)))

        XCTAssertEqual(payload.courseName, "")
        XCTAssertEqual(payload.issues, [.missingField("course_name")])
        XCTAssertEqual(payload.route, .watch(id: watchID))
    }

    func testAMalformedSlotIDsArrayIsAnIssueNotARejection() throws {
        let payload = try XCTUnwrap(AlertPayload.decode(
            userInfo: try userInfo(overriding: "slot_ids", with: "not-an-array")))

        XCTAssertEqual(payload.slotIDs, [])
        XCTAssertEqual(payload.issues.count, 1)
        XCTAssertEqual(payload.route, .watch(id: watchID))
    }

    /// Some senders and some test doubles spell a number as a string. Reading
    /// it is free; refusing it costs a tap.
    func testACountSpelledAsAStringIsStillANumber() throws {
        let payload = try XCTUnwrap(AlertPayload.decode(
            userInfo: try userInfo(overriding: "count", with: "1")))

        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload.route, .slot(id: slotID))
    }

    // MARK: -

    private func userInfoReplacingTees(with value: Any) throws -> [AnyHashable: Any] {
        var info = try userInfo()
        info["tees"] = value
        return info
    }

    // MARK: - Fields that are present but not usable

    /// A blank id is not an id. The sender can emit one — an empty column
    /// serialises as `""` — and a route to `.slot(id: "  ")` opens a screen
    /// that can find nothing, which is worse than falling back to the watch.
    func testABlankPrimarySlotIDFallsBackToTheWatch() throws {
        let payload = try XCTUnwrap(AlertPayload.decode(
            userInfo: try userInfo(overriding: ["primary_slot_id": "   ", "count": 1])))

        XCTAssertNil(payload.primarySlotID)
        XCTAssertEqual(payload.route, .watch(id: watchID))
    }

    /// A payload with nothing usable to open goes nowhere at all rather than
    /// somewhere wrong.
    func testAPayloadWhoseIdsAreAllBlankRoutesNowhere() throws {
        let payload = try XCTUnwrap(AlertPayload.decode(userInfo: try userInfo(
            overriding: ["primary_slot_id": "", "watch_id": " ", "count": 1])))

        XCTAssertNil(payload.watchID)
        XCTAssertNil(payload.primarySlotID)
        XCTAssertNil(payload.route)
    }

    /// Missing and unreadable are different, and the reason is the only record
    /// of why a push went nowhere. A `v` of `"one"` is a sender bug; a `v`
    /// that is absent is an older sender. Reporting the first as the second
    /// sends whoever debugs it looking in the wrong place.
    func testAFieldThatIsPresentButUnreadableIsMalformedNotMissing() throws {
        let cases: [(name: String, info: [AnyHashable: Any], expected: AlertPayloadIssue)] = [
            ("a version that is not a number", try userInfo(overriding: "v", with: "one"),
             .malformedField(name: "v", value: "one")),
            ("a count that is not a number", try userInfo(overriding: "count", with: "several"),
             .malformedField(name: "count", value: "several")),
        ]

        for test in cases {
            switch AlertPayload.read(userInfo: test.info) {
            case .success:
                XCTFail("\(test.name) should have been rejected")
            case .failure(let issue):
                XCTAssertEqual(issue, test.expected, test.name)
            }
        }
    }

    /// One bad element does not throw away the payload, and the drop is
    /// recorded rather than silent — the same two tiers the contract decoder
    /// uses when one course row is unreadable.
    func testASlotIDsArrayWithANonStringInItKeepsTheStringsAndSaysSo() throws {
        let payload = try XCTUnwrap(AlertPayload.decode(
            userInfo: try userInfo(overriding: "slot_ids", with: [slotID, 7])))

        XCTAssertEqual(payload.slotIDs, [slotID])
        guard case .malformedField(let name, _)? = payload.issues.first else {
            return XCTFail("the dropped element should be recorded, not swallowed")
        }
        XCTAssertEqual(name, "slot_ids")
        XCTAssertEqual(payload.issues.count, 1)
        XCTAssertEqual(payload.route, .watch(id: watchID))
    }

    /// APNs hands the payload over as a Foundation dictionary, and a nested
    /// object can arrive as an `NSDictionary` that will not cast to
    /// `[String: Any]` if anything in it is keyed on something else. Refusing
    /// it would throw away a payload whose own fields are perfectly readable.
    func testATeesObjectThatWillNotCastToAStringKeyedDictionaryIsStillRead() throws {
        var info = try userInfo()
        let tees = try XCTUnwrap(info["tees"] as? [String: Any])
        var loose: [AnyHashable: Any] = [:]
        for (key, value) in tees { loose[key] = value }
        loose[7] = "a key that is not a string"
        info["tees"] = loose

        let payload = try XCTUnwrap(AlertPayload.decode(userInfo: info))

        XCTAssertEqual(payload.primarySlotID, slotID)
        XCTAssertEqual(payload.count, 3)
        XCTAssertEqual(payload.issues, [])
    }

    /// The sender's payload with several keys in `tees` changed or removed.
    private func userInfo(overriding values: [String: Any?]) throws -> [AnyHashable: Any] {
        var info = try userInfo()
        var tees = try XCTUnwrap(info["tees"] as? [String: Any])
        for (key, value) in values {
            if let value { tees[key] = value } else { tees.removeValue(forKey: key) }
        }
        info["tees"] = tees
        return info
    }
}
