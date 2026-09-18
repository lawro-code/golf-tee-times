import SwiftUI
import XCTest
import TeesContract
@testable import TeesViews

/// The shell.
///
/// `TeesRootView` is the only file where all four track C tickets meet, and it
/// is meant to stay wiring — so there is very little here to assert, which is
/// the point. What is worth pinning down is the tab vocabulary (the search
/// screen hops to `.account` by name when an alert needs a sign-in, not by
/// index) and the return-trip contract the shell forwards `scenePhase` for.
@MainActor
final class TeesRootViewTests: XCTestCase {

    private let fixedNow = ContractDate.date(from: "2026-10-01T07:30:00+10:00")!

    private func store() -> SearchStore {
        let now = fixedNow
        let store = SearchStore(preferences: InMemoryViewsStore(), fixture: "minimal", now: { now })
        store.load()
        return store
    }

    private func ledger() -> BookingLedger {
        BookingLedger(store: InMemoryViewsStore(), now: { self.fixedNow })
    }

    // MARK: - The tabs

    func testThereAreExactlyThreeTabs() {
        XCTAssertEqual(TeesTab.allCases, [.search, .upcoming, .account])
    }

    /// Named, not numbered. `selection = .account` is what the search screen
    /// does when an alert needs a session, and a raw `2` there would survive a
    /// reorder silently.
    func testEveryTabHasAStableIdentityATitleAndAnIcon() {
        for tab in TeesTab.allCases {
            XCTAssertEqual(tab.id, tab.rawValue)
            XCTAssertFalse(tab.title.isEmpty, tab.rawValue)
            XCTAssertFalse(tab.systemImage.isEmpty, tab.rawValue)
        }

        XCTAssertEqual(TeesTab.search.title, "Search")
        XCTAssertEqual(TeesTab.upcoming.title, "Rounds")
        XCTAssertEqual(TeesTab.account.title, "Account")
    }

    /// No tab for friends, teams or invites. They are a later version, and a
    /// tab is the most expensive place to leave a hook for one.
    func testThereIsNoTabForAnythingOutOfScope() {
        let titles = TeesTab.allCases.map(\.title).joined(separator: " ").lowercased()
        for absent in ["friend", "team", "partner", "invite", "shuffle"] {
            XCTAssertFalse(titles.contains(absent), "\(absent) is out of scope for this version")
        }
    }

    // MARK: - The return trip

    /// The shell's only real job: forwarding `scenePhase` going `.active` to
    /// the ledger. A tap-out recorded on the way out has to become a question
    /// on the way back, and `.active` is the only signal that the trip ended.
    func testComingBackActivePromotesARecordedTapOutToThePrompt() throws {
        let payload = try ContractLoader.fixture("minimal")
        let slot = try XCTUnwrap(payload.slots.first)
        let ledger = ledger()

        ledger.recordTapOut(slot)
        XCTAssertNil(ledger.pendingConfirmation, "the question is asked on the way back, not on the way out")

        ledger.appDidBecomeActive()
        XCTAssertEqual(ledger.pendingConfirmation?.id, slot.id)
    }

    /// And with nothing recorded, coming back does nothing. An app that asks
    /// "did you book?" after an ordinary launch is the nagging this avoids.
    func testComingBackWithNoTapOutAsksNothing() {
        let ledger = ledger()
        ledger.appDidBecomeActive()
        XCTAssertNil(ledger.pendingConfirmation)
    }

    // MARK: - Construction

    /// Signed out is a first-class state: browsing works without an account,
    /// and the wall is in front of alerts rather than in front of tee times.
    func testShellConstructsSignedOut() {
        let view: any View = TeesRootView(
            store: store(),
            ledger: ledger(),
            email: nil,
            actions: StubAuthActions(),
            alerts: [],
            onCreateWatch: { _ in },
            onDeleteWatch: { _ in })
        XCTAssertTrue(view is TeesRootView)
    }

    func testShellConstructsSignedInWithAlerts() {
        let store = store()
        let draft = WatchDraft(filters: .standard, courses: store.courses, today: store.today)

        let view: any View = TeesRootView(
            store: store,
            ledger: ledger(),
            email: "golfer@example.com",
            actions: StubAuthActions(),
            alerts: [draft],
            onCreateWatch: { _ in },
            onDeleteWatch: { _ in })
        XCTAssertTrue(view is TeesRootView)
    }
}

// MARK: - Tester's pass, ticket C2

/// The tab vocabulary, pinned by its whole set rather than by its titles.
///
/// The suite above checks that no tab *title* mentions a friend, a team or an
/// invite. That would not notice a fourth tab that borrowed an existing title,
/// and a tab is the most expensive place in the app to leave a hook for a
/// feature this version is not building.
final class TeesTabVocabularyTests: XCTestCase {

    /// Exactly these three, by identity. Out of scope for this version and not
    /// to be scaffolded for: friend invites, copy-link joins, a friend graph,
    /// playing partners, saved teams, the team shuffle.
    func testTheTabSetIsExactlyThreeCasesAndNothingElse() {
        XCTAssertEqual(TeesTab.allCases.count, 3)
        XCTAssertEqual(Set(TeesTab.allCases.map(\.rawValue)), ["search", "upcoming", "account"])
    }

    /// Three tabs sharing an icon is a tab bar nobody can aim at. The titles
    /// are already asserted above; the icon is the half a thumb actually uses.
    func testEachTabCarriesItsOwnIconAndItsOwnTitle() {
        let icons = TeesTab.allCases.map(\.systemImage)
        XCTAssertEqual(Set(icons).count, icons.count, "two tabs share an icon: \(icons)")

        let titles = TeesTab.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two tabs share a title: \(titles)")
    }
}
