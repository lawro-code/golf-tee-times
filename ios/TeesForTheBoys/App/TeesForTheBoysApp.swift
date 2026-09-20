import SwiftUI
import TeesContract
import TeesData
import TeesDesign
import TeesPush
import TeesViews

/// Stage 2. Wires the five tracks together — nothing here is a track's own
/// logic, only the seams between them that the module boundaries deliberately
/// left for this file.
@main
struct TeesForTheBoysApp: App {

    /// The UIKit bridge `AppDelegate.swift`'s own doc comment says was
    /// missing: without this property, SwiftUI never installs `AppDelegate`
    /// as `UIApplication`'s delegate at all, so none of its methods — device
    /// token, foreground presentation, or a tapped notification — ever run,
    /// regardless of anything `AppSession` or `AppDelegate` itself does
    /// correctly in isolation.
    /// Not `private`: `AppDelegateWiringTests` (`@testable import`) reads it
    /// directly, since a hosted unit test's process never actually completes
    /// a real scene-connection launch — `UIApplication.shared.delegate` does
    /// not reliably reflect this adaptor there even when it is correctly
    /// declared, which is a property of how Xcode hosts unit tests, not of
    /// this code. Constructing `TeesForTheBoysApp` directly and reading its
    /// own `appDelegate` sidesteps that and tests the actual wiring instead.
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var session: AppSession

    /// Which tab is on screen. Lives here, not only inside `TeesRootView`,
    /// because landing a push route on the right tab means something outside
    /// that view has to be able to set it — see `session.pendingRoute` below.
    @State private var selection: TeesTab = .search

    /// `session` is assigned to `appDelegate` here, in `init()`, not in the
    /// `.task` below. `AppSession.pushCoordinator`'s own doc comment is why:
    /// a cold launch can hand `AppDelegate` a tap before `.task` has run at
    /// all, and `AppDelegate.session` has to already be set for that tap to
    /// reach `AppSession.handlePushTap` instead of being silently dropped by
    /// the `weak var session`'s `?.` on a nil session.
    ///
    /// `_session = StateObject(wrappedValue:)` rather than `self.session = `:
    /// reading `self.session` here, before this `App` is installed into
    /// SwiftUI's render graph, is the same "accessed before installed"
    /// mistake `@StateObject`'s own documentation warns against. Using the
    /// local `let` — the same instance either way — avoids it.
    @MainActor
    init() {
        let session = AppSession()
        _session = StateObject(wrappedValue: session)
        appDelegate.session = session
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let configurationFailure = session.configurationFailure {
                    ContentUnavailableView(
                        "Not configured",
                        systemImage: "exclamationmark.triangle",
                        description: Text(configurationFailure))
                } else {
                    TeesRootView(
                        store: session.searchStore,
                        ledger: session.ledger,
                        email: session.email,
                        actions: session,
                        alerts: session.alerts,
                        alertsLoadFailed: session.alertsLoadFailed,
                        onCreateWatch: session.createWatch,
                        onDeleteWatch: session.deleteWatch,
                        onRetryAlerts: session.refreshAlerts,
                        onSignedIn: session.refreshUserData,
                        onSignedOut: session.clearUserData,
                        onRetry: session.retrySearch,
                        onBecameActive: session.appDidBecomeActive,
                        selection: $selection)
                }
            }
            .task { await session.start() }
            .onChange(of: session.pendingRoute) { _, route in
                // The other half of a tap: `AppSession` already decoded it and
                // is holding it in `pendingRoute` (buffered through a cold
                // launch by `PushCoordinator`). This is what makes it land
                // somewhere instead of the app merely opening or resuming to
                // whatever tab it last showed. See `AppSession.tab(for:)`.
                guard let route else { return }
                selection = AppSession.tab(for: route)
                session.consumePendingRoute()
            }
        }
    }
}

/// `DataError.description` is already written for a screen — see
/// `SignInScreen.swift`'s doc comment on `AuthDisplayableError`. This is the
/// one line it says Stage 2 owes.
extension DataError: @retroactive AuthDisplayableError {
    public var displayMessage: String { description }
}
