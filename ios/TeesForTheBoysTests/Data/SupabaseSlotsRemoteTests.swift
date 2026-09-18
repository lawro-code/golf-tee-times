import XCTest
@testable import TeesData
import TeesContract
import Supabase

// MARK: - The stub

/// Canned PostgREST responses. No test in this track touches a hosted project,
/// so every byte the Supabase SDK sees comes from here.
///
/// All four B tickets compile into one test bundle, so every test-only type in
/// this file is prefixed `B2`.
final class B2StubURLProtocol: URLProtocol {

    /// Deliberately not `@Sendable`: a responder closes over the rows a test
    /// wants served, and those are plain JSON dictionaries. The box below is
    /// what makes the shared state safe.
    typealias Responder = (URLRequest) throws -> (status: Int, body: Data)

    private static let box = B2StubBox()

    static func respond(_ responder: @escaping Responder) {
        box.set(responder)
    }

    static func reset() {
        box.reset()
    }

    /// Every URL the SDK asked for, in order. This is how a test checks that
    /// slots were read through `open_slots` and paged, rather than trusting
    /// that they were.
    static var requestedURLs: [URL] { box.requestedURLs }

    static func requests(to table: String) -> [URL] {
        requestedURLs.filter { $0.lastPathComponent == table }
    }

    static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let responder = B2StubURLProtocol.box.record(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (status, body) = try responder(request)
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// The stub's shared state, behind a lock: `URLProtocol` runs on whatever
/// thread the session hands it.
final class B2StubBox: @unchecked Sendable {
    private let lock = NSLock()
    private var responder: B2StubURLProtocol.Responder?
    private var urls: [URL] = []

    func set(_ responder: @escaping B2StubURLProtocol.Responder) {
        lock.lock(); defer { lock.unlock() }
        self.responder = responder
        urls = []
    }

    func record(_ url: URL) -> B2StubURLProtocol.Responder? {
        lock.lock(); defer { lock.unlock() }
        urls.append(url)
        return responder
    }

    var requestedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        responder = nil
        urls = []
    }
}

// MARK: - Tests

/// The live read path, driven entirely through canned PostgREST bytes.
///
/// What these prove, in one line each: we read the views and not the base
/// table, slots page, a bad row costs one row, and a server that says no
/// becomes a `DataError` rather than a crash.
final class SupabaseSlotsRemoteTests: XCTestCase {

    /// 1 October 2026, 07:30 Sydney — the same instant `minimal.json` is
    /// generated at, so the day window in these tests is 3 to 7 October.
    private let now = ContractDate.date(from: "2026-10-01T07:30:00+10:00")!

    override func tearDown() {
        B2StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeRemote(
        pageSize: Int = PayloadAssembly.slotPageSize,
        maximumPages: Int = 64
    ) -> SupabaseSlotsRemote {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [B2StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SupabaseClientProvider.client(
            configuration: SupabaseConfiguration(
                url: URL(string: "https://b2-stub.supabase.co")!, anonKey: "b2-anon-key"),
            session: session)
        let capturedNow = now
        return SupabaseSlotsRemote(
            client: client,
            pageSize: pageSize,
            maximumPages: maximumPages,
            retriesTransientFailures: false,
            now: { capturedNow })
    }

    /// Serve the three views from arrays, paging `open_slots` the way PostgREST
    /// does: honour the `offset` and `limit` the client asked for.
    private func stubViews(
        courses: [Any] = B2Rows.fifteenCourses,
        slots: [Any] = [],
        courseDays: [Any] = [],
        slotStatus: Int = 200,
        slotBody: Data? = nil
    ) {
        B2StubURLProtocol.respond { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.lastPathComponent {
            case "courses":
                return (200, try JSONSerialization.data(withJSONObject: courses))
            case "course_day_scrapes":
                return (200, try JSONSerialization.data(withJSONObject: courseDays))
            case "open_slots":
                if let slotBody { return (slotStatus, slotBody) }
                let offset = Int(B2StubURLProtocol.queryValue("offset", in: url) ?? "0") ?? 0
                let limit = Int(B2StubURLProtocol.queryValue("limit", in: url) ?? "1000") ?? 1000
                let upper = min(offset + limit, slots.count)
                let page = offset < upper ? Array(slots[offset..<upper]) : []
                return (slotStatus, try JSONSerialization.data(withJSONObject: page))
            default:
                throw URLError(.unsupportedURL)
            }
        }
    }

    // MARK: - What it reads

    /// CONTRACT.md: read through the views, never the base tables. `open_slots`
    /// is already filtered to open, future tee times and joined to its course;
    /// `slots` is every tee time ever seen, including the gone ones.
    func testReadsThroughTheViewsAndNeverTheSlotsTable() async throws {
        stubViews(slots: [B2Rows.slot()], courseDays: [B2Rows.courseDay()])

        _ = try await makeRemote().fetchPayload()

        let tables = Set(B2StubURLProtocol.requestedURLs.map(\.lastPathComponent))
        XCTAssertTrue(tables.contains("open_slots"))
        XCTAssertTrue(tables.contains("courses"))
        XCTAssertTrue(tables.contains("course_day_scrapes"))
        XCTAssertFalse(tables.contains("slots"), "the base table is not the app's read surface")
        XCTAssertFalse(tables.contains("course_freshness"),
                       "the banner needs a row per course per day, which that view aggregates away")
    }

    func testSlotsAreOrderedByTeeAt() async throws {
        stubViews(slots: [B2Rows.slot()])

        _ = try await makeRemote().fetchPayload()

        let slotURL = try XCTUnwrap(B2StubURLProtocol.requests(to: "open_slots").first)
        let order = try XCTUnwrap(B2StubURLProtocol.queryValue("order", in: slotURL))
        XCTAssertTrue(order.hasPrefix("tee_at.asc"), order)
        XCTAssertTrue(order.contains("id"), "a tiebreaker keeps two-tee starts from shuffling between pages: \(order)")
    }

    // MARK: - Paging

    func testPagingWalksTheRangeUntilAShortPage() async throws {
        let slots: [Any] = (0..<5).map { B2Rows.slot(tee: "t\($0)") }
        stubViews(slots: slots)

        let payload = try await makeRemote(pageSize: 2).fetchPayload()

        XCTAssertEqual(payload.slots.count, 5)
        let pages = B2StubURLProtocol.requests(to: "open_slots")
        XCTAssertEqual(pages.count, 3, "two full pages and a short one")
        XCTAssertEqual(pages.map { B2StubURLProtocol.queryValue("offset", in: $0) },
                       ["0", "2", "4"])
        XCTAssertEqual(Set(pages.map { B2StubURLProtocol.queryValue("limit", in: $0) }), ["2"])
    }

    /// A database that never returns a short page must not spin forever. The
    /// cap costs a logged line and a short list; no cap costs the app.
    func testPagingStopsAtTheCapInsteadOfSpinning() async throws {
        let slots: [Any] = (0..<50).map { B2Rows.slot(tee: "t\($0)") }
        stubViews(slots: slots)

        let payload = try await makeRemote(pageSize: 2, maximumPages: 3).fetchPayload()

        XCTAssertEqual(payload.slots.count, 6)
        XCTAssertEqual(B2StubURLProtocol.requests(to: "open_slots").count, 3)
    }

    /// The golden fixture is 1755 slots over five days and PostgREST caps a
    /// default response. Without paging the app shows the first thousand tee
    /// times and silently loses the rest of the week.
    func testPagingAssemblesMoreThanAThousandSlots() async throws {
        let dates = ["2026-10-03", "2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07"]
        let slots: [Any] = (0..<1755).map { index in
            B2Rows.slot(date: dates[index % dates.count], tee: "t\(index)")
        }
        stubViews(slots: slots, courseDays: [B2Rows.courseDay()])

        let payload = try await makeRemote().fetchPayload()

        XCTAssertEqual(payload.slots.count, 1755)
        XCTAssertEqual(Set(payload.slots.map(\.id)).count, 1755, "ids stay unique across pages")
        XCTAssertTrue(payload.issues.isEmpty)

        let pages = B2StubURLProtocol.requests(to: "open_slots")
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.map { B2StubURLProtocol.queryValue("offset", in: $0) }, ["0", "1000"])
        XCTAssertEqual(Set(pages.map { B2StubURLProtocol.queryValue("limit", in: $0) }), ["1000"])
    }

    // MARK: - Bad data, live

    func testOneCorruptCourseStillYieldsTheOtherFourteen() async throws {
        var courses = B2Rows.fifteenCourses
        courses[3].removeValue(forKey: "name")
        stubViews(courses: courses, slots: [B2Rows.slot()])

        let payload = try await makeRemote().fetchPayload()

        XCTAssertEqual(payload.courses.count, 14)
        XCTAssertEqual(payload.issues.count, 1)
        XCTAssertEqual(payload.issues.first?.collection, "courses")
        XCTAssertEqual(payload.slots.count, 1, "the slots were never in question")
    }

    func testUnpricedAndNineHoleSlotsSurviveTheLiveReadPath() async throws {
        stubViews(slots: [
            B2Rows.slot(time: "06:16", tee: "a", priceMin: NSNull()),
            B2Rows.slot(time: "06:24", tee: "b", priceMin: "55.00", priceMax: "55.00"),
            B2Rows.slot(courseSlug: "bankstown", time: "07:00", tee: "c", holes: 9),
        ])

        let payload = try await makeRemote().fetchPayload()

        XCTAssertEqual(payload.slots.count, 3)
        XCTAssertNil(payload.slots[0].priceMin)
        XCTAssertEqual(payload.slots[1].priceMin, 55.0)
        XCTAssertEqual(payload.slots[2].holes, 9)
        XCTAssertTrue(payload.issues.isEmpty)
    }

    // MARK: - When the server says no

    /// A 500 is a `DataError`, not a crash and not an empty list. An empty list
    /// would read to the user as "no tee times", which is a different and much
    /// worse lie.
    func testServerErrorBecomesADataError() async throws {
        let body = Data(#"{"message":"internal server error","code":"XX000"}"#.utf8)
        stubViews(slots: [B2Rows.slot()], slotStatus: 500, slotBody: body)

        do {
            _ = try await makeRemote().fetchPayload()
            XCTFail("a 500 must not decode into a payload")
        } catch let error as DataError {
            guard case .server(_, let message) = error else {
                return XCTFail("expected .server, got \(error.diagnostic)")
            }
            XCTAssertEqual(message, "internal server error")
        }
    }

    /// The same, when the 500 comes from something in front of PostgREST and
    /// the body is HTML rather than PostgREST's JSON.
    ///
    /// The status has to survive — a 502 is retryable and a 400 is not — but
    /// the body must not. `DataError.description` is what a SwiftUI alert
    /// shows, so a gateway's error page reaching it verbatim would put
    /// `<!DOCTYPE html>` in front of a golfer. That is why this path goes
    /// through `DataError.from` and its `bodyMessage` filter rather than
    /// passing the raw bytes along.
    func testNonJSONServerErrorKeepsItsStatus() async throws {
        stubViews(
            slots: [B2Rows.slot()],
            slotStatus: 502,
            slotBody: Data("<html><body>502 Bad Gateway</body></html>".utf8))

        do {
            _ = try await makeRemote().fetchPayload()
            XCTFail("a 502 must not decode into a payload")
        } catch let error as DataError {
            guard case .server(let status, let message) = error else {
                return XCTFail("expected .server, got \(error.diagnostic)")
            }
            XCTAssertEqual(status, 502)
            XCTAssertTrue(error.isRetryable, "a gateway error is worth retrying")
            XCTAssertNil(message, "an HTML error page is not a message for a golfer")
            XCTAssertFalse(error.description.contains("<html"),
                           "the alert would show markup: \(error.description)")
            XCTAssertFalse(error.description.contains("<body"),
                           "the alert would show markup: \(error.description)")
            XCTAssertEqual(error.description, "The server is having a moment. Try again shortly.")
        }
    }

    func testTransportFailureBecomesOffline() async throws {
        B2StubURLProtocol.respond { _ in throw URLError(.notConnectedToInternet) }

        do {
            _ = try await makeRemote().fetchPayload()
            XCTFail("an unreachable server must not decode into a payload")
        } catch let error as DataError {
            XCTAssertEqual(error, .offline)
        }
    }

    // MARK: - The window and the stamp

    func testFastModeAsksForThreeDaysOnly() async throws {
        stubViews(slots: [B2Rows.slot()], courseDays: [B2Rows.courseDay()])

        let payload = try await makeRemote().fetchPayload(mode: .fast, days: 3)

        XCTAssertEqual(payload.mode, .fast)
        XCTAssertEqual(payload.days, 3)
        let slotURL = try XCTUnwrap(B2StubURLProtocol.requests(to: "open_slots").first)
        XCTAssertEqual(B2StubURLProtocol.queryValue("tee_date", in: slotURL), "lte.2026-10-03")

        let dayURL = try XCTUnwrap(B2StubURLProtocol.requests(to: "course_day_scrapes").first)
        let bounds = URLComponents(url: dayURL, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "tee_date" }.compactMap(\.value) ?? []
        XCTAssertEqual(Set(bounds), ["gte.2026-10-01", "lte.2026-10-03"])
    }

    func testFullModeAsksForFiveDays() async throws {
        stubViews(slots: [B2Rows.slot()])

        _ = try await makeRemote().fetchPayload()

        let slotURL = try XCTUnwrap(B2StubURLProtocol.requests(to: "open_slots").first)
        XCTAssertEqual(B2StubURLProtocol.queryValue("tee_date", in: slotURL), "lte.2026-10-05")
    }

    /// `generated_at` answers "when was the club last checked", which is the
    /// question the stale-data banner asks. `Date()` answers "when did this
    /// download finish", which always looks fresh.
    func testGeneratedAtIsTheScrapeNotTheDownload() async throws {
        stubViews(slots: [
            B2Rows.slot(time: "06:16", tee: "a", lastSeenAt: "2026-10-01T06:40:00+10:00"),
            B2Rows.slot(time: "06:24", tee: "b", lastSeenAt: "2026-10-01T07:20:00+10:00"),
        ])

        let payload = try await makeRemote().fetchPayload()

        XCTAssertEqual(ContractDate.date(from: payload.generatedAt),
                       ContractDate.date(from: "2026-10-01T07:20:00+10:00"))
    }

    func testAnEmptyDatabaseIsAnEmptyPayloadNotAFailure() async throws {
        stubViews(courses: [], slots: [], courseDays: [])

        let payload = try await makeRemote().fetchPayload()

        XCTAssertTrue(payload.slots.isEmpty)
        XCTAssertTrue(payload.courses.isEmpty)
        XCTAssertTrue(payload.issues.isEmpty)
        XCTAssertEqual(payload.contractVersion, Contract.version)
        XCTAssertEqual(B2StubURLProtocol.requests(to: "open_slots").count, 1)
    }

    func testItIsUsableAsASlotsFetching() async throws {
        stubViews(slots: [B2Rows.slot()])
        let remote: any SlotsFetching = makeRemote()

        let payload = try await remote.fetchPayload()

        XCTAssertEqual(payload.slots.count, 1)
    }
}
