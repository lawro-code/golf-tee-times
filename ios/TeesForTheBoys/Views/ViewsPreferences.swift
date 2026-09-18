import Foundation

/// The one place track C is allowed to persist anything.
///
/// There is exactly one seam so that a test never has to reach for
/// `UserDefaults.standard` and never has to clean up after itself. Ticket C4
/// stores its booking ledger through this same protocol; nothing else in the
/// track touches `UserDefaults` directly.
public protocol ViewsKeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// The shipping implementation.
public final class UserDefaultsViewsStore: ViewsKeyValueStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// The test and preview twin. Seeding it is how a test says "the user last
/// chose nine holes" without writing to the simulator's defaults.
public final class InMemoryViewsStore: ViewsKeyValueStore {
    private var values: [String: String]

    public init(seed: [String: String] = [:]) {
        self.values = seed
    }

    public func string(forKey key: String) -> String? {
        values[key]
    }

    public func set(_ value: String?, forKey key: String) {
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }
}

/// Typed accessors over the store. Keys live here and nowhere else.
public enum ViewsPreferences {

    /// Namespaced so a future preference cannot collide with a host app's key.
    public enum Key {
        public static let holes = "tees.views.holes"
    }

    /// The remembered hole count.
    ///
    /// Returns `.eighteen` when nothing is stored and when what is stored no
    /// longer decodes — a value written by an older build must degrade to the
    /// documented default rather than to `.any`, which would quietly start
    /// showing 9-hole rounds to someone who never asked for them.
    public static func holes(from store: ViewsKeyValueStore) -> SearchFilters.HolesFilter {
        guard let raw = store.string(forKey: Key.holes),
              let value = SearchFilters.HolesFilter(rawValue: raw)
        else { return .eighteen }
        return value
    }

    public static func setHoles(_ value: SearchFilters.HolesFilter, in store: ViewsKeyValueStore) {
        store.set(value.rawValue, forKey: Key.holes)
    }
}
