import Foundation

/// Everything a golfer can narrow the list by, as one value type.
///
/// It is deliberately a plain `struct`: the filter bar, the store, a saved
/// watch and a unit test all hold the same thing, and nothing about matching a
/// slot needs a view or a clock. `SlotQuery` does the matching; this type only
/// says what was asked for.
///
/// Two rules from CONTRACT.md live in here rather than in a screen:
///
/// - **Holes defaults to 18** (§2). Three 18-hole clubs also sell 9-hole tee
///   times, so "18 holes" is a real choice a golfer made, not an absence of
///   one. `activeCount` therefore does not count `.eighteen` as a filter.
/// - **A filter never hides inventory it cannot judge** (§3). `maxPrice` and
///   `maxDriveMinutes` are recorded here; `SlotQuery` is where the "unknown
///   still shows" rule is enforced, because that is where the slot is.
public struct SearchFilters: Equatable, Codable, Sendable {

    /// `YYYY-MM-DD` tee_date values. Empty means any day.
    ///
    /// Days are held as the course's wall-clock date string, never as a
    /// `Date`. The server already resolved Sydney's DST once; re-deriving a
    /// calendar day on the client is how the two disagree.
    public var days: Set<String>

    /// Empty means any time of day.
    public var timesOfDay: Set<TimeOfDay>

    /// 1...4. A slot matches when `spots_available >= players`.
    public var players: Int

    /// Defaults to `.eighteen`. See `ViewsPreferences` for the persistence.
    public var holes: HolesFilter

    /// Nil means any price. An unpriced slot never fails this — see
    /// `SlotQuery.apply`.
    public var maxPrice: Double?

    /// Nil means any drive. A slot with no known drive time never fails this.
    public var maxDriveMinutes: Int?

    /// Empty means all fifteen courses.
    public var courseSlugs: Set<String>

    public init(
        days: Set<String> = [],
        timesOfDay: Set<TimeOfDay> = [],
        players: Int = 1,
        holes: HolesFilter = .eighteen,
        maxPrice: Double? = nil,
        maxDriveMinutes: Int? = nil,
        courseSlugs: Set<String> = []
    ) {
        self.days = days
        self.timesOfDay = timesOfDay
        // Clamped rather than trusted: a stepper bound to 1...4 cannot produce
        // a 7, but a decoded watch from a future build could.
        self.players = min(max(players, 1), 4)
        self.holes = holes
        self.maxPrice = maxPrice
        self.maxDriveMinutes = maxDriveMinutes
        self.courseSlugs = courseSlugs
    }

    /// The synthesized `Decodable` conformance would assign `players`
    /// straight from the JSON, bypassing the clamp above — exactly the
    /// "future build" case the initializer's comment warns about, except it
    /// arrives from decoding a stored watch rather than from a newer app.
    /// Routing through the memberwise initializer keeps one place that owns
    /// the clamp instead of two that can drift apart.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            days: try c.decode(Set<String>.self, forKey: .days),
            timesOfDay: try c.decode(Set<TimeOfDay>.self, forKey: .timesOfDay),
            players: try c.decode(Int.self, forKey: .players),
            holes: try c.decode(HolesFilter.self, forKey: .holes),
            maxPrice: try c.decodeIfPresent(Double.self, forKey: .maxPrice),
            maxDriveMinutes: try c.decodeIfPresent(Int.self, forKey: .maxDriveMinutes),
            courseSlugs: try c.decode(Set<String>.self, forKey: .courseSlugs))
    }

    /// What a golfer sees before touching anything: one player, 18 holes,
    /// every day, every course, no price or drive ceiling.
    public static let standard = SearchFilters()

    public var isStandard: Bool { self == .standard }

    /// The number on the filter-bar badge.
    ///
    /// `holes == .eighteen` is the default and does **not** count, so the badge
    /// reads zero on a fresh launch. Everything else counts once, whatever its
    /// cardinality: picking three days is one active filter, not three.
    public var activeCount: Int {
        var n = 0
        if !days.isEmpty { n += 1 }
        if !timesOfDay.isEmpty { n += 1 }
        if players > 1 { n += 1 }
        if holes != .eighteen { n += 1 }
        if maxPrice != nil { n += 1 }
        if maxDriveMinutes != nil { n += 1 }
        if !courseSlugs.isEmpty { n += 1 }
        return n
    }

    // MARK: - Time of day

    /// Five fixed buckets. The boundaries are product decisions, not derived
    /// from the data, so they are written down once here and asserted in the
    /// tests rather than restated in each screen.
    ///
    /// | Case | Matches |
    /// |---|---|
    /// | `earlyMorning` | before 07:00 |
    /// | `morning` | 07:00–10:59 |
    /// | `midday` | 11:00–13:59 |
    /// | `afternoon` | 14:00–16:59 |
    /// | `twilight` | 17:00 and later |
    public enum TimeOfDay: String, CaseIterable, Codable, Sendable {
        case earlyMorning
        case morning
        case midday
        case afternoon
        case twilight

        public var title: String {
            switch self {
            case .earlyMorning: return "Early"
            case .morning: return "Morning"
            case .midday: return "Midday"
            case .afternoon: return "Afternoon"
            case .twilight: return "Twilight"
            }
        }

        public var subtitle: String {
            switch self {
            case .earlyMorning: return "before 7am"
            case .morning: return "7\u{2013}11am"
            case .midday: return "11am\u{2013}2pm"
            case .afternoon: return "2\u{2013}5pm"
            case .twilight: return "after 5pm"
            }
        }

        /// The half-open hour range this bucket owns, as `start..<end` in
        /// 24-hour wall-clock hours.
        var hourRange: Range<Int> {
            switch self {
            case .earlyMorning: return 0..<7
            case .morning: return 7..<11
            case .midday: return 11..<14
            case .afternoon: return 14..<17
            case .twilight: return 17..<24
            }
        }

        /// - Parameter teeTime: the contract's `tee_time`, which is always
        ///   `HH:MM:SS` — PostgREST renders a Postgres `time` with seconds, so
        ///   anything written against `"HH:MM"` will silently never match.
        ///
        /// A value that will not parse returns `false`. That is not the
        /// missing-data rule from CONTRACT.md §3: `tee_time` is non-null in
        /// the contract, so an unparseable one is a corrupt row rather than a
        /// club declining to publish something.
        public func matches(teeTime: String) -> Bool {
            guard let parts = ViewsWallClock.parse(teeTime) else { return false }
            return hourRange.contains(parts.hour)
        }
    }

    // MARK: - Holes

    /// Nine, eighteen, or do not care.
    ///
    /// Matching is against the **slot's** hole count, never the course's.
    /// Bankstown, Beverley Park and Brighton Lakes are 18-hole clubs that sell
    /// 9-hole tee times; copying the course's number here shows a golfer nine
    /// holes when they asked for eighteen.
    public enum HolesFilter: String, CaseIterable, Codable, Sendable {
        case nine
        case eighteen
        case any

        public var title: String {
            switch self {
            case .nine: return "9 holes"
            case .eighteen: return "18 holes"
            case .any: return "Either"
            }
        }

        public func matches(_ holes: Int) -> Bool {
            switch self {
            case .nine: return holes == 9
            case .eighteen: return holes == 18
            case .any: return true
            }
        }
    }
}
