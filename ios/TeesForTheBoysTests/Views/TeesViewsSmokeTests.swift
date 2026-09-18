import XCTest
@testable import TeesViews

/// The module surface. Stage 0 left this file asserting only that the module
/// links; it now also names the types the other three Track C tickets are being
/// written against. Those names are a contract — if one is renamed or loses its
/// `public`, this file stops compiling, which is the point.
final class TeesViewsSmokeTests: XCTestCase {

    func testModuleLinks() {
        XCTAssertFalse(TeesViewsModule.version.isEmpty)
        XCTAssertNotEqual(
            TeesViewsModule.version, "0",
            "still reporting the Stage 0 placeholder version")
    }

    /// One reference to each public type the search spine exports, reached
    /// through its public name from outside the file that declares it.
    func testTheSpineIsReachableByItsPublicNames() {
        XCTAssertEqual(SearchFilters.standard.holes, .eighteen)
        XCTAssertEqual(SearchFilters.HolesFilter.nine.title, "9 holes")
        XCTAssertEqual(SearchFilters.TimeOfDay.allCases.count, 5)
        XCTAssertEqual(SlotFormatting.priceAtCourse, "Price at course")
        XCTAssertEqual(SlotFormatting.dayTitle(for: "2026-10-03", today: "2026-10-03"), "Today")
        XCTAssertTrue(SlotQuery.apply(.standard, to: []).isEmpty)
        XCTAssertTrue(SlotQuery.sections([], today: "2026-10-03", priceFilterActive: false).isEmpty)
        XCTAssertNil(FreshnessSummary.unknown.bannerText)
        XCTAssertEqual(ViewsPreferences.holes(from: InMemoryViewsStore()), .eighteen)
        XCTAssertEqual(
            SlotDaySection(date: "2026-10-03", title: "Today", results: []).id, "2026-10-03")
    }

    /// `SearchStore` is `@MainActor`, so it gets its own hop. Everything else
    /// above is a value type or a pure function and needs none.
    @MainActor
    func testStoreIsReachableAndStartsIdle() {
        let store = SearchStore(preferences: InMemoryViewsStore(), fixture: "minimal")
        XCTAssertEqual(store.state, .idle)
    }
}
