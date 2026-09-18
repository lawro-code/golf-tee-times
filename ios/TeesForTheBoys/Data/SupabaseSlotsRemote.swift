import Foundation
import Supabase
import TeesContract
import os

/// The live read path: three queries against Supabase, one `ContractPayload`.
///
/// ## What it reads, and why through the views
///
/// | Query | Gives us |
/// |---|---|
/// | `public.open_slots` | Bookable tee times, already joined to their course — one query gets course, time, price, players, par and holes |
/// | `public.courses` | The frozen roster of 15, for filters and empty states |
/// | `public.course_day_scrapes` | Per course per day, whether we actually reached the club — the stale-data banner |
///
/// `open_slots` is a view over `slots`, not the table: it filters to
/// `status = 'open'` and `tee_at > now()` and joins the course in. Reading the
/// table instead would hand the app every tee time ever seen, including the
/// ones a successful scrape stopped listing, and would need a second query per
/// row to know the course's par.
///
/// The third read is the one place this file reads a base table rather than a
/// view, and deliberately: `course_freshness` aggregates to one row per course,
/// while the payload needs a row per course *per day* to tell "Long Reef had
/// nothing free" apart from "Long Reef returned a 500".
///
/// ## Two decisions worth knowing about
///
/// **Paging.** PostgREST caps a default response. A five-day scrape of fifteen
/// courses is 1755 slots, so slots are read in blocks of
/// `PayloadAssembly.slotPageSize` ordered by `tee_at`, and the order matters:
/// without a stable ORDER BY, two pages can overlap or skip rows.
///
/// **`generated_at` is the scrape, not the download.** It is the newest
/// `last_seen_at` on the rows that came back. A user looking at a banner that
/// says "updated 4 minutes ago" is asking when the club was last checked, not
/// when their phone last succeeded at talking to us.
public struct SupabaseSlotsRemote: SlotsFetching {

    /// The read surface. Names are here rather than inline so a migration that
    /// renames a view breaks in one place.
    enum Source {
        static let slots = "open_slots"
        static let courses = "courses"
        static let courseDays = "course_day_scrapes"
    }

    private let client: SupabaseClient
    private let pageSize: Int
    private let maximumPages: Int
    private let retriesTransientFailures: Bool
    private let now: @Sendable () -> Date

    /// B3 builds this with exactly this initialiser. The label does not change.
    public init(client: SupabaseClient) {
        self.init(client: client, pageSize: PayloadAssembly.slotPageSize)
    }

    /// Test seam: a small page size proves paging without 1000-row fixtures, an
    /// injected clock keeps the day window deterministic, and turning retries
    /// off stops an offline test spending seven seconds asleep in the SDK's
    /// exponential backoff. Production keeps the SDK default of three retries
    /// on a transient failure.
    init(
        client: SupabaseClient,
        pageSize: Int,
        maximumPages: Int = 64,
        retriesTransientFailures: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.pageSize = max(1, pageSize)
        self.maximumPages = max(1, maximumPages)
        self.retriesTransientFailures = retriesTransientFailures
        self.now = now
    }

    // MARK: - SlotsFetching

    public func fetchPayload() async throws -> ContractPayload {
        try await fetchPayload(mode: .full, days: Self.defaultDays(for: .full))
    }

    /// Bound the window when the caller only wants the near days.
    ///
    /// Days 0-2 are rescraped every 20 minutes and days 3-5 twice a day, so a
    /// caller refreshing for cancellations has no reason to pull five days of
    /// slots it already has. `days` counts today as day 0: `days: 3` is today,
    /// tomorrow and the day after.
    public func fetchPayload(mode: ContractPayload.Mode, days: Int) async throws -> ContractPayload {
        let window = Self.window(days: days, now: now())

        let courses = try await rows(collection: "courses") {
            client.from(Source.courses)
                .select()
                .eq("active", value: true)
                .order("sort_order")
        }

        let courseDays = try await rows(collection: "course_days") {
            client.from(Source.courseDays)
                .select()
                .gte("tee_date", value: window.first)
                .lte("tee_date", value: window.last)
                .order("tee_date")
                .order("course_slug")
        }

        var slots = RawRows(collection: "slots")
        var offset = 0
        var reachedTheEnd = false
        for _ in 0..<maximumPages {
            let page = try await rows(collection: "slots") {
                client.from(Source.slots)
                    .select()
                    .lte("tee_date", value: window.last)
                    // Ordered before ranged, and with a tiebreaker: two-tee
                    // starts mean many rows share a `tee_at`, and an unstable
                    // order can repeat or skip rows between pages.
                    .order("tee_at")
                    .order("id")
                    .range(from: offset, to: offset + pageSize - 1)
            }
            slots.append(page)
            if page.count < pageSize {
                reachedTheEnd = true
                break
            }
            offset += page.count
        }
        if !reachedTheEnd {
            // Only reachable if the database holds more than 64,000 open future
            // slots, which is forty times a real scrape. Said out loud, because
            // a list that is quietly missing next Sunday is the worst version
            // of this failing.
            DataLog.remote.error(
                "stopped after \(maximumPages, privacy: .public) slot pages; the list may be short")
        }

        return try PayloadAssembly.payload(
            courses: courses,
            slots: slots,
            courseDays: courseDays,
            mode: mode,
            days: window.days,
            generatedAt: nil,
            now: now())
    }

    /// Days 0-2 on the fast cadence, days 0-5 on the full one. The cadence is
    /// settled in BUILD-PLAN.md; this only mirrors it.
    public static func defaultDays(for mode: ContractPayload.Mode) -> Int {
        switch mode {
        case .fast: return 3
        case .full: return 5
        }
    }

    // MARK: - One query

    private func rows(
        collection: String,
        _ build: () -> PostgrestTransformBuilder
    ) async throws -> RawRows {
        do {
            let response = try await build().retry(enabled: retriesTransientFailures).execute()
            return try RawRows(collection: collection, json: response.data)
        } catch {
            // Every failure goes through the one door, including the `HTTPError`
            // the SDK throws when a non-2xx body is not PostgREST's JSON — a
            // gateway's HTML 502, say. `DataError.from` already keeps that
            // status and runs the body through `bodyMessage`, which drops an
            // HTML page rather than let it reach a golfer's alert.
            throw DataError.from(error)
        }
    }

    // MARK: - The day window

    /// Sydney, because the window is a run of calendar days at the course. This
    /// is a date bound for a query, not a recomputation of `tee_at` — that one
    /// instant is resolved on the server and never here.
    static let sydney = TimeZone(identifier: "Australia/Sydney") ?? TimeZone(identifier: "UTC")!

    struct Window {
        let first: String
        let last: String
        let days: Int
    }

    static func window(days: Int, now: Date) -> Window {
        let days = max(1, days)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sydney
        let end = calendar.date(byAdding: .day, value: days - 1, to: now) ?? now
        return Window(first: teeDate(now, calendar: calendar),
                      last: teeDate(end, calendar: calendar),
                      days: days)
    }

    private static func teeDate(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
