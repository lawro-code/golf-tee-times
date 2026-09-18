import Foundation

/// Which APNs gateway minted a token.
///
/// A sandbox token sent to the production gateway is rejected, and the other
/// way round, so whatever stores the token has to remember which one this is.
///
/// **The raw values are not cosmetic.** They are written straight into
/// `push_tokens.environment`, whose check constraint in
/// `supabase/migrations/0002_user_tables.sql` allows `'sandbox'` and
/// `'production'` and nothing else. Renaming a case here fails an insert there.
public enum PushEnvironment: String, Sendable, Equatable, CaseIterable {
    case sandbox
    case production

    /// The environment this build's tokens come from.
    ///
    /// A debug build installed from Xcode is signed for the sandbox gateway; a
    /// TestFlight or App Store build is not. This is a starting value, not a
    /// law — `PushRegistrar` takes it as a parameter so a build can be pointed
    /// the other way without touching this file.
    public static var current: PushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

/// Where a device token goes once iOS has issued one.
///
/// This module has no Supabase dependency and is not getting one:
/// `ios/project.yml` gives TeesPush exactly one dependency, `TeesContract`.
/// Track B owns `push_tokens` and the upsert that writes it; this protocol is
/// the seam between the two, and the app target is the only place that knows
/// about both sides of it.
///
/// Both methods are `async throws` because the implementation behind them is a
/// network round trip that can fail. A failure here is not fatal to the app:
/// the golfer simply does not get alerts until a later launch registers
/// successfully, and `PushRegistrar` records that outcome rather than trapping.
public protocol PushTokenSink: Sendable {
    /// Store, or refresh, this device's token for the signed-in user.
    ///
    /// Safe to call on every launch — iOS hands the same token back, and the
    /// implementation upserts.
    func register(token: String, environment: PushEnvironment) async throws

    /// Drop this device's token: sign-out, or alerts turned off.
    func retire(token: String) async throws
}

/// One call to `register`, kept so a test can assert on it.
public struct PushTokenRegistration: Equatable, Sendable {
    public let token: String
    public let environment: PushEnvironment

    public init(token: String, environment: PushEnvironment) {
        self.token = token
        self.environment = environment
    }
}

/// A sink that does nothing, successfully.
///
/// The default the registrar is built with, and what the app holds before
/// anybody has signed in: a token that arrives with no user to attach it to has
/// nowhere to go, and dropping it is the correct outcome rather than an error
/// to surface.
public struct NoOpPushTokenSink: PushTokenSink {
    public init() {}
    public func register(token: String, environment: PushEnvironment) async throws {}
    public func retire(token: String) async throws {}
}

/// The test and preview twin. Counts and keeps what it was handed.
///
/// An `actor` because the registrar calls it from the main actor while a test
/// reads it from its own context; serialising the state is cheaper than
/// reasoning about whether that is safe.
public actor RecordingPushTokenSink: PushTokenSink {

    /// Injected so a test can prove the registrar survives a sink that fails —
    /// the ordinary case of the phone being offline when the token arrives.
    public enum Failure: Error, Equatable {
        case refused
    }

    public private(set) var registrations: [PushTokenRegistration] = []
    public private(set) var retired: [String] = []

    private let failure: Failure?

    public init(failure: Failure? = nil) {
        self.failure = failure
    }

    public func register(token: String, environment: PushEnvironment) async throws {
        if let failure { throw failure }
        registrations.append(PushTokenRegistration(token: token, environment: environment))
    }

    public func retire(token: String) async throws {
        if let failure { throw failure }
        retired.append(token)
    }
}
