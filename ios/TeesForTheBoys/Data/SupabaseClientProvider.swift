import Foundation
import Supabase

/// The one `SupabaseClient` the app uses, and an injectable one for tests.
///
/// One client, not one per call site: the client owns the session, the auth
/// state stream and the refresh timer. Two of them fight over the same keychain
/// entry and each other's tokens.
///
/// Auth is configured deliberately:
///
/// - `storage:` a ``KeychainSessionStorage``, so a session survives a relaunch.
/// - `autoRefreshToken: true`, so the SDK refreshes before expiry. This track
///   does not hand-roll JWT refresh; it owns persistence and restore.
/// - `flowType: .pkce`, the right flow for a mobile client.
/// - `storageKey: "tees-for-the-boys"`, so the keychain entry is ours and named,
///   rather than a default derived from the project ref.
public enum SupabaseClientProvider {
    /// The keychain account the Supabase session is stored under. `AuthService`
    /// clears exactly this on sign-out.
    public static let sessionStorageKey = "tees-for-the-boys"

    /// The shared client, built on first use from ``SupabaseConfiguration/resolve()``.
    ///
    /// - Throws: `DataError.notConfigured` if no configuration was supplied.
    public static func client() throws -> SupabaseClient {
        try sharedClient.value {
            let configuration = try SupabaseConfiguration.resolve()
            return makeClient(
                configuration: configuration,
                session: .shared,
                storage: KeychainSessionStorage()
            )
        }
    }

    /// A fresh, unshared client.
    ///
    /// Tests pass a `URLSession` whose `protocolClasses` intercept every
    /// request, which is how this track gets to exercise auth without touching
    /// a hosted project. `storage` defaults to in-memory so a test never has to
    /// negotiate with the keychain.
    public static func client(
        configuration: SupabaseConfiguration,
        session: URLSession,
        storage: any AuthLocalStorage = InMemorySessionStorage()
    ) -> SupabaseClient {
        makeClient(configuration: configuration, session: session, storage: storage)
    }

    /// Drop the shared client. Tests only.
    static func resetShared() {
        sharedClient.reset()
    }

    private static func makeClient(
        configuration: SupabaseConfiguration,
        session: URLSession,
        storage: any AuthLocalStorage
    ) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.anonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: storage,
                    storageKey: sessionStorageKey,
                    flowType: .pkce,
                    autoRefreshToken: true,
                    // Emit the stored session at launch instead of waiting on a
                    // refresh first. Offline, the legacy behaviour emits nothing
                    // until the refresh fails, which reads as "signed out" for
                    // as long as the network takes to give up.
                    emitLocalSessionAsInitialSession: true
                ),
                global: SupabaseClientOptions.GlobalOptions(session: session)
            )
        )
    }
}

/// Builds the shared client exactly once, whichever thread asks first.
private final class SharedClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var client: SupabaseClient?

    func value(_ make: () throws -> SupabaseClient) rethrows -> SupabaseClient {
        lock.lock()
        defer { lock.unlock() }
        if let client { return client }
        let built = try make()
        client = built
        return built
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        client = nil
    }
}

private let sharedClient = SharedClientBox()
