import Combine
import SwiftUI
import UIKit

// MARK: - The seam

/// Everything this track needs from auth, and nothing else.
///
/// Track C does not import `TeesData` and never will — signing in is a callback
/// out of this module, wired to `AuthService` in Stage 2. The three methods
/// match Supabase Auth's shape exactly (ticket B is building that side), so the
/// adapter Stage 2 writes is three one-line forwards and no translation.
///
/// It is `AnyObject` because the implementation owns a session and is a
/// reference type on both sides of the seam.
public protocol AuthActions: AnyObject {
    func signIn(email: String, password: String) async throws
    func signUp(email: String, password: String) async throws
    func signOut() async throws
}

/// An error that already knows how to say itself to a person.
///
/// The opt-in exists because `error as? CustomStringConvertible` always
/// succeeds in Swift, so there is no way to ask an arbitrary `Error` whether it
/// has real copy — only to be told. Track B's `DataError.description` is
/// already written for a screen ("You are offline. Showing the last tee times
/// we saved."), so Stage 2's conformance is one line and nothing has to be
/// translated twice.
public protocol AuthDisplayableError: Error {
    var displayMessage: String { get }
}

/// The previews-and-tests twin.
///
/// Records what it was asked to do and, optionally, throws instead. That is
/// enough to assert the two things that matter: that a malformed email never
/// reaches it, and that an error it throws comes out the other side as text a
/// person can read.
public final class StubAuthActions: AuthActions {

    public struct Call: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case signIn, signUp, signOut
        }
        public let kind: Kind
        public let email: String
        public let password: String

        public init(kind: Kind, email: String = "", password: String = "") {
            self.kind = kind
            self.email = email
            self.password = password
        }
    }

    /// Thrown by every call when set. The point of the type is what the screen
    /// does with it, not what it is.
    public var error: Error?

    public private(set) var calls: [Call] = []

    public init(error: Error? = nil) {
        self.error = error
    }

    public func signIn(email: String, password: String) async throws {
        calls.append(Call(kind: .signIn, email: email, password: password))
        if let error { throw error }
    }

    public func signUp(email: String, password: String) async throws {
        calls.append(Call(kind: .signUp, email: email, password: password))
        if let error { throw error }
    }

    public func signOut() async throws {
        calls.append(Call(kind: .signOut))
        if let error { throw error }
    }
}

// MARK: - The view model

/// Sign in and sign up are the same form with a different verb, so they are the
/// same view model.
///
/// Everything worth asserting lives here rather than in a `body`:
/// `ios/project.yml` is frozen, there is no ViewInspector, and a validation rule
/// that only exists inside a button's action is a rule no test can see.
@MainActor
public final class AuthFormViewModel: ObservableObject {

    public enum Mode: Equatable, Sendable {
        case signIn
        case signUp
    }

    /// The same floor `AuthService` enforces. Supabase would refuse a shorter
    /// password anyway — but it refuses after a round trip, and saying so
    /// locally is instant.
    public static let minimumPasswordLength = 8

    @Published public var email: String = ""
    @Published public var password: String = ""

    /// True only while a call is actually in flight. Bound to the button's
    /// spinner and its disabled state, so a double tap cannot send twice.
    @Published public private(set) var isWorking = false

    /// A sentence to show the golfer. Never a raw error dump, never nil after a
    /// failure — a silent failure is the one outcome this screen may not have.
    @Published public private(set) var errorText: String?

    /// Which field to put the red ring around, when the failure was local.
    @Published public private(set) var invalidField: Field?

    public let mode: Mode
    private let actions: any AuthActions
    private let onSuccess: () -> Void

    public init(
        mode: Mode,
        actions: any AuthActions,
        onSuccess: @escaping () -> Void = {}
    ) {
        self.mode = mode
        self.actions = actions
        self.onSuccess = onSuccess
    }

    public enum Field: String, Equatable, Sendable {
        case email
        case password
    }

    public var submitTitle: String {
        mode == .signIn ? "Sign in" : "Create account"
    }

    /// Never false because the form looks incomplete. An empty field is told
    /// about on submit, in words, rather than by a button that does nothing and
    /// explains nothing.
    public var canSubmit: Bool { !isWorking }

    // MARK: Submitting

    public func submit() async {
        errorText = nil
        invalidField = nil

        if let problem = Self.validationProblem(email: email, password: password) {
            errorText = problem.message
            invalidField = problem.field
            return
        }

        isWorking = true
        defer { isWorking = false }

        let address = Self.normalisedEmail(email)
        do {
            switch mode {
            case .signIn:
                try await actions.signIn(email: address, password: password)
            case .signUp:
                try await actions.signUp(email: address, password: password)
            }
            onSuccess()
        } catch {
            errorText = Self.displayText(for: error)
        }
    }

    // MARK: Local validation

    public struct ValidationProblem: Equatable, Sendable {
        public let field: Field
        public let message: String

        public init(field: Field, message: String) {
            self.field = field
            self.message = message
        }
    }

    /// Enough of a check to catch a typo and an empty field, and no more. The
    /// server is the authority on whether an address exists; this only saves a
    /// round trip that was never going to succeed.
    ///
    /// The wording matches `AuthService`'s deliberately: the same mistake must
    /// not get two different explanations depending on whether it was caught
    /// here or there.
    public static func validationProblem(email: String, password: String) -> ValidationProblem? {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            return ValidationProblem(field: .email, message: "Enter your email address.")
        }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        let looksLikeAnAddress =
            parts.count == 2
            && !parts[0].isEmpty
            && parts[1].contains(".")
            && !parts[1].hasPrefix(".")
            && !parts[1].hasSuffix(".")
            && !address.contains(" ")
        guard looksLikeAnAddress else {
            return ValidationProblem(
                field: .email, message: "That does not look like an email address.")
        }
        guard password.count >= minimumPasswordLength else {
            return ValidationProblem(
                field: .password,
                message: "Use at least \(minimumPasswordLength) characters.")
        }
        return nil
    }

    public static func normalisedEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Turn anything thrown at this screen into a sentence.
    ///
    /// Two opt-ins, then a fallback. `AuthDisplayableError` is the seam for an
    /// error type that already holds screen-ready copy — track B's `DataError`
    /// is exactly that, and Stage 2 conforms it in one line. `LocalizedError`
    /// catches the system's own (`URLError` and friends).
    ///
    /// Anything else gets the plain fallback rather than `localizedDescription`,
    /// which for a bare `Error` renders as "The operation couldn't be completed.
    /// (TeesViews.Foo error 1.)" — the exact raw dump this screen is not allowed
    /// to show. Casting to `CustomStringConvertible` is not an option either:
    /// every `Error` satisfies it, so `String(describing:)` on a plain struct
    /// would leak "Foo()" onto the screen.
    public static func displayText(for error: Error) -> String {
        if let displayable = error as? AuthDisplayableError {
            let text = displayable.displayMessage
            if !text.isEmpty { return text }
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return "Something went wrong. Try again in a moment."
    }
}

// MARK: - The screen

/// Email and password, and the one line of explanation each screen owes.
public struct SignInScreen: View {

    @StateObject private var model: AuthFormViewModel
    @FocusState private var focus: AuthFormViewModel.Field?

    /// Shown under the fields. `AccountScreen` passes an action that opens
    /// `SignUpScreen`; a caller with nowhere to go passes nil and the row
    /// disappears.
    private let onCreateAccount: (() -> Void)?

    public init(
        actions: any AuthActions,
        onSignedIn: @escaping () -> Void = {},
        onCreateAccount: (() -> Void)? = nil
    ) {
        _model = StateObject(
            wrappedValue: AuthFormViewModel(mode: .signIn, actions: actions, onSuccess: onSignedIn)
        )
        self.onCreateAccount = onCreateAccount
    }

    public var body: some View {
        AuthForm(
            title: "Sign in",
            explanation: "Your alerts live on your account, so they keep watching when the app is closed.",
            model: model,
            focus: $focus,
            passwordContentType: .password,
            footer: {
                if let onCreateAccount {
                    Button("New here? Create an account", action: onCreateAccount)
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
            }
        )
    }
}

#Preview("Sign in") {
    SignInScreen(actions: StubAuthActions(), onCreateAccount: {})
}

// MARK: - The shared form

/// The body both auth screens share.
///
/// Sign in and sign up differ by a verb, one line of explanation and the
/// password content type — everything else about them is identical, and two
/// copies of a text field is two places for the accessibility to rot.
///
/// The accessibility rules this enforces, which are the ticket rather than a
/// nicety:
///
/// - every field has a visible label **above** it, not only a placeholder,
///   because a placeholder vanishes the moment someone types into it;
/// - `textContentType` and `keyboardType` are set, so the keychain offers the
///   saved password and the keyboard shows an `@`;
/// - nothing is clipped at AX5: the whole form scrolls and every label is
///   `fixedSize(horizontal: false, vertical: true)`;
/// - focus moves email → password → submit, which is the order a person reading
///   the screen aloud would expect.
struct AuthForm<Footer: View>: View {

    let title: String
    let explanation: String
    @ObservedObject var model: AuthFormViewModel
    @FocusState.Binding var focus: AuthFormViewModel.Field?
    let passwordContentType: UITextContentType
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.largeTitle.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                field(
                    label: "Email",
                    invalid: model.invalidField == .email
                ) {
                    TextField("you@example.com", text: $model.email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                        .accessibilityLabel(Text("Email"))
                }

                field(
                    label: "Password",
                    invalid: model.invalidField == .password
                ) {
                    SecureField(
                        "At least \(AuthFormViewModel.minimumPasswordLength) characters",
                        text: $model.password
                    )
                    .textContentType(passwordContentType)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit { submit() }
                    .accessibilityLabel(Text("Password"))
                }

                if let errorText = model.errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(errorText))
                }

                Button(action: submit) {
                    HStack(spacing: 8) {
                        if model.isWorking {
                            ProgressView()
                                .accessibilityHidden(true)
                        }
                        Text(model.isWorking ? "One moment\u{2026}" : model.submitTitle)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmit)
                .accessibilityLabel(Text(model.submitTitle))

                footer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { focus = .email }
    }

    @MainActor
    private func submit() {
        Task { await model.submit() }
    }

    @ViewBuilder
    private func field(
        label: String,
        invalid: Bool,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.red, lineWidth: invalid ? 1.5 : 0)
                )
        }
    }
}
