import Foundation
import TeesContract

/// The seams between this track's four tickets.
///
/// Each protocol has exactly one production implementation and at least one
/// test double. They exist so that the store (B3) can be tested with no
/// network and no keychain, and so that track C never sees a `SupabaseClient`.
///
/// These signatures are a contract with the other tickets. Do not rename them.

/// A decoded payload and the moment it was fetched.
///
/// The timestamp is the cache's, not the server's: `ContractPayload.generatedAt`
/// says when the scrape ran, this says when this device last heard about it.
/// Staleness is measured against this one.
public struct CachedPayload: Sendable {
    public let payload: ContractPayload
    public let fetchedAt: Date

    public init(payload: ContractPayload, fetchedAt: Date) {
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}

/// Reads open tee times from wherever they live. Implemented against Supabase
/// (B2) and against the golden fixture for previews and tests.
///
/// Never requires a signed-in user: browsing works signed out.
public protocol SlotsFetching: Sendable {
    func fetchPayload() async throws -> ContractPayload
}

/// The on-disk copy that makes the app open instantly and work in airplane
/// mode. Synchronous by design — it is a file read, and making it `async` would
/// buy nothing but a suspension point.
public protocol PayloadCaching: Sendable {
    func load() throws -> CachedPayload?
    func save(_ payload: ContractPayload, fetchedAt: Date) throws
    func clear() throws
}

/// Who is signed in, if anyone.
///
/// `currentUserID` is nil for a signed-out browser, which is an ordinary state,
/// not an error. `requireUserID()` is the wall: call it only on the paths that
/// genuinely need an owner — watches, bookings, push tokens.
public protocol SessionProviding: Sendable {
    var currentUserID: UUID? { get }
    /// - Throws: `DataError.notSignedIn` when nobody is signed in.
    func requireUserID() throws -> UUID
}
