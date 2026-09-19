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
    @StateObject private var session = AppSession()

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
                        onCreateWatch: session.createWatch,
                        onDeleteWatch: session.deleteWatch,
                        onSignedIn: session.refreshUserData,
                        onSignedOut: session.clearUserData)
                }
            }
            .task { await session.start() }
        }
    }
}

/// `DataError.description` is already written for a screen — see
/// `SignInScreen.swift`'s doc comment on `AuthDisplayableError`. This is the
/// one line it says Stage 2 owes.
extension DataError: @retroactive AuthDisplayableError {
    public var displayMessage: String { description }
}
