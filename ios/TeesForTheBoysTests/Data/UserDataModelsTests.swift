import XCTest
@testable import TeesData
import TeesContract
import Supabase

// MARK: - The harness this ticket's repository tests share

/// Canned PostgREST responses for the user-owned tables.
///
/// **Nothing in these tests touches a hosted Supabase project.** Every byte the
/// SDK sees comes from here, and the point of the stub is as much what it
/// records as what it serves: the request body and the query string are the
/// thing under test, because they are what the frozen schema will accept or
/// reject.
///
/// All four B tickets compile into one test bundle, so every test-only type in
/// this ticket is prefixed `B4`.
final class B4StubURLProtocol: URLProtocol {

    /// One request as it went out, with its body already drained.
    struct Sent: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?

        var path: String { url.path }
        var table: String { url.lastPathComponent }

        /// The body as JSON, which is how every assertion here reads it.
        var json: [String: Any]? {
            guard let body, let parsed = try? JSONSerialization.jsonObject(with: body) else {
                return nil
            }
            if let object = parsed as? [String: Any] { return object }
            // PostgREST takes a single-row insert as a one-element array.
            return (parsed as? [[String: Any]])?.first
        }

        func query(_ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == name }?.value
        }

        func queries(_ name: String) -> [String] {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
        }

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    typealias Responder = (Sent) -> (status: Int, body: Data)

    private static let box = B4StubBox()

    /// Serve the same body to everything. Enough for most of these tests: the
    /// assertion is on what went out, not on what came back.
    static func respond(status: Int = 200, json: String) {
        let body = Data(json.utf8)
        box.set { _ in (status: status, body: body) }
    }

    static func respond(_ responder: @escaping Responder) {
        box.set(responder)
    }

    /// Fail every request the way a dropped connection does.
    ///
    /// "The network went away" and "the server said no" are different failures
    /// and the UI branches on the difference — one gets a retry button, the
    /// other does not — so a test has to be able to produce both.
    static func fail(with code: URLError.Code) {
        box.set(failure: URLError(code))
    }

    static var sent: [Sent] { box.sent }

    static func sent(to table: String) -> [Sent] {
        sent.filter { $0.table == table }
    }

    static func reset() { box.reset() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let sent = Sent(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request))

        switch Self.box.record(sent) {
        case .none:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .respond(let responder):
            let (status, body) = responder(sent)
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// `URLSession` hands a `URLProtocol` the body as a stream, not as
    /// `httpBody`. Reading only `httpBody` is the classic way to write a test
    /// that asserts nothing at all.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// The stub's shared state behind a lock: `URLProtocol` runs on whichever
/// thread the session hands it.
final class B4StubBox: @unchecked Sendable {

    /// What the stub does with the next request: answer it, or fail below HTTP.
    enum Outcome {
        case respond(B4StubURLProtocol.Responder)
        case fail(URLError)
    }

    private let lock = NSLock()
    private var outcome: Outcome?
    private var requests: [B4StubURLProtocol.Sent] = []

    func set(_ responder: @escaping B4StubURLProtocol.Responder) {
        lock.lock(); defer { lock.unlock() }
        outcome = .respond(responder)
        requests = []
    }

    func set(failure: URLError) {
        lock.lock(); defer { lock.unlock() }
        outcome = .fail(failure)
        requests = []
    }

    func record(_ sent: B4StubURLProtocol.Sent) -> Outcome? {
        lock.lock(); defer { lock.unlock() }
        requests.append(sent)
        return outcome
    }

    var sent: [B4StubURLProtocol.Sent] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        outcome = nil
        requests = []
    }
}

/// Signed in, or not. The whole sign-in wall reduces to this one seam.
struct B4StubSession: SessionProviding {
    let userID: UUID?

    static let signedIn = B4StubSession(
        userID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    static let signedOut = B4StubSession(userID: nil)
    /// The mate who signs in on the same iPhone. Two people sharing a phone is
    /// ordinary for this app, and the push token key is built around it.
    static let mate = B4StubSession(
        userID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!)

    var currentUserID: UUID? { userID }

    func requireUserID() throws -> UUID {
        guard let userID else { throw DataError.notSignedIn }
        return userID
    }
}

/// A `SupabaseClient` wired to the stub and to nothing else.
enum B4Client {
    static func make() -> SupabaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [B4StubURLProtocol.self]
        return SupabaseClientProvider.client(
            configuration: SupabaseConfiguration(
                url: URL(string: "https://b4-stub.supabase.co")!, anonKey: "b4-anon-key"),
            session: URLSession(configuration: configuration))
    }
}

/// Values every file in this ticket's tests reaches for.
enum B4Fixtures {

    /// The signed-in user in these tests.
    static let userID = B4StubSession.signedIn.userID!

    /// 1 October 2026, 07:30 at the course. Three days before Sydney puts its
    /// clocks forward, which is the whole reason this date was picked.
    static let now = ContractDate.date(from: "2026-10-01T07:30:00+10:00")!

    /// A real-shaped slot: a two-tee start at Warringah, unpriced, the case
    /// CONTRACT.md #1 and #3 both describe.
    static func slot(
        id: String = "the-coast:2026-10-03:0800:1st-tee-social",
        courseSlug: String = "the-coast",
        teeDate: String = "2026-10-03",
        teeTime: String = "08:00:00",
        teeAt: String = "2026-10-03T08:00:00+10:00",
        holes: Int = 18,
        priceMin: Double? = 55,
        bookingURL: String = "https://thecoast.miclub.com.au/guests/bookings/x"
    ) -> Slot {
        Slot(
            id: id,
            courseSlug: courseSlug,
            courseName: "The Coast Golf Club",
            region: "Eastern Suburbs",
            driveMinutesFromBondi: 14,
            par: 70,
            requiresRegistration: false,
            teeDate: teeDate,
            teeTime: teeTime,
            teeAt: ContractDate.date(from: teeAt)!,
            spotsAvailable: 2,
            totalSpots: 4,
            holes: holes,
            priceMin: priceMin,
            priceMax: priceMin,
            priceTiers: [],
            bookingType: "1st Tee Social",
            bookingURLString: bookingURL)
    }

    /// One `watches` row as PostgREST renders it, with Postgres's six
    /// fractional digits on the timestamps.
    static let watchRow = """
        {
          "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "user_id": "11111111-2222-3333-4444-555555555555",
          "label": "Saturday morning at The Coast",
          "course_slugs": ["the-coast"],
          "weekdays": [6, 7],
          "date_from": "2026-10-01",
          "date_to": "2026-10-03",
          "time_from": "07:00:00",
          "time_to": "09:30:00",
          "min_players": 2,
          "holes": null,
          "price_max": "60.00",
          "max_drive_minutes": 45,
          "active": true,
          "created_at": "2026-09-18T21:04:11.123456+00:00",
          "updated_at": "2026-09-18T21:04:11.123456+00:00",
          "expires_at": "2026-10-03T14:00:00+00:00"
        }
        """

    /// One `bookings` row.
    static let bookingRow = """
        {
          "id": "12121212-3434-5656-7878-909090909090",
          "user_id": "11111111-2222-3333-4444-555555555555",
          "slot_id": "the-coast:2026-10-03:0800:1st-tee-social",
          "course_slug": "the-coast",
          "course_name": "The Coast Golf Club",
          "tee_at": "2026-10-02T22:00:00+00:00",
          "tee_date": "2026-10-03",
          "tee_time": "08:00:00",
          "players": 4,
          "holes": 18,
          "price": 55,
          "booking_url": "https://thecoast.miclub.com.au/guests/bookings/x",
          "confirmed_at": "2026-10-01T00:00:00+00:00",
          "cancelled_at": null
        }
        """

    /// One `push_tokens` row.
    static let pushTokenRow = """
        {
          "user_id": "11111111-2222-3333-4444-555555555555",
          "token": "b4f0000000000000000000000000000000000000000000000000000000000001",
          "platform": "ios",
          "environment": "sandbox",
          "created_at": "2026-10-01T00:00:00+00:00",
          "updated_at": "2026-10-01T00:00:00+00:00"
        }
        """
}

// MARK: - Tests

/// The models, on their own: formats, the checks that mirror the migration,
/// and what a row actually looks like on the wire.
final class UserDataModelsTests: XCTestCase {

    // MARK: Dates and times stay strings

    /// The heart of it. A `date` column carries a calendar date at a golf
    /// course; a `time` column carries a wall clock there. Neither is an
    /// instant, and CONTRACT.md #4 is about what happens when one is treated as
    /// one.
    func testWatchRowEncodesDatesAndTimesAsStrings() throws {
        let draft = try WatchDraft(
            courseSlugs: ["the-coast"],
            weekdays: [7, 6],
            dateFrom: "2026-10-01",
            dateTo: "2026-10-03",
            timeFrom: "07:00",
            timeTo: "09:30",
            minPlayers: 2).validated()

        let row = WatchWriteRow(userID: B4Fixtures.userID, draft: draft, expiresAt: nil)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])

        XCTAssertEqual(json["date_from"] as? String, "2026-10-01")
        XCTAssertEqual(json["date_to"] as? String, "2026-10-03")
        XCTAssertEqual(json["time_from"] as? String, "07:00:00", "HH:MM is widened, not left short")
        XCTAssertEqual(json["time_to"] as? String, "09:30:00")
    }

    /// ISO-8601 weekdays, 1 = Monday. Sorted and de-duplicated so the array
    /// cannot outgrow the `array_length(weekdays, 1) between 1 and 7` check.
    func testWeekdaysEncodeAsSortedISOIntegers() throws {
        let draft = try WatchDraft(weekdays: [7, 6, 6, 1]).validated()
        XCTAssertEqual(draft.weekdays, [1, 6, 7])

        let row = WatchWriteRow(userID: B4Fixtures.userID, draft: draft, expiresAt: nil)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        XCTAssertEqual(json["weekdays"] as? [Int], [1, 6, 7])
    }

    /// A PATCH that leaves a nil column out cannot clear it, so every filter
    /// column is written — nulls included.
    func testClearedFiltersAreWrittenAsExplicitNulls() throws {
        let draft = try WatchDraft().validated()
        let row = WatchWriteRow(userID: nil, draft: draft, expiresAt: nil)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])

        for column in [
            "label", "course_slugs", "weekdays", "date_from", "date_to",
            "holes", "price_max", "max_drive_minutes", "expires_at",
        ] {
            XCTAssertTrue(json[column] is NSNull, "\(column) has to go out as an explicit null")
        }
        XCTAssertNil(json["user_id"], "a PATCH never re-sends the owner")
    }

    // MARK: The checks the database carries

    func testTimeOrderIsRefusedBeforeTheRoundTrip() {
        assertInvalidInput(field: "time_to") {
            try WatchDraft(timeFrom: "11:00:00", timeTo: "09:00:00").validated()
        }
    }

    func testDateOrderIsRefusedBeforeTheRoundTrip() {
        assertInvalidInput(field: "date_to") {
            try WatchDraft(dateFrom: "2026-10-05", dateTo: "2026-10-01").validated()
        }
    }

    func testPlayerCountOutsideOneToFourIsRefused() {
        assertInvalidInput(field: "min_players") { try WatchDraft(minPlayers: 0).validated() }
        assertInvalidInput(field: "min_players") { try WatchDraft(minPlayers: 5).validated() }
    }

    func testHolesMustBeNineOrEighteen() {
        assertInvalidInput(field: "holes") { try WatchDraft(holes: 12).validated() }
        XCTAssertNoThrow(try WatchDraft(holes: 9).validated())
        XCTAssertNoThrow(try WatchDraft(holes: 18).validated())
    }

    func testEmptyCourseSlugsIsRefusedButNilIsEveryCourse() throws {
        assertInvalidInput(field: "course_slugs") { try WatchDraft(courseSlugs: []).validated() }
        assertInvalidInput(field: "course_slugs") {
            try WatchDraft(courseSlugs: ["  "]).validated()
        }
        XCTAssertNil(try WatchDraft(courseSlugs: nil).validated().courseSlugs)
    }

    func testWeekdaysOutsideOneToSevenAreRefused() {
        assertInvalidInput(field: "weekdays") { try WatchDraft(weekdays: [0]).validated() }
        assertInvalidInput(field: "weekdays") { try WatchDraft(weekdays: [8]).validated() }
        assertInvalidInput(field: "weekdays") { try WatchDraft(weekdays: []).validated() }
    }

    func testNegativePriceAndDriveAreRefused() {
        assertInvalidInput(field: "price_max") { try WatchDraft(priceMax: -1).validated() }
        assertInvalidInput(field: "max_drive_minutes") {
            try WatchDraft(maxDriveMinutes: -1).validated()
        }
    }

    func testMalformedDatesAndTimesAreRefused() {
        assertInvalidInput(field: "date_from") {
            try WatchDraft(dateFrom: "2026-02-30").validated()
        }
        assertInvalidInput(field: "date_from") {
            try WatchDraft(dateFrom: "03/10/2026").validated()
        }
        assertInvalidInput(field: "time_from") {
            try WatchDraft(timeFrom: "25:00:00").validated()
        }
        assertInvalidInput(field: "time_from") { try WatchDraft(timeFrom: "7am").validated() }
    }

    /// null on a filter column means "any". The app's holes filter defaults to
    /// 18, but a draft that says nothing must not have 18 invented for it: a
    /// watch for either is a different watch from a watch for eighteen.
    func testNilHolesStaysNilRatherThanBecomingEighteen() throws {
        XCTAssertNil(try WatchDraft().validated().holes)
    }

    /// A blank label is not a label. It is dropped rather than stored, so a
    /// list of alerts never shows a row titled with three spaces.
    func testABlankLabelIsDroppedAndARealOneIsTrimmed() throws {
        XCTAssertNil(try WatchDraft(label: "   ").validated().label)
        XCTAssertEqual(
            try WatchDraft(label: "  Saturday morning  ").validated().label,
            "Saturday morning")
    }

    /// Editing an alert is decode → draft → PATCH, and a field the draft
    /// forgets to carry is a filter the golfer silently loses by opening the
    /// edit screen and saving it unchanged.
    func testEditingAWatchCarriesEveryFilterBackUnchanged() throws {
        // holes is 9 here rather than the fixture's null: a dropped `holes`
        // would compare nil-to-nil and pass on the fixture as written.
        let row = B4Fixtures.watchRow.replacingOccurrences(
            of: "\"holes\": null", with: "\"holes\": 9")
        let watch = try JSONDecoder().decode(Watch.self, from: Data(row.utf8))
        let draft = WatchDraft(watch: watch)

        XCTAssertEqual(draft.label, watch.label)
        XCTAssertEqual(draft.courseSlugs, watch.courseSlugs)
        XCTAssertEqual(draft.weekdays, watch.weekdays)
        XCTAssertEqual(draft.dateFrom, watch.dateFrom)
        XCTAssertEqual(draft.dateTo, watch.dateTo)
        XCTAssertEqual(draft.timeFrom, watch.timeFrom)
        XCTAssertEqual(draft.timeTo, watch.timeTo)
        XCTAssertEqual(draft.minPlayers, watch.minPlayers)
        XCTAssertEqual(draft.holes, 9)
        XCTAssertEqual(draft.priceMax, watch.priceMax)
        XCTAssertEqual(draft.maxDriveMinutes, watch.maxDriveMinutes)
        XCTAssertEqual(draft.active, watch.active)

        // Saving it untouched must not alter a column either.
        XCTAssertEqual(try draft.validated(), draft)
    }

    // MARK: Decoding what comes back

    func testWatchDecodesFromAPostgrestRow() throws {
        let watch = try JSONDecoder().decode(
            Watch.self, from: Data(B4Fixtures.watchRow.utf8))

        XCTAssertEqual(watch.userID, B4Fixtures.userID)
        XCTAssertEqual(watch.courseSlugs, ["the-coast"])
        XCTAssertEqual(watch.weekdays, [6, 7])
        XCTAssertEqual(watch.dateFrom, "2026-10-01")
        XCTAssertEqual(watch.timeFrom, "07:00:00")
        XCTAssertNil(watch.holes, "null holes is 'either', not a missing value")
        XCTAssertEqual(watch.priceMax, 60, "numeric arrives as a string from some clients")
        XCTAssertEqual(watch.minPlayers, 2)
        XCTAssertTrue(watch.active)
        // Postgres sends six fractional digits, which is more than
        // `ISO8601DateFormatter` reliably takes. The assertion is on the second,
        // not the microsecond: what matters is that the row parses at all
        // rather than throwing and losing the watch.
        XCTAssertEqual(
            watch.createdAt.timeIntervalSince1970,
            try XCTUnwrap(ContractDate.date(from: "2026-09-18T21:04:11+00:00"))
                .timeIntervalSince1970,
            accuracy: 1)
    }

    func testBookingDecodesAndKeepsAMalformedURLAsAString() throws {
        let booking = try JSONDecoder().decode(
            Booking.self, from: Data(B4Fixtures.bookingRow.utf8))
        XCTAssertEqual(booking.courseName, "The Coast Golf Club")
        XCTAssertEqual(booking.teeDate, "2026-10-03")
        XCTAssertEqual(booking.teeTime, "08:00:00")
        XCTAssertEqual(booking.players, 4)
        XCTAssertFalse(booking.isCancelled)
        XCTAssertNotNil(booking.bookingURL)

        let broken = B4Fixtures.bookingRow.replacingOccurrences(
            of: "https://thecoast.miclub.com.au/guests/bookings/x", with: "not a url at all")
        let survived = try JSONDecoder().decode(Booking.self, from: Data(broken.utf8))
        XCTAssertEqual(survived.bookingURLString, "not a url at all")
    }

    /// `numeric` reaches us as a JSON number from one Postgres client and as
    /// `"55.00"` from another. The contract says so about `price_min` and it is
    /// just as true of a watch's price limit and a booking's price — and a
    /// price that fails to decode takes the whole row with it.
    func testANumericColumnDecodesFromANumberAsWellAsAString() throws {
        let asString = try JSONDecoder().decode(Watch.self, from: Data(B4Fixtures.watchRow.utf8))
        XCTAssertEqual(asString.priceMax, 60)

        let asNumber = B4Fixtures.watchRow.replacingOccurrences(of: "\"60.00\"", with: "60.0")
        XCTAssertEqual(
            try JSONDecoder().decode(Watch.self, from: Data(asNumber.utf8)).priceMax, 60)

        let priceAsString = B4Fixtures.bookingRow.replacingOccurrences(
            of: "\"price\": 55", with: "\"price\": \"55.00\"")
        XCTAssertEqual(
            try JSONDecoder().decode(Booking.self, from: Data(priceAsString.utf8)).price, 55)
    }

    /// A cancelled round is a row with a timestamp in it, not a missing row.
    /// Reading it wrong is how a cancelled round turns up in "upcoming".
    func testACancelledRoundDecodesItsCancellation() throws {
        let row = B4Fixtures.bookingRow.replacingOccurrences(
            of: "\"cancelled_at\": null",
            with: "\"cancelled_at\": \"2026-10-01T23:30:00.123456+00:00\"")
        let booking = try JSONDecoder().decode(Booking.self, from: Data(row.utf8))

        XCTAssertTrue(booking.isCancelled)
        XCTAssertEqual(
            try XCTUnwrap(booking.cancelledAt).timeIntervalSince1970,
            try XCTUnwrap(ContractDate.date(from: "2026-10-01T23:30:00+00:00"))
                .timeIntervalSince1970,
            accuracy: 1)
    }

    /// A timestamp that cannot be read is a broken row, not an empty column.
    /// Read leniently, an unparseable `cancelled_at` becomes "not cancelled" and
    /// a round the golfer cancelled reappears in their upcoming list — which is
    /// worse than the row being reported as broken.
    func testAnUnreadableTimestampIsRefusedRatherThanReadAsNothing() throws {
        let cancelled = B4Fixtures.bookingRow.replacingOccurrences(
            of: "\"cancelled_at\": null", with: "\"cancelled_at\": \"soon\"")
        XCTAssertThrowsError(
            try JSONDecoder().decode(Booking.self, from: Data(cancelled.utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError, "got \(error)")
        }

        let confirmed = B4Fixtures.bookingRow.replacingOccurrences(
            of: "\"confirmed_at\": \"2026-10-01T00:00:00+00:00\"",
            with: "\"confirmed_at\": \"whenever\"")
        XCTAssertThrowsError(
            try JSONDecoder().decode(Booking.self, from: Data(confirmed.utf8)))
    }

    /// A watch has to survive its own round trip, because a `Date` encoded as a
    /// number and decoded as a string is a crash on the next launch.
    func testAWatchSurvivesItsOwnEncodeAndDecode() throws {
        let row = B4Fixtures.watchRow.replacingOccurrences(of: ".123456", with: "")
        let original = try JSONDecoder().decode(Watch.self, from: Data(row.utf8))
        let again = try JSONDecoder().decode(Watch.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(again, original)
    }

    func testPushTokenDecodesItsEnvironment() throws {
        let token = try JSONDecoder().decode(
            PushToken.self, from: Data(B4Fixtures.pushTokenRow.utf8))
        XCTAssertEqual(token.environment, .sandbox)
        XCTAssertEqual(token.platform, PushToken.platformIOS)
    }

    // MARK: End of day

    /// The two awkward nights, as arithmetic. 4 October 2026 is when Sydney
    /// puts its clocks forward, so the day before ends at +10:00 and the day
    /// itself ends at +11:00. A device-zone calendar gets one of these wrong
    /// for every user outside Sydney and both of them for a user in Perth.
    func testEndOfDayIsResolvedInSydneyAcrossTheDSTChange() throws {
        XCTAssertEqual(
            try UserDataFormat.endOfDay("2026-10-03", field: "date_to"),
            ContractDate.date(from: "2026-10-03T14:00:00+00:00"),
            "the day before the change ends at midnight AEST")

        XCTAssertEqual(
            try UserDataFormat.endOfDay("2026-10-04", field: "date_to"),
            ContractDate.date(from: "2026-10-04T13:00:00+00:00"),
            "the 23-hour day ends at midnight AEDT")

        XCTAssertEqual(
            try UserDataFormat.endOfDay("2026-04-05", field: "date_to"),
            ContractDate.date(from: "2026-04-05T14:00:00+00:00"),
            "the 25-hour day in April starts on AEDT and ends at midnight AEST")
    }

    /// A date the calendar cannot resolve is refused by name, here, rather than
    /// becoming some arbitrary instant a watch then expires at.
    func testEndOfDayRefusesADateThatIsNotOne() {
        assertInvalidInput(field: "date_to") {
            try UserDataFormat.endOfDay("2026-13-01", field: "date_to")
        }
        assertInvalidInput(field: "date_to") {
            try UserDataFormat.endOfDay("2026-02-30", field: "date_to")
        }
        assertInvalidInput(field: "date_to") {
            try UserDataFormat.endOfDay("", field: "date_to")
        }
    }

    // MARK: Helper

    private func assertInvalidInput(
        field: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Any
    ) {
        do {
            _ = try body()
            XCTFail("expected DataError.invalidInput(\(field))", file: file, line: line)
        } catch let error as DataError {
            guard case .invalidInput(let thrown, let reason) = error else {
                return XCTFail("expected invalidInput, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(thrown, field, file: file, line: line)
            XCTAssertFalse(reason.isEmpty, "a reason a screen can show", file: file, line: line)
        } catch {
            XCTFail("expected DataError, got \(error)", file: file, line: line)
        }
    }
}
