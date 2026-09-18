import SwiftUI

/// The account tab: who you are, and what you are watching.
///
/// Deliberately small. There is no display name, no avatar, no notification
/// preferences and no theme picker — every one of those is a screen somebody
/// has to maintain and nobody asked for. An account exists so an alert can
/// reach a person, so this screen shows the address it would reach, the alerts
/// it would carry, and the way out.
///
/// Signed out it is simply `SignInScreen`, because the only reason to open the
/// account tab signed out is to sign in.
public struct AccountScreen: View {

    /// Non-nil means signed in. The address is the account, so it is also the
    /// signed-in test — there is nothing else on this screen that needs a user
    /// id.
    private let email: String?
    private let actions: any AuthActions
    private let alerts: [WatchDraft]
    private let onDelete: (WatchDraft) -> Void
    private let onSignedIn: () -> Void
    private let onSignedOut: () -> Void

    @State private var sheet: AuthSheetMode?
    @State private var isSigningOut = false
    @State private var signOutError: String?

    public init(
        email: String?,
        actions: any AuthActions,
        alerts: [WatchDraft],
        onDelete: @escaping (WatchDraft) -> Void,
        onSignedIn: @escaping () -> Void = {},
        onSignedOut: @escaping () -> Void = {}
    ) {
        self.email = email
        self.actions = actions
        self.alerts = alerts
        self.onDelete = onDelete
        self.onSignedIn = onSignedIn
        self.onSignedOut = onSignedOut
    }

    public var body: some View {
        Group {
            if let email {
                signedIn(email)
            } else {
                SignInScreen(
                    actions: actions,
                    onSignedIn: onSignedIn,
                    onCreateAccount: { sheet = .signUp }
                )
            }
        }
        .sheet(item: $sheet) { mode in
            switch mode {
            case .signUp:
                SignUpScreen(
                    actions: actions,
                    onSignedUp: {
                        sheet = nil
                        onSignedIn()
                    },
                    onSignInInstead: { sheet = nil }
                )
            case .signIn:
                SignInScreen(
                    actions: actions,
                    onSignedIn: {
                        sheet = nil
                        onSignedIn()
                    }
                )
            }
        }
    }

    // MARK: - Signed in

    private func signedIn(_ email: String) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signed in as")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(email)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                Button(role: .destructive) {
                    signOut()
                } label: {
                    HStack(spacing: 8) {
                        if isSigningOut {
                            ProgressView().accessibilityHidden(true)
                        }
                        Text("Sign out")
                    }
                    .frame(minHeight: 44)
                }
                .disabled(isSigningOut)

                if let signOutError {
                    Text(signOutError)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                if alerts.isEmpty {
                    Text("No alerts yet. Search for a tee time you want and tap the alert button.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(alerts) { alert in
                        row(alert)
                    }
                    .onDelete { offsets in
                        for index in offsets where alerts.indices.contains(index) {
                            onDelete(alerts[index])
                        }
                    }
                }
            } header: {
                Text("Your alerts")
            } footer: {
                Text("We check every 20 minutes for the next three days, and twice a day after that.")
            }
        }
    }

    private func row(_ alert: WatchDraft) -> some View {
        Text(alert.sentence)
            .font(.subheadline)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
            // Swiping is not discoverable with VoiceOver on, so the same delete
            // is offered as a rotor action carrying the sentence it removes.
            .accessibilityLabel(Text(alert.sentence))
            .accessibilityAction(named: Text("Delete this alert")) { onDelete(alert) }
    }

    // `@MainActor` so the `Task` below inherits the main actor and the `@State`
    // writes after the await happen where SwiftUI expects them.
    @MainActor
    private func signOut() {
        signOutError = nil
        isSigningOut = true
        Task {
            do {
                try await actions.signOut()
                onSignedOut()
            } catch {
                signOutError = AuthFormViewModel.displayText(for: error)
            }
            isSigningOut = false
        }
    }
}

#Preview("Signed in") {
    AccountScreen(
        email: "will@example.com",
        actions: StubAuthActions(),
        alerts: [
            WatchDraft(
                filters: SearchFilters(days: ["2026-09-19"], timesOfDay: [.morning]),
                courses: [],
                today: "2026-09-18"
            )
        ],
        onDelete: { _ in }
    )
}

#Preview("Signed out") {
    AccountScreen(email: nil, actions: StubAuthActions(), alerts: [], onDelete: { _ in })
}
