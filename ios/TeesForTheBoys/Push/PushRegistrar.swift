import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Whatever can ask iOS for a device token.
///
/// `UIApplication` satisfies it, and that is the only production
/// implementation. It is a protocol so the registrar can be built and driven in
/// a unit test on a simulator, where `registerForRemoteNotifications()` reaches
/// a service that will never call back.
///
/// `@MainActor` because `UIApplication` is: registration is a UIKit call and
/// belongs on the main thread whoever is making it.
@MainActor
public protocol RemoteNotificationRegistering {
    func registerForRemoteNotifications()
}

#if canImport(UIKit)
extension UIApplication: RemoteNotificationRegistering {}
#endif

/// What happened the last time this device tried to register.
public enum PushRegistrationOutcome: Equatable, Sendable {
    /// iOS issued a token and the sink took it.
    case registered(environment: PushEnvironment)
    /// iOS refused to issue a token. Ordinary on a simulator.
    case systemRefused(reason: String)
    /// iOS issued a token and storing it failed — offline, or nobody signed in.
    case notStored(reason: String)
    /// The token was handed back: sign-out, or alerts turned off.
    case retired
}

/// Registers this device for remote notifications and hands the token on.
///
/// ## The simulator never issues a real APNs token
///
/// `registerForRemoteNotifications()` on a simulator either never calls back or
/// calls back with an error, and this module's own gate runs on a simulator. A
/// failure here is therefore an **ordinary, logged, non-fatal outcome** — no
/// trap, no `fatalError`, no retry storm. The app keeps working; the golfer
/// simply gets no alerts on that install, which is exactly what should happen.
///
/// ## The device token never reaches a log
///
/// It identifies a device. Not truncated, not hashed, not "just in debug" —
/// `PushTokenRepository` in Track B holds the same rule for the same reason.
/// The environment and the outcome are plenty to debug with.
///
/// ## Where the app delegate hooks in
///
/// ```swift
/// func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
///     registrar.didRegister(deviceToken: token)
/// }
/// func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
///     registrar.didFailToRegister(error)
/// }
/// ```
///
/// Both of those are synchronous and the sink is `async`, so `didRegister`
/// starts a task. ``handleRegistration(deviceToken:)`` is the same work with
/// the task awaited, which is the one a test drives.
@MainActor
public final class PushRegistrar {

    private let application: any RemoteNotificationRegistering
    private let sink: any PushTokenSink

    /// Which gateway this build's tokens come from. Injected rather than read
    /// from the build configuration at the point of use, so a build can be
    /// pointed the other way without touching this file.
    public let environment: PushEnvironment

    /// The hex token iOS last issued, or nil if it never has. Held so
    /// ``retire()`` has something to hand back at sign-out.
    public private(set) var currentToken: String?

    /// What happened last. Nil until something has.
    public private(set) var lastOutcome: PushRegistrationOutcome?

    public init(
        application: any RemoteNotificationRegistering,
        sink: any PushTokenSink = NoOpPushTokenSink(),
        environment: PushEnvironment = .current
    ) {
        self.application = application
        self.sink = sink
        self.environment = environment
    }

    #if canImport(UIKit)
    /// The app's registrar, against the real `UIApplication`.
    public convenience init(
        sink: any PushTokenSink = NoOpPushTokenSink(),
        environment: PushEnvironment = .current
    ) {
        self.init(application: UIApplication.shared, sink: sink, environment: environment)
    }
    #endif

    /// Ask iOS for a token.
    ///
    /// Call this only once notification permission has been granted — asking
    /// earlier is harmless but pointless, since a token with no permission
    /// behind it delivers nothing.
    ///
    /// Silent about its own success: the answer arrives at the app delegate,
    /// not here.
    public func register() {
        PushLog.registration.info(
            "registering for remote notifications (\(self.environment.rawValue, privacy: .public))")
        application.registerForRemoteNotifications()
    }

    // MARK: - What the app delegate calls back with

    /// iOS issued a token. Fire-and-forget; the delegate method is synchronous.
    public func didRegister(deviceToken: Data) {
        Task { await handleRegistration(deviceToken: deviceToken) }
    }

    /// iOS refused. **Not fatal, by design** — see the note on the type.
    public func didFailToRegister(_ error: Error) {
        let reason = String(describing: error)
        lastOutcome = .systemRefused(reason: reason)
        PushLog.registration.error(
            "APNs registration failed, alerts are off for this install: \(reason, privacy: .public)")
    }

    /// The same work as ``didRegister(deviceToken:)`` with the hand-off
    /// awaited.
    @discardableResult
    public func handleRegistration(deviceToken: Data) async -> PushRegistrationOutcome {
        let token = Self.hexString(from: deviceToken)

        // Checked before `currentToken` is set, not after: an empty token kept
        // here is one `retire()` would later hand to the sink as an empty
        // string, which is a row nobody can match to a device.
        guard !token.isEmpty else {
            let outcome = PushRegistrationOutcome.systemRefused(reason: "empty device token")
            lastOutcome = outcome
            PushLog.registration.error("APNs handed back an empty device token")
            return outcome
        }

        currentToken = token

        do {
            try await sink.register(token: token, environment: environment)
            let outcome = PushRegistrationOutcome.registered(environment: environment)
            lastOutcome = outcome
            PushLog.registration.info(
                "registered a push token (\(self.environment.rawValue, privacy: .public))")
            return outcome
        } catch {
            // Nobody signed in yet, or the phone is offline. The token is kept
            // so a later launch can try again with the same one.
            let outcome = PushRegistrationOutcome.notStored(reason: String(describing: error))
            lastOutcome = outcome
            PushLog.registration.error(
                "push token was not stored: \(String(describing: error), privacy: .public)")
            return outcome
        }
    }

    /// Hand the token back: sign-out, or alerts turned off.
    @discardableResult
    public func retire() async -> PushRegistrationOutcome? {
        guard let token = currentToken else { return nil }
        do {
            try await sink.retire(token: token)
            currentToken = nil
            lastOutcome = .retired
            PushLog.registration.info("retired this device's push token")
            return .retired
        } catch {
            let outcome = PushRegistrationOutcome.notStored(reason: String(describing: error))
            lastOutcome = outcome
            PushLog.registration.error(
                "push token was not retired: \(String(describing: error), privacy: .public)")
            return outcome
        }
    }

    // MARK: - The token itself

    /// APNs hands over 32 bytes; the server wants the lowercase hex of them.
    ///
    /// `%02x` and not `%x`: a leading zero byte is 8 characters of difference
    /// between a token that works and one the gateway rejects, and a token that
    /// is one byte short fails silently — no push, no error, no clue.
    public nonisolated static func hexString(from deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }
}
