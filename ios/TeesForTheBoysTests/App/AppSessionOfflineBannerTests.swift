import TeesContract
import TeesData
import XCTest
@testable import TeesForTheBoys

/// Regression coverage for the bug where `AppSession.apply` only ever set
/// `searchStore.isOffline` on an exact `snapshot.lastError == .offline`
/// match.
///
/// `DataError.from` (`Data/DataError.swift`) only produces `.offline` for
/// `URLError.notConnectedToInternet` / `.networkConnectionLost` / `.timedOut`.
/// A DNS failure, a refused connection, or a live host answering with a 5xx
/// (a paused/down Supabase project, a gateway error) all map to `.transport`
/// or `.server(status:,message:)` instead — an exact-case equality check on
/// an enum with associated values evaluates those as false, so the offline
/// banner never fired for any of them and a stale cache sat on screen with
/// zero indication anything was wrong.
@MainActor
final class AppSessionOfflineBannerTests: XCTestCase {

    private struct FakeFailingRemote: SlotsFetching {
        let error: Error
        func fetchPayload() async throws -> ContractPayload { throw error }
    }

    private struct FakeSeededCache: PayloadCaching {
        let seeded: CachedPayload?
        func load() throws -> CachedPayload? { seeded }
        func save(_ payload: ContractPayload, fetchedAt: Date) throws {}
        func clear() throws {}
    }

    /// `AppSession.start()` calls `SupabaseClientProvider.client()`
    /// unconditionally (only `makeTeeTimeStore` is overridable), so a real
    /// configuration has to be on record or `start()` bails out in its own
    /// `catch` before ever reaching `store.start()`/`apply()` — the exact
    /// machinery this test is trying to exercise. Same pattern
    /// `SupabaseConfigurationTests` uses; never a real network call.
    override func setUp() {
        super.setUp()
        SupabaseConfiguration.configure(url: URL(string: "https://stub.supabase.co")!, anonKey: "stub-anon-key")
    }

    private static func healthyCache(fetchedAt: Date) -> CachedPayload {
        CachedPayload(
            payload: ContractPayload(
                generatedAt: "2026-09-18T06:00:00+10:00", courses: [], slots: [], courseDays: []),
            fetchedAt: fetchedAt)
    }

    /// Poll rather than sleep: `TeeTimeStore.start()` kicks the refresh off
    /// detached, so the failure lands on the actor asynchronously.
    private func awaitSettled(_ store: TeeTimeStore) async {
        for _ in 0..<20_000 {
            let stillRefreshing = await store.snapshot.isRefreshing
            if !stillRefreshing { return }
            await Task.yield()
        }
    }

    /// One of the three concrete failure shapes named in the bug report: a
    /// host that does not resolve.
    func testDNSFailureWithAHealthyCacheStillSetsOffline() async {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let cache = FakeSeededCache(seeded: Self.healthyCache(fetchedAt: now.addingTimeInterval(-7 * 60 * 60)))
        let remote = FakeFailingRemote(error: URLError(.cannotFindHost))
        let store = TeeTimeStore(remote: remote, cache: cache, now: { now })

        let session = AppSession(makeTeeTimeStore: { store })
        await session.start()
        await awaitSettled(store)
        // Give AppSession's snapshot-stream task a few turns to consume the
        // failure snapshot the store just published.
        for _ in 0..<50 { await Task.yield() }

        XCTAssertNil(session.configurationFailure, "precondition: start() must actually reach store.start()")
        let lastError = await store.snapshot.lastError
        XCTAssertNotEqual(
            lastError, .offline,
            "precondition: a DNS failure must not already read as .offline")
        XCTAssertNotNil(session.searchStore.payload, "the stale cache should still be on screen")
        XCTAssertTrue(
            session.searchStore.isOffline,
            "a DNS failure left a stale cache on screen with no offline banner")
    }

    /// A fresh install, no signal: `DiskPayloadCache.load()` has nothing to
    /// return (`seeded: nil`, matching a real first launch) and the fetch
    /// throws `URLError.notConnectedToInternet`, so `payload` stays nil the
    /// whole way through — `TeeTimeSnapshot.isEmptyAndFailing` is true.
    ///
    /// `AppSession.apply` used to set `isOffline = true` from
    /// `lastError?.isRetryable` alone, with no regard for whether there was
    /// ever a payload to call "loaded". `SearchScreen`'s `topChrome` renders
    /// `ViewsOfflineBanner` ("You're offline. These are the last tee times we
    /// loaded.") whenever that flag is set — via `.safeAreaInset`, so it sits
    /// above the content switch regardless of state — and `isEmptyAndFailing`
    /// fed the same `.failed` state `DataError.offline.description` ("You are
    /// offline. Showing the last tee times we saved."). Both sentences are
    /// false on a device that has never fetched or saved anything: a banner
    /// and a full-screen error, stacked, each claiming tee times were
    /// loaded/saved over a screen that is empty because nothing ever was.
    func testColdLaunchWithNoCacheAndNoNetworkDoesNotClaimTeeTimesWereLoadedOrSaved() async {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let cache = FakeSeededCache(seeded: nil)
        let remote = FakeFailingRemote(error: URLError(.notConnectedToInternet))
        let store = TeeTimeStore(remote: remote, cache: cache, now: { now })

        let session = AppSession(makeTeeTimeStore: { store })
        await session.start()
        await awaitSettled(store)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertNil(session.configurationFailure, "precondition: start() must actually reach store.start()")
        let lastError = await store.snapshot.lastError
        XCTAssertEqual(lastError, .offline, "precondition: no connectivity must map to .offline")
        XCTAssertNil(session.searchStore.payload, "precondition: nothing has ever been cached or fetched")

        XCTAssertFalse(
            session.searchStore.isOffline,
            """
            the offline banner ("these are the last tee times we loaded") \
            showed even though nothing has ever loaded on this device.
            """)

        guard case .failed(let message) = session.searchStore.state else {
            return XCTFail("expected the empty-and-failing state to be .failed, got \(session.searchStore.state)")
        }
        XCTAssertFalse(
            message.localizedCaseInsensitiveContains("saved")
                || message.localizedCaseInsensitiveContains("loaded"),
            "the full-screen error falsely claimed tee times were saved/loaded: \(message)")
    }

    /// The other concrete shape named in the bug report: a live host
    /// answering with a 5xx, as a paused/down Supabase project or a gateway
    /// error would.
    func testServerFailureWithAHealthyCacheStillSetsOffline() async {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let cache = FakeSeededCache(seeded: Self.healthyCache(fetchedAt: now.addingTimeInterval(-7 * 60 * 60)))
        let remote = FakeFailingRemote(error: DataError.server(status: 503, message: nil))
        let store = TeeTimeStore(remote: remote, cache: cache, now: { now })

        let session = AppSession(makeTeeTimeStore: { store })
        await session.start()
        await awaitSettled(store)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertNil(session.configurationFailure, "precondition: start() must actually reach store.start()")
        let lastError = await store.snapshot.lastError
        XCTAssertNotEqual(lastError, .offline)
        XCTAssertNotNil(session.searchStore.payload, "the stale cache should still be on screen")
        XCTAssertTrue(
            session.searchStore.isOffline,
            "a paused/down server (5xx) left a stale cache on screen with no offline banner")
    }
}
