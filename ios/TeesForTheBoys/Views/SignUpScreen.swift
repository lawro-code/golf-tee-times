import SwiftUI

/// The same form as `SignInScreen`, with the one line that matters on it.
///
/// A golfer only ever reaches this screen because they tried to set an alert,
/// so the explanation says exactly that and nothing else. No marketing, no
/// feature list, no profile step: the account exists to make an alert reach
/// someone, and asking for anything more at this moment is asking for a reason
/// to close the app.
public struct SignUpScreen: View {

    @StateObject private var model: AuthFormViewModel
    @FocusState private var focus: AuthFormViewModel.Field?

    /// Shown under the fields, for the golfer who already has an account.
    private let onSignInInstead: (() -> Void)?

    public init(
        actions: any AuthActions,
        onSignedUp: @escaping () -> Void = {},
        onSignInInstead: (() -> Void)? = nil
    ) {
        _model = StateObject(
            wrappedValue: AuthFormViewModel(mode: .signUp, actions: actions, onSuccess: onSignedUp)
        )
        self.onSignInInstead = onSignInInstead
    }

    public var body: some View {
        AuthForm(
            title: "Create an account",
            // The one line. It says what the account is for: alerts.
            explanation: "An account is only used for alerts \u{2014} it is how we reach you when a tee time you want opens up.",
            model: model,
            focus: $focus,
            // `.newPassword` rather than `.password`: it is what makes the
            // keychain offer to generate and save a strong one instead of
            // trying to fill an existing one.
            passwordContentType: .newPassword,
            footer: {
                if let onSignInInstead {
                    Button("Already have an account? Sign in", action: onSignInInstead)
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
            }
        )
    }
}

#Preview("Sign up") {
    SignUpScreen(actions: StubAuthActions(), onSignInInstead: {})
}
