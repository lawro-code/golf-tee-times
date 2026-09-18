import Foundation
import Supabase

/// Who is signed in, as the rest of the app sees it.
public enum AuthState: Sendable, Equatable {
    case signedOut
    case signedIn(userID: UUID, email: String)
}

/// Email and password auth, over `client.auth`.
///
/// **Browsing works signed out.** Nothing on the read path calls anything in
/// this file. The wall is in front of alerts, watches and bookings only, and
/// `requireUserID()` is that wall.
///
/// Refresh is the SDK's job — `autoRefreshToken` is on and it refreshes before
/// expiry. This class owns the three things the SDK does not: local validation
/// before a pointless round trip, restoring at launch, and making sure sign-out
/// leaves nothing behind in the keychain.
public final class AuthService: SessionProviding, Sendable {
    /// Shorter than this and Supabase would refuse it anyway — but it refuses
    /// after a round trip, and telling someone locally is instant and kinder.
    public static let minimumPasswordLength = 8

    private let client: SupabaseClient
    private let storage: (any AuthLocalStorage)?
    private let storageKey: String

    /// - Parameters:
    ///   - client: usually `try SupabaseClientProvider.client()`.
    ///   - storage: the same storage that client was built with. The default is
    ///     the keychain, which is what the shared client uses; a test passes the
    ///     very instance it gave the client so sign-out can be observed.
    ///   - storageKey: the account name the session is filed under.
    public init(
        client: SupabaseClient,
        storage: (any AuthLocalStorage)? = KeychainSessionStorage(),
        storageKey: String = SupabaseClientProvider.sessionStorageKey
    ) {
        self.client = client
        self.storage = storage
        self.storageKey = storageKey
    }

    // MARK: - SessionProviding

    public var currentUserID: UUID? {
        client.auth.currentUser?.id
    }

    public func requireUserID() throws -> UUID {
        guard let id = currentUserID else { throw DataError.notSignedIn }
        return id
    }

    // MARK: - State

    public var state: AuthState {
        Self.state(for: client.auth.currentSession)
    }

    /// Auth state as it changes, bridged off the SDK's own stream.
    ///
    /// The SDK emits an `initialSession` event as soon as it is observed, so a
    /// consumer gets the current state without a separate first read. Cancel the
    /// consuming task and the upstream observation goes with it.
    public var stateChanges: AsyncStream<AuthState> {
        let upstream = client.auth.authStateChanges
        return AsyncStream { continuation in
            let task = Task {
                for await change in upstream {
                    continuation.yield(Self.state(for: change.session))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func state(for session: Session?) -> AuthState {
        guard let session else { return .signedOut }
        return .signedIn(userID: session.user.id, email: session.user.email ?? "")
    }

    // MARK: - Sign up, in, out

    public func signUp(email: String, password: String) async throws {
        let address = try Self.validatedEmail(email)
        try Self.validatePassword(password)
        do {
            _ = try await client.auth.signUp(email: address, password: password)
            DataLog.auth.info("sign-up accepted")
        } catch {
            let mapped = DataError.from(error)
            DataLog.failed("sign-up", mapped, in: .auth)
            throw mapped
        }
    }

    public func signIn(email: String, password: String) async throws {
        let address = try Self.validatedEmail(email)
        try Self.validatePassword(password)
        do {
            _ = try await client.auth.signIn(email: address, password: password)
            DataLog.auth.info("signed in")
        } catch {
            let mapped = DataError.from(error)
            DataLog.failed("sign-in", mapped, in: .auth)
            throw mapped
        }
    }

    /// Signs out, and leaves nothing on the device.
    ///
    /// The SDK clears its own storage, but only when it can see a session to
    /// clear — a corrupt or half-written entry would survive that. Removing the
    /// key outright afterwards is cheap and makes "signed out" mean it.
    /// Being offline does not stop a sign-out: the local session goes either way.
    public func signOut() async throws {
        var serverFailure: DataError?
        do {
            try await client.auth.signOut()
        } catch {
            let mapped = DataError.from(error)
            if mapped != .notSignedIn {
                DataLog.failed("sign-out", mapped, in: .auth)
                serverFailure = mapped
            }
        }
        clearStoredSession()
        if let serverFailure, !serverFailure.isRetryable { throw serverFailure }
        DataLog.auth.info("signed out")
    }

    /// Restore a session at launch.
    ///
    /// - Returns: true when this device has a session to carry on with.
    ///
    /// The three outcomes worth separating:
    /// - nothing stored → false, show the signed-out app (which still browses).
    /// - stored, and the server confirms or the failure is the network's →
    ///   true. Being offline at launch must not sign a person out.
    /// - stored, and the server rejected it (an expired or revoked refresh
    ///   token) → clear it and return false.
    @discardableResult
    public func restoreSession() async throws -> Bool {
        guard client.auth.currentSession != nil else {
            DataLog.auth.debug("no stored session")
            return false
        }
        do {
            _ = try await client.auth.session
            DataLog.auth.info("session restored")
            return true
        } catch {
            let mapped = DataError.from(error)
            if mapped.isRetryable {
                // Offline at launch. The session is still ours; the SDK will
                // refresh it when the network comes back.
                DataLog.auth.notice("kept the stored session: \(mapped.diagnostic, privacy: .public)")
                return true
            }
            if mapped == .notSignedIn {
                clearStoredSession()
                return false
            }
            DataLog.failed("session restore", mapped, in: .auth)
            clearStoredSession()
            return false
        }
    }

    private func clearStoredSession() {
        do {
            try storage?.remove(key: storageKey)
        } catch {
            // A keychain that will not delete is not worth failing a sign-out
            // over, but it is worth knowing about.
            DataLog.failed("clearing the stored session", DataError.from(error), in: .auth)
        }
    }

    // MARK: - Local validation

    /// Enough of an email check to catch a typo and a missing field, and no
    /// more. The server is the authority on whether an address exists; this only
    /// saves a round trip that was never going to succeed.
    static func validatedEmail(_ raw: String) throws -> String {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            throw DataError.invalidInput(field: "email", reason: "Enter your email address.")
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
            throw DataError.invalidInput(
                field: "email", reason: "That does not look like an email address.")
        }
        return address.lowercased()
    }

    static func validatePassword(_ password: String) throws {
        guard password.count >= minimumPasswordLength else {
            throw DataError.invalidInput(
                field: "password",
                reason: "Use at least \(minimumPasswordLength) characters.")
        }
    }
}
