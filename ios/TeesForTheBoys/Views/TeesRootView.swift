import SwiftUI
import TeesContract

/// The shell Stage 2 mounts: three tabs, the did-you-book prompt, and the
/// scene-phase forwarding that makes the prompt fire.
///
/// This is the only file in track C where all four tickets' views meet, so it
/// is kept to wiring on purpose. Every decision it might be tempted to make —
/// which state the list is in, whether an alert needs a sign-in, when a round
/// leaves the upcoming list — already belongs to a screen or to a store. If
/// something here starts needing a branch, the branch belongs in the thing
/// being wired.
///
/// The one piece of behaviour it does own is the return trip. A golfer taps
/// out to MiClub from `SlotDetailScreen`, books (or does not), and comes back
/// to the app minutes later; `scenePhase` going `.active` is the only signal
/// that the trip is over, and it arrives on the shell rather than on the
/// screen that started it.
public struct TeesRootView: View {
    @ObservedObject private var store: SearchStore
    @ObservedObject private var ledger: BookingLedger

    /// Non-nil means signed in. Browsing works signed out — the wall is in
    /// front of alerts, not in front of tee times.
    private let email: String?
    private let actions: any AuthActions
    private let alerts: [WatchDraft]
    private let onCreateWatch: (WatchDraft) -> Void
    private let onDeleteWatch: (WatchDraft) -> Void
    private let onSignedIn: () -> Void
    private let onSignedOut: () -> Void

    @State private var selection: TeesTab = .search
    @Environment(\.scenePhase) private var scenePhase

    public init(
        store: SearchStore,
        ledger: BookingLedger,
        email: String?,
        actions: any AuthActions,
        alerts: [WatchDraft],
        onCreateWatch: @escaping (WatchDraft) -> Void,
        onDeleteWatch: @escaping (WatchDraft) -> Void,
        onSignedIn: @escaping () -> Void = {},
        onSignedOut: @escaping () -> Void = {}
    ) {
        self.store = store
        self.ledger = ledger
        self.email = email
        self.actions = actions
        self.alerts = alerts
        self.onCreateWatch = onCreateWatch
        self.onDeleteWatch = onDeleteWatch
        self.onSignedIn = onSignedIn
        self.onSignedOut = onSignedOut
    }

    public var body: some View {
        TabView(selection: $selection) {
            // SearchScreen brings its own NavigationStack; the other two do not.
            SearchScreen(
                store: store,
                ledger: ledger,
                isSignedIn: email != nil,
                onCreateWatch: onCreateWatch,
                onRequireSignIn: { selection = .account })
                .tabItem { Label(TeesTab.search.title, systemImage: TeesTab.search.systemImage) }
                .tag(TeesTab.search)

            NavigationStack {
                UpcomingRoundsScreen(ledger: ledger, today: store.today)
            }
            .tabItem { Label(TeesTab.upcoming.title, systemImage: TeesTab.upcoming.systemImage) }
            .tag(TeesTab.upcoming)

            NavigationStack {
                // Signed out, AccountScreen is SignInScreen — the only reason
                // to open this tab without a session is to start one.
                AccountScreen(
                    email: email,
                    actions: actions,
                    alerts: alerts,
                    onDelete: onDeleteWatch,
                    onSignedIn: onSignedIn,
                    onSignedOut: onSignedOut)
            }
            .tabItem { Label(TeesTab.account.title, systemImage: TeesTab.account.systemImage) }
            .tag(TeesTab.account)
        }
        .didYouBookPrompt(ledger: ledger)
        .onChange(of: scenePhase) { _, phase in
            // The return from MiClub. `.active` is the only moment the app
            // learns the trip is over, so the question is asked from here.
            if phase == .active { ledger.appDidBecomeActive() }
        }
    }
}

/// The three tabs.
///
/// A named type rather than integer tags so the "sign in required" hop out of
/// the search screen is `selection = .account` rather than `selection = 2`.
public enum TeesTab: String, CaseIterable, Identifiable, Sendable {
    case search
    case upcoming
    case account

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .search: return "Search"
        case .upcoming: return "Rounds"
        case .account: return "Account"
        }
    }

    public var systemImage: String {
        switch self {
        case .search: return "magnifyingglass"
        case .upcoming: return "calendar"
        case .account: return "person.crop.circle"
        }
    }
}

#if DEBUG
#Preview("Root \u{2014} signed out") {
    TeesRootView(
        store: SearchStore.previewStore(fixture: "golden"),
        ledger: BookingLedger(store: InMemoryViewsStore()),
        email: nil,
        actions: StubAuthActions(),
        alerts: [],
        onCreateWatch: { _ in },
        onDeleteWatch: { _ in })
}
#endif
