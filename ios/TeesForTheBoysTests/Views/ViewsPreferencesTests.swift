import XCTest
@testable import TeesViews

/// The track's only persistence seam, so it is worth proving that the default
/// survives every way the stored value can be wrong.
final class ViewsPreferencesTests: XCTestCase {

    // MARK: - The default

    func testAbsentValueReadsAsEighteen() {
        XCTAssertEqual(ViewsPreferences.holes(from: InMemoryViewsStore()), .eighteen)
    }

    /// A value written by an older or newer build must degrade to 18, not to
    /// `.any` — `.any` would quietly start showing 9-hole rounds to someone who
    /// never asked for them, which is the exact failure CONTRACT.md §2 warns
    /// about.
    func testUnreadableValueReadsAsEighteen() {
        for junk in ["", "9", "NINE", "eighteen-ish", "{\"holes\":9}"] {
            let store = InMemoryViewsStore(seed: [ViewsPreferences.Key.holes: junk])
            XCTAssertEqual(ViewsPreferences.holes(from: store), .eighteen, "junk: \(junk)")
        }
    }

    // MARK: - Round trip

    func testEveryCaseRoundTrips() {
        for value in SearchFilters.HolesFilter.allCases {
            let store = InMemoryViewsStore()
            ViewsPreferences.setHoles(value, in: store)
            XCTAssertEqual(ViewsPreferences.holes(from: store), value)
        }
    }

    func testSeedingIsHowATestSaysTheUserLastChoseNine() {
        let store = InMemoryViewsStore(seed: [ViewsPreferences.Key.holes: "nine"])
        XCTAssertEqual(ViewsPreferences.holes(from: store), .nine)
    }

    func testLatestWriteWins() {
        let store = InMemoryViewsStore()
        ViewsPreferences.setHoles(.nine, in: store)
        ViewsPreferences.setHoles(.any, in: store)
        XCTAssertEqual(ViewsPreferences.holes(from: store), .any)
    }

    // MARK: - The key

    /// The key is storage. Changing it does not reset a preference, it orphans
    /// one — the old value stays on disk forever and the golfer's choice
    /// silently reverts to 18.
    func testKeyIsNamespacedAndStable() {
        XCTAssertEqual(ViewsPreferences.Key.holes, "tees.views.holes")
    }

    // MARK: - The two implementations agree

    func testInMemoryStoreClearsOnNil() {
        let store = InMemoryViewsStore(seed: ["k": "v"])
        store.set(nil, forKey: "k")
        XCTAssertNil(store.string(forKey: "k"))
    }

    /// A throwaway suite rather than `.standard`, so this test leaves nothing
    /// behind in the simulator for the next one to trip over.
    func testUserDefaultsStoreReadsAndWrites() throws {
        let name = "tees.views.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let store = UserDefaultsViewsStore(defaults: defaults)
        XCTAssertEqual(ViewsPreferences.holes(from: store), .eighteen)

        ViewsPreferences.setHoles(.nine, in: store)
        XCTAssertEqual(ViewsPreferences.holes(from: store), .nine)
        XCTAssertEqual(
            UserDefaultsViewsStore(defaults: defaults).string(forKey: ViewsPreferences.Key.holes),
            "nine",
            "a second store over the same defaults sees the write")

        store.set(nil, forKey: ViewsPreferences.Key.holes)
        XCTAssertNil(store.string(forKey: ViewsPreferences.Key.holes))
    }
}
