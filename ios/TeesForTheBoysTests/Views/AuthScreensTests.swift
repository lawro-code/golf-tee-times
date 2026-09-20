import XCTest
@testable import TeesViews

/// Sign in and sign up, from the view model down.
///
/// Two rules are being defended here. A mistake the app can see is caught
/// locally and explained in words — a round trip that was never going to
/// succeed is a second of a golfer's life and a worse error message. And a
/// failure that does come back from the server becomes readable text, never a
/// raw dump and never silence.
@MainActor
final class AuthScreensTests: XCTestCase {

    // MARK: - Errors the tests throw at the screen

    /// The seam track B's `DataError` will use: copy that is already written
    /// for a person to read.
    private struct DisplayableFailure: AuthDisplayableError {
        let displayMessage: String
    }

    /// What the system throws — `URLError` and friends.
    private struct LocalizedFailure: LocalizedError {
        var errorDescription: String? { "That email or password is not right." }
    }

    /// An error with nothing to say. Its `localizedDescription` is the
    /// "The operation couldn't be completed. (TeesViews.BareFailure error 1.)"
    /// dump that must never reach a screen.
    private struct BareFailure: Error {}

    // MARK: - Local validation

    func testAnEmptyEmailIsCaughtAndNamed() {
        let problem = AuthFormViewModel.validationProblem(email: "  ", password: "longenough")
        XCTAssertEqual(problem?.field, .email)
        XCTAssertEqual(problem?.message, "Enter your email address.")
    }

    func testAMalformedEmailIsCaught() {
        let malformed = [
            "willexample.com",      // no @
            "will@example",         // no dot in the domain
            "@example.com",         // no local part
            "will@.com",            // domain starts with a dot
            "will@example.",        // domain ends with a dot
            "will @example.com"     // a space
        ]
        for address in malformed {
            let problem = AuthFormViewModel.validationProblem(
                email: address, password: "longenough")
            XCTAssertEqual(
                problem?.field, .email, "\(address) should have been rejected")
            XCTAssertEqual(problem?.message, "That does not look like an email address.")
        }
    }

    func testAShortPasswordIsCaughtAndSaysHowShort() {
        let problem = AuthFormViewModel.validationProblem(
            email: "will@example.com", password: "sevench")
        XCTAssertEqual(problem?.field, .password)
        XCTAssertEqual(problem?.message, "Use at least 8 characters.")
        XCTAssertEqual(AuthFormViewModel.minimumPasswordLength, 8)
    }

    func testAGoodEmailAndPasswordPass() {
        XCTAssertNil(
            AuthFormViewModel.validationProblem(
                email: "will@example.com", password: "eightchars"))
        XCTAssertNil(
            AuthFormViewModel.validationProblem(
                email: "will.lawrence+golf@sub.example.com", password: "12345678"))
    }

    // MARK: - Nothing invalid reaches the network

    func testAMalformedEmailNeverReachesAuth() async {
        let stub = StubAuthActions()
        let model = AuthFormViewModel(mode: .signIn, actions: stub)
        model.email = "willexample.com"
        model.password = "eightchars"

        await model.submit()

        XCTAssertTrue(stub.calls.isEmpty, "A local validation failure must not make a call")
        XCTAssertEqual(model.errorText, "That does not look like an email address.")
        XCTAssertEqual(model.invalidField, .email)
        XCTAssertFalse(model.isWorking)
    }

    func testAShortPasswordNeverReachesAuth() async {
        let stub = StubAuthActions()
        let model = AuthFormViewModel(mode: .signUp, actions: stub)
        model.email = "will@example.com"
        model.password = "short"

        await model.submit()

        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertEqual(model.errorText, "Use at least 8 characters.")
        XCTAssertEqual(model.invalidField, .password)
    }

    // MARK: - VoiceOver hears about a local validation failure too

    /// The bug: a red ring is invisible to VoiceOver, and the field's
    /// accessibility label used to stay the plain "Email"/"Password" no
    /// matter what failed. A screen-reader user exploring the form after a
    /// failed submit has to be told *which* field is wrong and *why* — the
    /// label is the only channel VoiceOver has, so it has to say both.
    func testTheInvalidFieldsLabelNamesTheReason() async {
        let stub = StubAuthActions()
        let model = AuthFormViewModel(mode: .signIn, actions: stub)
        model.email = "willexample.com"
        model.password = "eightchars"

        await model.submit()

        XCTAssertEqual(
            model.accessibleLabel(for: .email, defaultText: "Email"),
            "Email. That does not look like an email address.",
            "VoiceOver on the failed field must say why it failed, not just its name")
    }

    func testTheFieldThatDidNotFailKeepsItsPlainLabel() async {
        let stub = StubAuthActions()
        let model = AuthFormViewModel(mode: .signUp, actions: stub)
        model.email = "will@example.com"
        model.password = "short"

        await model.submit()

        XCTAssertEqual(model.invalidField, .password)
        XCTAssertEqual(
            model.accessibleLabel(for: .email, defaultText: "Email"), "Email",
            "Only the field that actually failed should carry the explanation")
    }

    /// Before any submit, and again after a successful one, every field reads
    /// as itself — nothing left over from a previous failure.
    func testFieldLabelsArePlainOutsideOfAFailure() async {
        let stub = StubAuthActions()
        let model = AuthFormViewModel(mode: .signIn, actions: stub)
        XCTAssertEqual(model.accessibleLabel(for: .email, defaultText: "Email"), "Email")
        XCTAssertEqual(model.accessibleLabel(for: .password, defaultText: "Password"), "Password")

        model.email = "will@example.com"
        model.password = "eightchars"
        await model.submit()

        XCTAssertEqual(model.accessibleLabel(for: .email, defaultText: "Email"), "Email")
        XCTAssertEqual(model.accessibleLabel(for: .password, defaultText: "Password"), "Password")
    }

    // MARK: - The happy path

    func testSigningInSendsTheTrimmedLowercasedAddressAndReportsSuccess() async {
        let stub = StubAuthActions()
        var signedIn = 0
        let model = AuthFormViewModel(mode: .signIn, actions: stub, onSuccess: { signedIn += 1 })
        model.email = "  Will@Example.COM "
        model.password = "eightchars"

        await model.submit()

        XCTAssertEqual(
            stub.calls,
            [StubAuthActions.Call(kind: .signIn, email: "will@example.com", password: "eightchars")])
        XCTAssertEqual(signedIn, 1)
        XCTAssertNil(model.errorText)
        XCTAssertNil(model.invalidField)
        XCTAssertFalse(model.isWorking, "The in-flight state has to end")
    }

    func testSigningUpCallsSignUpAndNotSignIn() async {
        let stub = StubAuthActions()
        let model = AuthFormViewModel(mode: .signUp, actions: stub)
        model.email = "will@example.com"
        model.password = "eightchars"

        await model.submit()

        XCTAssertEqual(stub.calls.map(\.kind), [.signUp])
        XCTAssertEqual(model.submitTitle, "Create account")
    }

    func testTheSignInScreenSaysSignIn() {
        let model = AuthFormViewModel(mode: .signIn, actions: StubAuthActions())
        XCTAssertEqual(model.submitTitle, "Sign in")
        XCTAssertTrue(model.canSubmit)
    }

    // MARK: - Failures become words

    /// The one this ticket exists to prevent: an error that goes nowhere. A
    /// golfer who taps Sign in and sees nothing change assumes the app is
    /// broken, and they are right.
    func testAnErrorFromAuthBecomesTextRatherThanSilence() async {
        let stub = StubAuthActions(
            error: DisplayableFailure(displayMessage: "That email is already registered."))
        var signedIn = 0
        let model = AuthFormViewModel(mode: .signUp, actions: stub, onSuccess: { signedIn += 1 })
        model.email = "will@example.com"
        model.password = "eightchars"

        await model.submit()

        XCTAssertEqual(model.errorText, "That email is already registered.")
        XCTAssertEqual(signedIn, 0, "A failure is not a success")
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(stub.calls.map(\.kind), [.signUp], "The call was made and it failed")
    }

    func testASystemErrorUsesItsOwnDescription() async {
        let stub = StubAuthActions(error: LocalizedFailure())
        let model = AuthFormViewModel(mode: .signIn, actions: stub)
        model.email = "will@example.com"
        model.password = "eightchars"

        await model.submit()

        XCTAssertEqual(model.errorText, "That email or password is not right.")
    }

    /// An error with nothing readable in it gets a plain sentence — never the
    /// type name, never "error 1".
    func testAnErrorWithNothingToSayIsNotDumpedOnScreen() async {
        let stub = StubAuthActions(error: BareFailure())
        let model = AuthFormViewModel(mode: .signIn, actions: stub)
        model.email = "will@example.com"
        model.password = "eightchars"

        await model.submit()

        let text = model.errorText ?? ""
        XCTAssertEqual(text, "Something went wrong. Try again in a moment.")
        XCTAssertFalse(text.contains("BareFailure"))
        XCTAssertFalse(text.contains("error 1"))
    }

    /// A second attempt starts clean. Leaving the last failure on screen while
    /// a new one is in flight is how a fixed password still looks wrong.
    func testRetryingClearsTheLastFailure() async {
        let stub = StubAuthActions(error: DisplayableFailure(displayMessage: "No."))
        let model = AuthFormViewModel(mode: .signIn, actions: stub)
        model.email = "will@example.com"
        model.password = "eightchars"

        await model.submit()
        XCTAssertEqual(model.errorText, "No.")

        stub.error = nil
        await model.submit()
        XCTAssertNil(model.errorText)
        XCTAssertNil(model.invalidField)
    }

    // MARK: - The stub itself

    func testTheStubRecordsSignOut() async throws {
        let stub = StubAuthActions()
        try await stub.signOut()
        XCTAssertEqual(stub.calls.map(\.kind), [.signOut])
    }
}
