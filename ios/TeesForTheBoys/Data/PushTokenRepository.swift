import Foundation
import Supabase

/// The `push_tokens` row for this device, and nothing else.
///
/// Track E owns the APNs sender and the key that goes with it. This file owns
/// one thing: putting a token in the table when iOS hands one over, and taking
/// it out when the user signs out or turns alerts off.
///
/// ## Why the upsert targets `(user_id, token)`
///
/// Because two mates sharing one iPhone is an ordinary case for this app, and
/// the composite key is the only thing that makes it work. On the token alone,
/// the second person to sign in cannot register at all: the row belongs to the
/// first, RLS hides it from them, and their upsert fails on a primary key they
/// are not allowed to see — while the first person's alerts keep arriving on a
/// phone the second person is holding. The migration says all of this at
/// length; this is the client half of it. The sender de-duplicates by token at
/// send time, so one device still gets one push.
///
/// ## Tokens never reach a log
///
/// An APNs token identifies a device. Nothing here logs one — not truncated,
/// not hashed, not "just in debug". The environment and the outcome are plenty.
public struct PushTokenRepository: Sendable {

    public static let table = "push_tokens"

    private let client: SupabaseClient
    private let session: any SessionProviding
    private let now: @Sendable () -> Date

    public init(client: SupabaseClient, session: any SessionProviding) {
        self.init(client: client, session: session, now: { Date() })
    }

    /// Test seam for `updated_at`.
    init(
        client: SupabaseClient,
        session: any SessionProviding,
        now: @escaping @Sendable () -> Date
    ) {
        self.client = client
        self.session = session
        self.now = now
    }

    /// Register, or refresh, this device's token for the signed-in user.
    ///
    /// Safe to call on every launch: the same token upserts onto the same row
    /// and only moves `updated_at`.
    ///
    /// - Parameter environment: which APNs gateway minted it. A sandbox token
    ///   sent to production is rejected and the other way round, so the row has
    ///   to remember which one this is.
    @discardableResult
    public func register(
        token: String, environment: PushEnvironment
    ) async throws -> PushToken {
        let userID = try session.requireUserID()
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else {
            // The reason names the field, never the value.
            throw DataError.invalidInput(
                field: "token", reason: "This device did not supply a usable push token.")
        }

        let row = PushTokenWriteRow(
            userID: userID,
            token: token,
            platform: PushToken.platformIOS,
            environment: environment,
            updatedAt: now())

        let data = try await UserDataRequest.data {
            try client.from(Self.table)
                .upsert(row, onConflict: "user_id,token", returning: .representation)
                .select()
                .single()
        }
        let stored: PushToken = try UserDataRequest.decode(
            PushToken.self, from: data, table: Self.table)
        DataLog.userdata.info(
            "registered a push token (\(stored.environment.rawValue, privacy: .public))")
        return stored
    }

    /// Drop this device's token: sign-out, or alerts turned off.
    ///
    /// Scoped to `(user_id, token)` like everything else here, so signing out
    /// on a shared phone removes your row and leaves your mate's alone.
    public func remove(token: String) async throws {
        let userID = try session.requireUserID()
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw DataError.invalidInput(
                field: "token", reason: "This device did not supply a usable push token.")
        }

        try await UserDataRequest.send {
            client.from(Self.table)
                .delete(returning: .minimal)
                .eq("user_id", value: userID)
                .eq("token", value: token)
        }
        DataLog.userdata.info("removed a push token")
    }

    /// Every device this user has registered. RLS already scopes it; the
    /// explicit filter says so at the call site too.
    public func registeredTokens() async throws -> [PushToken] {
        let userID = try session.requireUserID()

        let data = try await UserDataRequest.data {
            client.from(Self.table)
                .select()
                .eq("user_id", value: userID)
                .order("updated_at", ascending: false)
        }
        return try UserDataRequest.decode([PushToken].self, from: data, table: Self.table)
    }
}
