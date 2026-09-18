import Foundation
import Supabase

/// Watches — create, list, edit, deactivate, delete. All of it behind the
/// sign-in wall.
///
/// ## The wall
///
/// Every method calls ``SessionProviding/requireUserID()`` **before** it builds
/// a request, so a signed-out caller gets ``DataError/notSignedIn`` without a
/// packet leaving the phone. That is deliberate and it is the only place the
/// wall exists: browsing and filtering stay open to everyone, the wall goes in
/// front of alerts (BUILD-PLAN.md, CONTRACT.md).
///
/// `user_id` is set here from the session and is never a parameter. RLS checks
/// `user_id = auth.uid()` on insert, update, select and delete, so a caller who
/// could pass one in would only ever be passing in a value the database is
/// about to reject — or, worse, the right one by accident.
///
/// ## One call, not a wizard
///
/// ``create(_:)`` takes the whole ``WatchDraft`` because the active filters
/// already describe a watch completely. The UI for this is a single button, so
/// the API for it is a single call.
public struct WatchRepository: Sendable {

    /// Named here so a migration that renames the table breaks in one place.
    public static let table = "watches"

    private let client: SupabaseClient
    private let session: any SessionProviding
    private let now: @Sendable () -> Date

    public init(client: SupabaseClient, session: any SessionProviding) {
        self.init(client: client, session: session, now: { Date() })
    }

    /// Test seam. An injected clock keeps `expires_at` assertions exact.
    init(
        client: SupabaseClient,
        session: any SessionProviding,
        now: @escaping @Sendable () -> Date
    ) {
        self.client = client
        self.session = session
        self.now = now
    }

    // MARK: - Writing

    /// Save the current filters as a watch.
    ///
    /// - Throws: ``DataError/notSignedIn`` when nobody is signed in,
    ///   ``DataError/invalidInput(field:reason:)`` when the draft would violate
    ///   one of the table's checks — before any request goes out.
    @discardableResult
    public func create(_ draft: WatchDraft) async throws -> Watch {
        let userID = try session.requireUserID()
        let validated = try draft.validated()
        let row = WatchWriteRow(
            userID: userID,
            draft: validated,
            expiresAt: try Self.expiry(endingOn: validated.dateTo))

        let data = try await UserDataRequest.data {
            try client.from(Self.table)
                .insert(row, returning: .representation)
                .select()
                .single()
        }
        let watch: Watch = try UserDataRequest.decode(Watch.self, from: data, table: Self.table)
        DataLog.userdata.info("created watch \(watch.id.uuidString, privacy: .public)")
        return watch
    }

    /// Replace a watch's filters. Columns cleared in the draft are cleared in
    /// the row: ``WatchWriteRow`` sends every filter column, nils included.
    @discardableResult
    public func update(id: UUID, to draft: WatchDraft) async throws -> Watch {
        let userID = try session.requireUserID()
        let validated = try draft.validated()
        let row = WatchWriteRow(
            userID: nil,
            draft: validated,
            expiresAt: try Self.expiry(endingOn: validated.dateTo))

        let data = try await UserDataRequest.data {
            try client.from(Self.table)
                .update(row, returning: .representation)
                .eq("id", value: id)
                .eq("user_id", value: userID)
                .select()
                .single()
        }
        return try UserDataRequest.decode(Watch.self, from: data, table: Self.table)
    }

    /// Stop a watch matching without deleting it.
    ///
    /// This is the hook the "did you book?" flow needs: a yes on a slot that
    /// satisfied a watch deactivates it, because nothing is more annoying than
    /// an alert for a tee time you already have. Deciding *which* watch a
    /// booking satisfies is the matcher's job, server-side, in track E. This
    /// method is where that flow ends up, and this ticket stops here.
    @discardableResult
    public func deactivate(id: UUID) async throws -> Watch {
        let userID = try session.requireUserID()

        let data = try await UserDataRequest.data {
            try client.from(Self.table)
                .update(WatchActiveRow(active: false), returning: .representation)
                .eq("id", value: id)
                .eq("user_id", value: userID)
                .select()
                .single()
        }
        let watch: Watch = try UserDataRequest.decode(Watch.self, from: data, table: Self.table)
        DataLog.userdata.info("deactivated watch \(watch.id.uuidString, privacy: .public)")
        return watch
    }

    /// Delete a watch outright. Its `alert_deliveries` go with it — the ledger
    /// is `on delete cascade` from `watches`.
    public func delete(id: UUID) async throws {
        let userID = try session.requireUserID()

        try await UserDataRequest.send {
            client.from(Self.table)
                .delete(returning: .minimal)
                .eq("id", value: id)
                .eq("user_id", value: userID)
        }
    }

    // MARK: - Reading

    /// This user's watches, newest first.
    ///
    /// - Parameter includeInactive: false, the default, hides the ones a
    ///   booking or an expiry has already retired.
    public func list(includeInactive: Bool = false) async throws -> [Watch] {
        let userID = try session.requireUserID()

        let data = try await UserDataRequest.data {
            var query = client.from(Self.table)
                .select()
                .eq("user_id", value: userID)
            if !includeInactive {
                query = query.eq("active", value: true)
            }
            return query.order("created_at", ascending: false)
        }
        return try UserDataRequest.decode([Watch].self, from: data, table: Self.table)
    }

    // MARK: - Expiry

    /// When a watch stops being worth matching.
    ///
    /// The end of `date_to` **at the course**, which is in Sydney, and never in
    /// whatever zone the phone is in. A golfer in Perth saving a watch that
    /// runs to Saturday means Saturday at the course; resolving that with the
    /// device calendar would retire it two hours early, and on the first Sunday
    /// in October it would be an hour out for everyone.
    ///
    /// nil `date_to` means nil expiry: a watch with no end date does not have
    /// one invented for it.
    public static func expiry(endingOn dateTo: String?) throws -> Date? {
        guard let dateTo else { return nil }
        return try UserDataFormat.endOfDay(dateTo, field: "date_to")
    }

    /// Whether a watch has run out, measured against the same clock the
    /// repository uses. The database index `watches_live_idx` is on the same
    /// column; this is the client-side read of it.
    public func hasExpired(_ watch: Watch) -> Bool {
        guard let expiresAt = watch.expiresAt else { return false }
        return expiresAt <= now()
    }
}

/// The one-column PATCH ``WatchRepository/deactivate(id:)`` sends. A whole
/// ``WatchWriteRow`` would rewrite every filter to whatever the caller last
/// held, which is not what "stop alerting me" means.
struct WatchActiveRow: Encodable {
    let active: Bool
}
