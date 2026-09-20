import SwiftUI
import XCTest
import TeesContract
import TeesDesign
@testable import TeesViews

/// Regression coverage for: the real "no results" screens rendered
/// `ViewsEmptyState` — `StateViews.swift`'s deliberately unstyled placeholder,
/// which is `VStack(spacing: 12) { Text(title).font(.headline); Text(message)
/// .font(.subheadline).foregroundStyle(.secondary); action }` — the exact
/// same shape as `ViewsErrorState`. No icon, no colour, nothing that tells a
/// golfer "we looked and there's nothing" apart from the words. `TeesDesign`
/// already ships `TeesEmptyState` for this — a muted gold flag and an italic
/// serif subline, built (its own doc comment says so) so "an empty screen
/// ... [doesn't read] as a failure" — but neither `SearchScreen`'s search-
/// matched-nothing state nor `UpcomingRoundsScreen`'s empty list ever called
/// it.
///
/// `ios/project.yml` is frozen for Stage 1 — no ViewInspector, no snapshot
/// library — so a rendered `body` cannot be asked "what does this look like".
/// What can be asked, and what this relies on: a SwiftUI `@ViewBuilder`
/// `if`/`switch` fixes ONE concrete generic type for a property at compile
/// time, and that type embeds every branch's own concrete view type in its
/// generic signature whether or not that branch is the one that runs for a
/// given instance. So the empty-state branch's chosen component shows up in
/// `body`'s full runtime type name for ANY instance of the screen — a fresh
/// install, a signed-out golfer, a search with results still on screen — not
/// only one manufactured into the empty case. Reflecting on that type name is
/// therefore a real assertion about which component the screen is wired to,
/// not a guess at SwiftUI's internals.
@MainActor
final class EmptyStateComponentUsageTests: XCTestCase {

    private func bodyTypeName<V: View>(_ view: V) -> String {
        String(reflecting: type(of: view.body))
    }

    /// `UpcomingRoundsScreen`'s empty branch must be the on-brand
    /// `TeesEmptyState`, not the plain `ViewsEmptyState` that reads identically
    /// to a failure.
    func testUpcomingRoundsScreenEmptyBranchUsesTheOnBrandEmptyState() {
        let ledger = BookingLedger(store: InMemoryViewsStore(), now: { Date(timeIntervalSince1970: 0) })
        let screen = UpcomingRoundsScreen(ledger: ledger, today: "2026-09-20")

        let typeName = bodyTypeName(screen)

        XCTAssertTrue(
            typeName.contains("TeesEmptyState"),
            "UpcomingRoundsScreen's empty branch is not TeesEmptyState: \(typeName)")
        XCTAssertFalse(
            typeName.contains("ViewsEmptyState"),
            "UpcomingRoundsScreen's empty branch still uses the plain ViewsEmptyState, " +
            "which is visually identical to ViewsErrorState: \(typeName)")
    }

    /// `SearchScreen`'s empty branch — a filter combination that matches
    /// nothing — must also be `TeesEmptyState`.
    func testSearchScreenEmptyBranchUsesTheOnBrandEmptyState() {
        let store = SearchStore(
            preferences: InMemoryViewsStore(),
            fixture: "minimal",
            now: { Date(timeIntervalSince1970: 0) })
        let screen = SearchScreen(
            store: store,
            ledger: BookingLedger(store: InMemoryViewsStore(), now: { Date(timeIntervalSince1970: 0) }),
            isSignedIn: false,
            onCreateWatch: { _ in true },
            onRequireSignIn: {})

        let typeName = bodyTypeName(screen)

        XCTAssertTrue(
            typeName.contains("TeesEmptyState"),
            "SearchScreen's empty branch is not TeesEmptyState: \(typeName)")
        XCTAssertFalse(
            typeName.contains("ViewsEmptyState"),
            "SearchScreen's empty branch still uses the plain ViewsEmptyState, " +
            "which is visually identical to ViewsErrorState: \(typeName)")
    }
}
