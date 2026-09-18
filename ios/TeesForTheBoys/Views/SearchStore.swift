import Combine
import Foundation
import TeesContract

/// The one object the search screens observe.
///
/// It owns the payload, the filters, the derived sections and the freshness
/// summary, and it recomputes the last two whenever either of the first two
/// changes. A screen reads; it does not derive.
///
/// **Fixtures only.** Track C has no network and no `TeesData` dependency — the
/// module does not link it and must not. Stage 2 swaps the fixture load for the
/// real store; until then `ContractLoader.fixture` is the whole data source,
/// and that is deliberate: the screens get built against the awkward real data
/// rather than against something convenient.
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

    /// Setting this persists the hole choice and recomputes the sections.
    ///
    /// `didSet` rather than a `setFilters` method so a SwiftUI binding —
    /// `$store.filters.players` — does the right thing without every screen
    /// remembering to call something afterwards.
    @Published public var filters: SearchFilters {
        didSet {
            if oldValue.holes != filters.holes {
                ViewsPreferences.setHoles(filters.holes, in: preferences)
            }
            recompute()
        }
    }

    @Published public private(set) var sections: [SlotDaySection] = []
    @Published public private(set) var resultCount: Int = 0
    @Published public private(set) var freshness: FreshnessSummary = .unknown

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

    /// Load the fixture and recompute everything derived from it.
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
        recompute()
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

    private func recompute() {
        guard let payload else {
            sections = []
            resultCount = 0
            freshness = .unknown
            return
        }

        let results = SlotQuery.apply(filters, to: payload.slots)
        sections = SlotQuery.sections(
            results,
            today: today,
            priceFilterActive: filters.maxPrice != nil)
        resultCount = results.count
        freshness = FreshnessSummary.make(
            courseDays: payload.courseDays,
            courses: payload.courses,
            now: now())
    }

    private static let sydneyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = SlotFormatting.sydney
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
