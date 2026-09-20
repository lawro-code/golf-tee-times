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
    private let alertsLoadFailed: Bool
    private let onCreateWatch: (WatchDraft) async -> Bool
    private let onDeleteWatch: (WatchDraft) -> Void
    private let onRetryAlerts: () -> Void
    private let onSignedIn: () -> Void
    private let onSignedOut: () -> Void
    private let onRetry: (() -> Void)?
    private let onBecameActive: () -> Void

    @State private var selection: TeesTab = .search
    @Environment(\.scenePhase) private var scenePhase

    /// Lets something outside this view (Stage 2 assembly) put a specific tab
    /// on screen — a tapped push notification routing to the tab that can show
    /// what it named, say. `nil` (every existing call site, every preview,
    /// every test) keeps `selection` as this view's own `@State`, unchanged
    /// from before this existed.
    private let externalSelection: Binding<TeesTab>?

    /// What `TabView` actually binds to: the caller's binding when it supplied
    /// one, this view's own state otherwise.
    private var activeSelection: Binding<TeesTab> {
        externalSelection ?? $selection
    }

    public init(
        store: SearchStore,
        ledger: BookingLedger,
        email: String?,
        actions: any AuthActions,
        alerts: [WatchDraft],
        alertsLoadFailed: Bool = false,
        onCreateWatch: @escaping (WatchDraft) async -> Bool,
        onDeleteWatch: @escaping (WatchDraft) -> Void,
        onRetryAlerts: @escaping () -> Void = {},
        onSignedIn: @escaping () -> Void = {},
        onSignedOut: @escaping () -> Void = {},
        onRetry: (() -> Void)? = nil,
        onBecameActive: @escaping () -> Void = {},
        selection: Binding<TeesTab>? = nil
    ) {
        self.store = store
        self.ledger = ledger
        self.email = email
        self.actions = actions
        self.alerts = alerts
        self.alertsLoadFailed = alertsLoadFailed
        self.onCreateWatch = onCreateWatch
        self.onDeleteWatch = onDeleteWatch
        self.onRetryAlerts = onRetryAlerts
        self.onSignedIn = onSignedIn
        self.onSignedOut = onSignedOut
        self.onRetry = onRetry
        self.onBecameActive = onBecameActive
        self.externalSelection = selection
    }

    public var body: some View {
        TabView(selection: activeSelection) {
            // SearchScreen brings its own NavigationStack; the other two do not.
            SearchScreen(
                store: store,
                ledger: ledger,
                isSignedIn: email != nil,
                onCreateWatch: onCreateWatch,
                onRequireSignIn: { selection = .account },
                onRetry: onRetry)
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
                    alertsLoadFailed: alertsLoadFailed,
                    onDelete: onDeleteWatch,
                    onRetryAlerts: onRetryAlerts,
                    onSignedIn: onSignedIn,
                    onSignedOut: onSignedOut)
            }
            .tabItem { Label(TeesTab.account.title, systemImage: TeesTab.account.systemImage) }
            .tag(TeesTab.account)
        }
        .didYouBookPrompt(ledger: ledger)
        .onChange(of: scenePhase) { _, phase in
            // The return from MiClub — or from anywhere else the app was
            // backgrounded, including an idle phone left suspended for hours.
            // `.active` is the only signal a scene gives that this happened,
            // so it is both when the did-you-book question is asked and the
            // only remaining trigger (besides the one cold-launch fetch) that
            // ever asks the data track to check staleness again.
            if phase == .active {
                ledger.appDidBecomeActive()
                onBecameActive()
            }
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
        onCreateWatch: { _ in true },
        onDeleteWatch: { _ in })
}
#endif
