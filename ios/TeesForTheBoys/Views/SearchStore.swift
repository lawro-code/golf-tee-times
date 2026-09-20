import Combine
import Foundation
import TeesContract

/// The one object the search screens observe.
///
/// It owns the payload and the filters; `sections`, `resultCount` and
/// `freshness` are derived from those two plus the current instant, computed
/// fresh on every read rather than cached. A screen reads; it does not
/// derive.
///
/// **Why computed, not cached.** An earlier version cached these three in
/// `@Published` vars and refreshed them from a private `recompute()` called
/// only on a filter change or a new payload. Nothing else in the app ever
/// touches either of those, so a golfer who opens the app once and leaves it
/// — foregrounded or backgrounded, untouched — sailed straight through local
/// midnight with the cache frozen on the wrong side of it: "Tomorrow"
/// stayed "Tomorrow" after it became today, and yesterday's now-past tee
/// times stayed listed under "Today". `today` (below) was always computed
/// fresh and never had this problem; `sections` et al. now match it.
///
/// **No `TeesData` dependency, and never will be.** Track C was built and
/// tested against `load()` and a bundled fixture on purpose — the screens got
/// built against the awkward real data rather than against something
/// convenient. Stage 2 added `apply(payload:errorDescription:)` alongside it
/// for the live path: the App target owns `TeeTimeStore` and forwards its
/// snapshots here, so this module still never imports `TeesData` and the
/// module boundary stays real rather than aspirational.
@MainActor
public final class SearchStore: ObservableObject {

    /// Where the load got to. `.failed` carries the loader's own error text so
    /// a broken fixture name says which fixture, not "something went wrong".
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published public private(set) var state: LoadState = .idle
    @Published public private(set) var payload: ContractPayload?

    /// Setting this persists the hole choice. `sections`/`resultCount`
    /// reflect the new filters on their very next read — see the class doc
    /// comment — so there is nothing else for this to trigger.
    ///
    /// `didSet` rather than a `setFilters` method so a SwiftUI binding —
    /// `$store.filters.players` — does the right thing without every screen
    /// remembering to call something afterwards.
    @Published public var filters: SearchFilters {
        didSet {
            if oldValue.holes != filters.holes {
                ViewsPreferences.setHoles(filters.holes, in: preferences)
            }
        }
    }

    /// Set by whoever owns connectivity. The store does not watch the network —
    /// it has none — it just carries the flag so one banner decision lives in
    /// one place.
    @Published public var isOffline: Bool = false

    public var courses: [Course] { payload?.courses ?? [] }

    /// Sydney wall-clock `YYYY-MM-DD`, derived from the injected clock.
    ///
    /// Sydney and not the device's zone: a golfer checking tee times from a
    /// Melbourne airport lounge is still booking a Sydney morning, and
    /// "Tomorrow" has to mean tomorrow at the course.
    public var today: String { Self.sydneyDateFormatter.string(from: now()) }

    private let preferences: ViewsKeyValueStore
    private let fixtureName: String
    private let now: () -> Date

    /// - Parameters:
    ///   - preferences: the persistence seam. Pass an `InMemoryViewsStore` in a
    ///     test or a preview and nothing touches the simulator's defaults.
    ///   - fixture: `"golden"` for scrolling and previews (a real 15-course,
    ///     1755-slot scrape), `"minimal"` for assertions.
    ///   - now: injected clock. Every date decision in the store goes through
    ///     it, so a test can sit on a fixed instant.
    public init(
        preferences: ViewsKeyValueStore = UserDefaultsViewsStore(),
        fixture: String = "golden",
        now: @escaping () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.fixtureName = fixture
        self.now = now
        // The remembered hole count, read before anything else: a golfer who
        // plays nines should never see an 18-hole list on launch.
        var initial = SearchFilters.standard
        initial.holes = ViewsPreferences.holes(from: preferences)
        self.filters = initial
    }

    /// Load the fixture.
    ///
    /// Synchronous on purpose — reading a bundled file is not worth an `async`
    /// seam that Stage 2 would then have to unpick. A missing or undecodable
    /// fixture lands in `.failed` with `ContractLoader`'s message; it never
    /// throws and never crashes.
    public func load() {
        state = .loading
        do {
            let loaded = try ContractLoader.fixture(fixtureName)
            payload = loaded
            state = .loaded
        } catch {
            payload = nil
            state = .failed(String(describing: error))
        }
    }

    /// The Stage 2 seam this type's own doc comment promised: a live payload
    /// coming from `TeeTimeStore` rather than a bundled fixture.
    ///
    /// Deliberately just a setter, not a subscription. `TeesViews` has no
    /// `TeesData` dependency and must not gain one — the module boundary is
    /// the whole point of splitting the tracks. The App target holds
    /// `TeeTimeStore`, awaits its `snapshotStream()`, and calls this on every
    /// snapshot; this store never needs to know what a `TeeTimeSnapshot` is.
    ///
    /// - Parameters:
    ///   - payload: nil is a legitimate state — no cache yet and no fetch has
    ///     landed. It renders as `.loading`, the same as a fixture that has not
    ///     resolved, not as `.failed`.
    ///   - errorDescription: set only when a fetch actually failed. A nil
    ///     payload with no error is "still loading", not "broken".
    public func apply(payload newPayload: ContractPayload?, errorDescription: String? = nil) {
        payload = newPayload
        if let errorDescription {
            state = .failed(errorDescription)
        } else if newPayload != nil {
            state = .loaded
        } else {
            state = .loading
        }
    }

    /// Back to one player, 18 holes, every day, every course.
    ///
    /// Reset means reset: the remembered hole count goes back to the documented
    /// default too, because a golfer who taps "Clear" and still sees a filtered
    /// list has been told the button does nothing.
    public func resetFilters() {
        filters = .standard
    }

    /// A loaded store for SwiftUI previews. Defaults to `minimal` so a preview
    /// renders every awkward case — a two-tee start, a 9-hole booking at an
    /// 18-hole club, an unpriced slot, a club needing registration — on one
    /// screen instead of none of them.
    public static func previewStore(fixture: String = "minimal") -> SearchStore {
        let store = SearchStore(preferences: InMemoryViewsStore(), fixture: fixture)
        store.load()
        return store
    }

    // MARK: - Derivation

    /// The day-grouped results a screen renders. Computed fresh on every
    /// read from `payload`, `filters` and `now()` — never cached — so a
    /// section's "Today"/"Tomorrow" title, and which now-past slots have
    /// dropped out, are always true of the instant it is actually read,
    /// with nothing that needs to remember to ask for a refresh first.
    public var sections: [SlotDaySection] {
        guard let payload else { return [] }
        return SlotQuery.sections(
            matchingResults(in: payload),
            today: today,
            priceFilterActive: filters.maxPrice != nil)
    }

    /// `sections.reduce(0) { $0 + $1.results.count }`, computed the same way
    /// so the two can never disagree.
    public var resultCount: Int {
        guard let payload else { return 0 }
        return matchingResults(in: payload).count
    }

    /// Scoped to the same day/course facets `matchingResults` uses, so the
    /// banner describes what's on screen rather than the whole 5-day,
    /// 15-course payload. Days 3-4 only get a fresh scrape every ~12h
    /// (`scrape.yml`'s full run) while days 0-2 refresh every 20 minutes
    /// (`scrape-fast.yml`); mixing them lets an always-recent day-0-2 row
    /// hide a stale day-3/4 row the golfer actually filtered down to.
    public var freshness: FreshnessSummary {
        guard let payload else { return .unknown }
        return FreshnessSummary.make(
            courseDays: Self.visibleCourseDays(payload.courseDays, matching: filters),
            courses: payload.courses,
            now: now())
    }

    private func matchingResults(in payload: ContractPayload) -> [SlotResult] {
        SlotQuery.apply(filters, to: payload.slots, now: now())
    }

    /// Narrow `course_days` to the day/course facets a golfer actually
    /// selected — the same two facets `SlotQuery.matches` uses to narrow
    /// slots. Other filters (players, holes, price, drive time) select
    /// individual slots within a day and say nothing about which
    /// course-day rows are "on screen", so they are deliberately not
    /// applied here.
    static func visibleCourseDays(_ courseDays: [CourseDay], matching filters: SearchFilters) -> [CourseDay] {
        courseDays.filter { day in
            (filters.days.isEmpty || filters.days.contains(day.teeDate))
                && (filters.courseSlugs.isEmpty || filters.courseSlugs.contains(day.courseSlug))
        }
    }

    private static let sydneyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = SlotFormatting.sydney
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
