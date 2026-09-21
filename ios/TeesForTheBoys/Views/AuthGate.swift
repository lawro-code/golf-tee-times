import SwiftUI
import TeesDesign

/// Which auth screen a sheet is currently showing. `Identifiable` so one
/// `.sheet(item:)` can swap between the two without a second presentation.
public enum AuthSheetMode: String, Identifiable, Equatable, Sendable {
    case signIn
    case signUp

    public var id: String { rawValue }
}

/// The wall, as a value — so what it decides can be asserted without a render.
public enum AuthGatePresentation: Equatable, Sendable {
    /// Signed in: the wrapped content, unchanged and unwrapped.
    case content
    /// Signed out: the explanation and a way in.
    case wall

    public init(isSignedIn: Bool) {
        self = isSignedIn ? .content : .wall
    }

    /// Why an account is needed, in one sentence, phrased as a reason rather
    /// than a demand. Public so the copy can be asserted rather than drifting.
    public static let explanation =
        "Alerts need an account. It is where your watches live, so a tee time that opens at 6am can still reach you."

    public static let callToAction = "Sign in to set alerts"
}

/// Wraps the parts of the app that need an account.
///
/// **Browsing and search never pass through this.** The fifteen clubs, the tee
/// times, the filters and the prices are all readable signed out — RLS makes
/// reference and scraped data world-readable on purpose — and a wall in front
/// of them would kill the one thing that makes the app worth opening. The wall
/// goes in front of alerts, watches and bookings, and nowhere else.
///
/// It is in this ticket rather than its own because the wall and the alert
/// button are one flow: the wall only ever appears because somebody tried to
/// set an alert, which is why its explanation talks about alerts.
public struct AuthGate<Content: View>: View {

    private let isSignedIn: Bool
    private let actions: any AuthActions
    private let onSignedIn: () -> Void
    private let content: Content

    @State private var sheet: AuthSheetMode?

    public init(
        isSignedIn: Bool,
        actions: any AuthActions,
        onSignedIn: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.isSignedIn = isSignedIn
        self.actions = actions
        self.onSignedIn = onSignedIn
        self.content = content()
    }

    private var presentation: AuthGatePresentation {
        AuthGatePresentation(isSignedIn: isSignedIn)
    }

    public var body: some View {
        Group {
            switch presentation {
            case .content:
                content
            case .wall:
                wall
            }
        }
        .sheet(item: $sheet) { mode in
            switch mode {
            case .signIn:
                SignInScreen(
                    actions: actions,
                    onSignedIn: { finish() },
                    onCreateAccount: { sheet = .signUp }
                )
            case .signUp:
                SignUpScreen(
                    actions: actions,
                    onSignedUp: { finish() },
                    onSignInInstead: { sheet = .signIn }
                )
            }
        }
    }

    private var wall: some View {
        VStack(alignment: .leading, spacing: TeesSpacing.lg) {
            Image(systemName: "bell.badge")
                .font(.title)
                .foregroundStyle(TeesColor.green)
                .accessibilityHidden(true)
            Text(AuthGatePresentation.explanation)
                .font(TeesFont.body)
                .foregroundStyle(TeesColor.muted)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(AuthGatePresentation.callToAction) { sheet = .signIn }
                .buttonStyle(.teesPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TeesSpacing.xl)
        .background(TeesColor.background)
    }

    private func finish() {
        sheet = nil
        onSignedIn()
    }
}

#Preview("Signed out") {
    AuthGate(isSignedIn: false, actions: StubAuthActions()) {
        Text("Your alerts")
    }
}

#Preview("Signed in") {
    AuthGate(isSignedIn: true, actions: StubAuthActions()) {
        Text("Your alerts")
    }
}
