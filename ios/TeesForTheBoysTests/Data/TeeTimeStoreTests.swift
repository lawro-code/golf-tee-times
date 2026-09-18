import XCTest
import TeesContract
@testable import TeesData

// MARK: - Test doubles

/// A clock the test moves by hand. `TeeTimeStore` and `RefreshPolicy` never
/// call `Date()`, which is what makes a six-hour staleness boundary assertable
/// in a millisecond.
final class B3Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ start: Date) { instant = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return instant
    }

    func advance(_ interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        instant = instant.addingTimeInterval(interval)
    }
}

/// A `SlotsFetching` that never touches a network, counts its calls, and can be
/// held open mid-fetch.
///
/// The gate is the whole point: single-flight is only observable while a fetch
/// is still in the air, so a test needs to be able to stop one in the middle.
actor B3FakeRemote: SlotsFetching {
    private(set) var callCount = 0
    private var result: Result<ContractPayload, DataError>
    private var gateOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ result: Result<ContractPayload, DataError>, gateOpen: Bool = true) {
        self.result = result
        self.gateOpen = gateOpen
    }

    func setResult(_ result: Result<ContractPayload, DataError>) { self.result = result }

    func openGate() {
        gateOpen = true
        let waiting = waiters
        waiters = []
        for continuation in waiting { continuation.resume() }
    }

    /// Shut it again, so a *second* fetch can be held mid-flight after a first
    /// one has already finished. That is the only way to reach the state where
    /// a failure is on record and a retry is in the air at the same time.
    func closeGate() { gateOpen = false }

    func fetchPayload() async throws -> ContractPayload {
        callCount += 1
        if !gateOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        return try result.get()
    }
}

/// An in-memory `PayloadCaching`. Faster than disk and, more usefully, able to
/// fail on demand — `DiskPayloadCache` deliberately cannot.
final class B3MemoryCache: PayloadCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CachedPayload?
    private var saves = 0
    private var loads = 0
    private var loadFailure: DataError?
    private var saveFailure: DataError?

    init(seeded: CachedPayload? = nil) { stored = seeded }

    var saveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return saves
    }

    /// How many times the store has read the disk. `start()` is allowed one.
    var loadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return loads
    }

    /// Change what is on disk behind the store's back, the way a second
    /// process or an app-group extension would.
    func seed(_ cached: CachedPayload?) {
        lock.lock(); defer { lock.unlock() }
        stored = cached
    }

    var contents: CachedPayload? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func failLoads(with error: DataError) {
        lock.lock(); defer { lock.unlock() }
        loadFailure = error
    }

    func failSaves(with error: DataError) {
        lock.lock(); defer { lock.unlock() }
        saveFailure = error
    }

    func load() throws -> CachedPayload? {
        lock.lock(); defer { lock.unlock() }
        loads += 1
        if let failure = loadFailure { throw failure }
        return stored
    }

    func save(_ payload: ContractPayload, fetchedAt: Date) throws {
        lock.lock(); defer { lock.unlock() }
        if let failure = saveFailure { throw failure }
        stored = CachedPayload(payload: payload, fetchedAt: fetchedAt)
        saves += 1
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}

/// What each observer actually saw. A stream that never fires then shows up as
/// a missing entry, which fails; reading the stream inline would hang instead,
/// and a hung test tells nobody anything.
actor B3Recorder {
    private(set) var seen: [String: Int] = [:]
    func record(_ name: String, slots: Int) { seen[name] = slots }
}

// MARK: - Tests

final class TeeTimeStoreTests: XCTestCase {

    private let t0 = B3Fixtures.t0

    /// Jitter pinned off so a backoff boundary is a boundary. The jitter itself
    /// is proved in `RefreshPolicyTests`.
    private var policy: RefreshPolicy { RefreshPolicy(jitterSeed: 0) }

    private func makeStore(
        remote: B3FakeRemote,
        cache: any PayloadCaching,
        clock: B3Clock
    ) -> TeeTimeStore {
        TeeTimeStore(remote: remote, cache: cache, policy: policy, now: { clock.now })
    }

    /// Give every other task a fair chance to reach the actor. Used only where
    /// the assertion is about what has *not* happened.
    private func settle(_ turns: Int = 500) async {
        for _ in 0..<turns { await Task.yield() }
    }

    // MARK: - Cache first

    /// The launch promise: tee times are on screen before the network has
    /// answered. The remote here has not answered at all when the assertions
    /// run — it is still sitting behind a closed gate.
    func testColdLaunchServesTheCacheBeforeTheRemoteResolves() async {
        let clock = B3Clock(t0)
        let cached = CachedPayload(
            payload: B3Fixtures.payload(slots: 9),
            fetchedAt: t0.addingTimeInterval(-20 * 60))
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 3)), gateOpen: false)
        let store = makeStore(remote: remote, cache: B3MemoryCache(seeded: cached), clock: clock)

        let first = await store.start()

        XCTAssertEqual(first.slots.count, 9, "the cache is served synchronously")
        XCTAssertEqual(first.fetchedAt, cached.fetchedAt)
        XCTAssertEqual(first.staleness, .soft, "twenty minutes old, so refetch quietly")
        XCTAssertTrue(first.isRefreshing, "and a refresh was started behind it")
        XCTAssertNil(first.lastError)

        await remote.openGate()
    }

    func testAnEmptyCacheStillStartsAndThenRefreshes() async {
        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 4)))
        let store = makeStore(remote: remote, cache: B3MemoryCache(), clock: clock)

        let first = await store.start()
        XCTAssertFalse(first.hasPayload)
        XCTAssertEqual(first.staleness, .hard, "never fetched is not fresh")

        await store.refresh()
        let after = await store.snapshot
        XCTAssertEqual(after.slots.count, 4)
        XCTAssertEqual(after.staleness, .fresh)
    }

    /// A cache that throws is still not a launch failure. `DiskPayloadCache`
    /// never throws on a bad file, but the store must not assume that of every
    /// `PayloadCaching`.
    func testAThrowingCacheDoesNotStopLaunch() async {
        let clock = B3Clock(t0)
        let cache = B3MemoryCache()
        cache.failLoads(with: .cacheUnavailable("keychain said no"))
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 2)))
        let store = makeStore(remote: remote, cache: cache, clock: clock)

        let first = await store.start()
        XCTAssertFalse(first.hasPayload)
        XCTAssertNil(first.lastError, "a cache miss is not something to show a golfer")
    }

    /// The end-to-end version of the corrupt-cache rule, through the real disk
    /// cache: garbage on disk, and the app still launches and then recovers.
    func testACorruptCacheFileOnDiskStillLaunches() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("B3Store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let disk = DiskPayloadCache(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0x7b, 0x22, 0x63, 0x6f, 0x6e]).write(to: disk.fileURL)   // `{"con`

        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 6)))
        let store = makeStore(remote: remote, cache: disk, clock: clock)

        let first = await store.start()
        XCTAssertFalse(first.hasPayload, "the bad file was discarded, not decoded")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: disk.fileURL.path),
            "and deleted, so the next launch does not read it again")

        await store.refresh(force: true)
        let recovered = await store.snapshot
        XCTAssertEqual(recovered.slots.count, 6)

        let rewritten = try XCTUnwrap(disk.load())
        XCTAssertEqual(rewritten.payload.slots.count, 6, "and the cache is rebuilt")
    }

    // MARK: - Airplane mode

    /// The rule: a failure never destroys good data. The cached tee times stay
    /// on screen, the offline error rides alongside them, and `fetchedAt` still
    /// says when the data is actually from.
    func testOfflineKeepsTheCachedPayloadAndReportsIt() async {
        let clock = B3Clock(t0)
        let fetchedAt = t0.addingTimeInterval(-30 * 60)
        let cached = CachedPayload(payload: B3Fixtures.payload(slots: 9), fetchedAt: fetchedAt)
        let cache = B3MemoryCache(seeded: cached)
        let remote = B3FakeRemote(.failure(.offline))
        let store = makeStore(remote: remote, cache: cache, clock: clock)

        await store.start()
        await store.refresh(force: true)
        let snapshot = await store.snapshot

        XCTAssertEqual(snapshot.slots.count, 9, "the payload survives the failure")
        XCTAssertEqual(snapshot.lastError, .offline)
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt, "a failure does not restamp the data")
        XCTAssertFalse(snapshot.isRefreshing)
        XCTAssertFalse(snapshot.isEmptyAndFailing, "there is something to draw")
        XCTAssertEqual(cache.saveCount, 0, "and nothing was written over the good copy")
    }

    func testASuccessAfterAFailureClearsTheError() async {
        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.failure(.offline))
        let store = makeStore(remote: remote, cache: B3MemoryCache(), clock: clock)

        await store.refresh()
        let failed = await store.snapshot
        XCTAssertEqual(failed.lastError, .offline)

        await remote.setResult(.success(B3Fixtures.payload(slots: 7)))
        clock.advance(120)
        await store.refresh(force: true)
        let recovered = await store.snapshot

        XCTAssertNil(recovered.lastError)
        XCTAssertEqual(recovered.slots.count, 7)
    }

    // MARK: - Single flight

    /// The thundering-herd rule, and the property most worth this test. Ten
    /// callers arriving while a fetch is in the air must join it, not start
    /// nine more.
    func testTenConcurrentRefreshesProduceExactlyOneRemoteCall() async {
        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 5)), gateOpen: false)
        let store = makeStore(remote: remote, cache: B3MemoryCache(), clock: clock)

        let herd = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<10 {
                    group.addTask { await store.refresh() }
                }
            }
        }

        await settle()
        let whileInFlight = await remote.callCount
        let midSnapshot = await store.snapshot
        XCTAssertEqual(whileInFlight, 1, "ten callers, one request")
        XCTAssertTrue(midSnapshot.isRefreshing)

        await remote.openGate()
        await herd.value

        let finalCount = await remote.callCount
        let finalSnapshot = await store.snapshot
        XCTAssertEqual(finalCount, 1)
        XCTAssertEqual(finalSnapshot.slots.count, 5, "and all ten got the answer")
        XCTAssertFalse(finalSnapshot.isRefreshing)
    }

    /// Pull-to-refresh skips the staleness test and the floor. It does not skip
    /// single-flight — ten thumbs are still one request.
    func testConcurrentForcedRefreshesAlsoCollapseToOne() async {
        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 5)), gateOpen: false)
        let store = makeStore(remote: remote, cache: B3MemoryCache(), clock: clock)

        let herd = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<10 {
                    group.addTask { await store.refresh(force: true) }
                }
            }
        }

        await settle()
        let whileInFlight = await remote.callCount
        XCTAssertEqual(whileInFlight, 1)

        await remote.openGate()
        await herd.value
        let finalCount = await remote.callCount
        XCTAssertEqual(finalCount, 1)
    }

    /// Fifteen screens calling `start()` at once is the same herd by another
    /// name.
    func testStartIsNotAWayAroundSingleFlight() async {
        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 5)), gateOpen: false)
        let store = makeStore(remote: remote, cache: B3MemoryCache(), clock: clock)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<15 {
                group.addTask { _ = await store.start() }
            }
        }
        await settle()

        let count = await remote.callCount
        XCTAssertEqual(count, 1)
        await remote.openGate()
    }

    // MARK: - The floor and force

    func testTheSixtySecondFloorStopsARefreshAndForceGetsPastIt() async {
        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 5)))
        let store = makeStore(remote: remote, cache: B3MemoryCache(), clock: clock)

        await store.refresh()
        let afterFirst = await remote.callCount
        XCTAssertEqual(afterFirst, 1)

        // A tab switch five seconds later. The server cannot have anything new.
        clock.advance(5)
        await store.refresh()
        let afterTabSwitch = await remote.callCount
        XCTAssertEqual(afterTabSwitch, 1, "inside the floor, no request")

        // A thumb five seconds later. That is different.
        await store.refresh(force: true)
        let afterPull = await remote.callCount
        XCTAssertEqual(afterPull, 2, "force refetches inside the sixty-second floor")
    }

    func testStartDoesNotRefetchFreshCachedData() async {
        let clock = B3Clock(t0)
        let cached = CachedPayload(
            payload: B3Fixtures.payload(slots: 9), fetchedAt: t0.addingTimeInterval(-30))
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 5)))
        let store = makeStore(remote: remote, cache: B3MemoryCache(seeded: cached), clock: clock)

        let first = await store.start()
        await settle(50)
        let count = await remote.callCount
        let snapshot = await store.snapshot

        XCTAssertEqual(first.staleness, .fresh)
        XCTAssertEqual(count, 0, "thirty seconds old is not worth a request")
        XCTAssertEqual(snapshot.slots.count, 9)
    }

    // MARK: - Backoff

    /// Repeated failures have to lengthen the wait — 2s, then 8s, then 30s —
    /// and a success has to put the ladder back to the bottom. A ladder that
    /// never reset would leave a recovered phone waiting minutes for nothing.
    func testBackoffLengthensAcrossFailuresAndResetsAfterASuccess() async {
        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.failure(.offline))
        let store = makeStore(remote: remote, cache: B3MemoryCache(), clock: clock)

        await store.refresh()
        var count = await remote.callCount
        XCTAssertEqual(count, 1, "first attempt")

        // Rung one: two seconds.
        clock.advance(1.5)
        await store.refresh()
        count = await remote.callCount
        XCTAssertEqual(count, 1, "still inside the 2s backoff")

        clock.advance(0.5)
        await store.refresh()
        count = await remote.callCount
        XCTAssertEqual(count, 2)

        // Rung two: eight seconds, which is the proof that it lengthened.
        clock.advance(2)
        await store.refresh()
        count = await remote.callCount
        XCTAssertEqual(count, 2, "two seconds is no longer enough — the wait grew")

        clock.advance(6)
        await store.refresh()
        count = await remote.callCount
        XCTAssertEqual(count, 3)

        // Rung three: thirty seconds.
        clock.advance(8)
        await store.refresh()
        count = await remote.callCount
        XCTAssertEqual(count, 3)

        // The network comes back.
        await remote.setResult(.success(B3Fixtures.payload(slots: 5)))
        clock.advance(22)
        await store.refresh()
        count = await remote.callCount
        let recovered = await store.snapshot
        XCTAssertEqual(count, 4)
        XCTAssertNil(recovered.lastError)

        // Now fail again, once, well past the floor. If the ladder had not
        // reset we would be on rung four and owe two minutes of silence.
        await remote.setResult(.failure(.offline))
        clock.advance(601)
        await store.refresh()
        count = await remote.callCount
        XCTAssertEqual(count, 5)

        clock.advance(2)
        await store.refresh()
        count = await remote.callCount
        XCTAssertEqual(count, 6, "the ladder reset on success, so this is rung one again")
    }

    // MARK: - Staleness over time

    /// Proof that the store reads the injected clock and never `Date()`: the
    /// data does not change, only the time does, and the staleness moves.
    func testStalenessFollowsTheInjectedClock() async {
        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 5)))
        let store = makeStore(remote: remote, cache: B3MemoryCache(), clock: clock)

        await store.refresh()
        var snapshot = await store.snapshot
        XCTAssertEqual(snapshot.staleness, .fresh)

        clock.advance(11 * 60)
        snapshot = await store.snapshot
        XCTAssertEqual(snapshot.staleness, .soft)

        clock.advance(7 * 60 * 60)
        snapshot = await store.snapshot
        XCTAssertEqual(snapshot.staleness, .hard)
        XCTAssertEqual(snapshot.slots.count, 5, "stale, but still there")
    }

    // MARK: - Writing the cache

    func testASuccessfulFetchWritesTheCache() async {
        let clock = B3Clock(t0)
        let cache = B3MemoryCache()
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 5)))
        let store = makeStore(remote: remote, cache: cache, clock: clock)

        await store.refresh()

        XCTAssertEqual(cache.saveCount, 1)
        XCTAssertEqual(cache.contents?.payload.slots.count, 5)
        XCTAssertEqual(cache.contents?.fetchedAt, t0)
    }

    /// A cache that will not write is a worse next launch, not a failed fetch.
    func testAFailedCacheWriteDoesNotFailTheFetch() async {
        let clock = B3Clock(t0)
        let cache = B3MemoryCache()
        cache.failSaves(with: .cacheUnavailable("disk full"))
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 5)))
        let store = makeStore(remote: remote, cache: cache, clock: clock)

        await store.refresh()
        let snapshot = await store.snapshot

        XCTAssertEqual(snapshot.slots.count, 5)
        XCTAssertNil(snapshot.lastError, "the fetch worked; the disk is a separate problem")
    }

    // MARK: - The stream

    func testSnapshotStreamYieldsCurrentStateOnSubscribeAndOnChange() async {
        let clock = B3Clock(t0)
        let cached = CachedPayload(
            payload: B3Fixtures.payload(slots: 9), fetchedAt: t0.addingTimeInterval(-30))
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 2)))
        let store = makeStore(remote: remote, cache: B3MemoryCache(seeded: cached), clock: clock)

        await store.start()

        var iterator = await store.snapshotStream().makeAsyncIterator()
        let onSubscribe = await iterator.next()
        XCTAssertEqual(onSubscribe?.slots.count, 9,
                       "a screen appearing late still draws immediately")

        await store.refresh(force: true)

        let afterRefresh = await iterator.next()
        XCTAssertEqual(afterRefresh?.slots.count, 2)
        XCTAssertEqual(afterRefresh?.fetchedAt, t0)
    }

    // MARK: - Helpers for the tests below

    /// Wait for the detached refresh `start()` kicked off to land. Polls the
    /// actor rather than sleeping, so a six-hour staleness test still runs in
    /// microseconds and a broken store fails instead of hanging the suite.
    private func awaitQuiet(
        _ store: TeeTimeStore, file: StaticString = #filePath, line: UInt = #line
    ) async -> TeeTimeSnapshot {
        for _ in 0..<20_000 {
            let snapshot = await store.snapshot
            if !snapshot.isRefreshing { return snapshot }
            await Task.yield()
        }
        XCTFail("the refresh never finished", file: file, line: line)
        return await store.snapshot
    }

    // MARK: - Launching once

    /// `start()` is the launch path and it runs once. A second screen appearing
    /// or the app returning from the background must not re-read the disk
    /// underneath live data — a cache written by something else would otherwise
    /// replace what is on screen with an older payload.
    func testStartIsIdempotentAndDoesNotReReadTheCache() async {
        let clock = B3Clock(t0)
        let cache = B3MemoryCache(seeded: CachedPayload(
            payload: B3Fixtures.payload(slots: 9), fetchedAt: t0.addingTimeInterval(-30)))
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 5)))
        let store = makeStore(remote: remote, cache: cache, clock: clock)

        let first = await store.start()
        XCTAssertEqual(first.slots.count, 9)
        XCTAssertEqual(cache.loadCount, 1)

        // Something writes the disk behind the store's back.
        cache.seed(CachedPayload(payload: B3Fixtures.payload(slots: 2), fetchedAt: t0))
        let second = await store.start()
        await settle(50)

        XCTAssertEqual(cache.loadCount, 1, "the cache is read once, at launch")
        XCTAssertEqual(second.slots.count, 9, "and the second start changed nothing on screen")
        let calls = await remote.callCount
        XCTAssertEqual(calls, 0, "thirty-second-old data is not worth a request, twice over")
    }

    // MARK: - The one state that earns a full-screen error

    /// First launch, no cache, no signal. Nothing to draw and nothing on the
    /// way — the only combination where a golfer should see an error screen
    /// rather than tee times with a banner.
    func testAColdLaunchWithNoCacheAndNoNetworkIsEmptyAndFailing() async {
        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.failure(.offline))
        let store = makeStore(remote: remote, cache: B3MemoryCache(), clock: clock)

        let launch = await store.start()
        XCTAssertTrue(launch.isRefreshing)
        XCTAssertFalse(launch.isEmptyAndFailing, "still trying — do not condemn it yet")

        let settled = await awaitQuiet(store)
        XCTAssertTrue(settled.isEmptyAndFailing, "nothing to draw and nothing on the way")
        XCTAssertEqual(settled.lastError, .offline)
        XCTAssertFalse(settled.hasPayload)
        XCTAssertEqual(settled.staleness, .hard, "never fetched is never fresh")
        XCTAssertNil(settled.fetchedAt)

        // The golfer taps Retry. Now there is a failure on record *and* a
        // request in the air: still nothing to draw, but something is coming,
        // so this is a spinner and not a second full-screen failure. This is
        // the only state where the `isRefreshing` half of the rule does any
        // work, and without it the screen would condemn its own retry.
        await remote.closeGate()
        let retry = Task { await store.refresh(force: true) }
        await settle()

        let midRetry = await store.snapshot
        XCTAssertTrue(midRetry.isRefreshing, "precondition: the retry is in the air")
        XCTAssertFalse(midRetry.hasPayload, "precondition: still nothing to draw")
        XCTAssertEqual(midRetry.lastError, .offline, "and the last failure is still on record")
        XCTAssertFalse(midRetry.isEmptyAndFailing,
                       "something is on the way — do not condemn it again")

        await remote.openGate()
        await retry.value
        let afterRetry = await store.snapshot
        XCTAssertTrue(afterRetry.isEmptyAndFailing, "the retry failed too, so now say so")
    }

    /// Seven hours old and no signal: still the tee times, still labelled, with
    /// the error alongside rather than in place of them. Blanking a screen
    /// because the data is old is the failure this prevents.
    func testAHardStaleCacheIsStillServedAndLabelled() async {
        let clock = B3Clock(t0)
        let fetchedAt = t0.addingTimeInterval(-7 * 60 * 60)
        let cache = B3MemoryCache(seeded: CachedPayload(
            payload: B3Fixtures.payload(slots: 9), fetchedAt: fetchedAt))
        let remote = B3FakeRemote(.failure(.offline))
        let store = makeStore(remote: remote, cache: cache, clock: clock)

        let launch = await store.start()
        XCTAssertEqual(launch.slots.count, 9, "old tee times still beat an empty screen")
        XCTAssertEqual(launch.staleness, .hard, "and the app says so")

        let settled = await awaitQuiet(store)
        XCTAssertEqual(settled.slots.count, 9, "the failure did not take them away")
        XCTAssertEqual(settled.fetchedAt, fetchedAt, "and it does not pretend to be new")
        XCTAssertEqual(settled.staleness, .hard)
        XCTAssertEqual(settled.lastError, .offline)
        XCTAssertFalse(settled.isEmptyAndFailing, "there is something to draw")
        XCTAssertEqual(cache.saveCount, 0, "nothing was written over the good copy")
    }

    // MARK: - Single flight must not outlive the flight

    /// The easy version of this bug is leaving the in-flight slot set on the
    /// error path. Every later refresh would then join a task that has already
    /// finished, return instantly, and never fetch — an app that goes quiet
    /// after its first failed request. No clock movement here on purpose, so
    /// the only thing under test is the release.
    func testAFailedFetchReleasesTheSingleFlightSlot() async {
        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.failure(.offline))
        let store = makeStore(remote: remote, cache: B3MemoryCache(), clock: clock)

        await store.refresh()
        var calls = await remote.callCount
        XCTAssertEqual(calls, 1)
        let afterFailure = await store.snapshot
        XCTAssertFalse(afterFailure.isRefreshing, "nothing is in the air any more")

        await remote.setResult(.success(B3Fixtures.payload(slots: 8)))
        await store.refresh(force: true)

        calls = await remote.callCount
        let recovered = await store.snapshot
        XCTAssertEqual(calls, 2, "a new flight, not a join onto a finished one")
        XCTAssertEqual(recovered.slots.count, 8)
        XCTAssertNil(recovered.lastError)
    }

    // MARK: - The stream

    /// `.bufferingNewest(1)`. A screen that was busy while three refreshes
    /// landed wants the current tee times, not a queue of the ones it missed.
    /// An unbounded buffer would hand it the launch snapshot first and make it
    /// redraw its way forward through history.
    func testASlowScreenGetsTheNewestSnapshotNotABacklog() async {
        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 1)))
        let store = makeStore(remote: remote, cache: B3MemoryCache(), clock: clock)

        // Subscribed, then not read from. The subscribe-time snapshot is empty.
        var iterator = await store.snapshotStream().makeAsyncIterator()

        for count in [2, 4, 6] {
            await remote.setResult(.success(B3Fixtures.payload(slots: count)))
            clock.advance(61)
            await store.refresh(force: true)
        }

        let first = await iterator.next()
        XCTAssertEqual(first?.slots.count, 6,
                       "the first thing a slow screen reads is the current state")
        XCTAssertEqual(first?.isRefreshing, false)
    }

    /// Two screens, one store. A fan-out that only kept the latest continuation
    /// would starve whichever screen subscribed first, and the symptom would be
    /// a list that never updates on one tab.
    func testEveryObserverSeesTheSameUpdate() async {
        let clock = B3Clock(t0)
        let remote = B3FakeRemote(.success(B3Fixtures.payload(slots: 3)))
        let store = makeStore(remote: remote, cache: B3MemoryCache(), clock: clock)

        let recorder = B3Recorder()
        let streamA = await store.snapshotStream()
        let streamB = await store.snapshotStream()
        let readerA = Task {
            for await snapshot in streamA where snapshot.slots.count == 3 {
                await recorder.record("a", slots: snapshot.slots.count)
                break
            }
        }
        let readerB = Task {
            for await snapshot in streamB where snapshot.slots.count == 3 {
                await recorder.record("b", slots: snapshot.slots.count)
                break
            }
        }

        await store.refresh()
        await settle()

        let seen = await recorder.seen
        XCTAssertEqual(seen["a"], 3)
        XCTAssertEqual(seen["b"], 3, "a second screen is not starved by the first")

        readerA.cancel()
        readerB.cancel()
        _ = await readerA.value
        _ = await readerB.value
    }

    // MARK: - The seam the other tracks were promised

    /// `init(remote:cache:policy:)` and the two-argument form still compile
    /// exactly as specified. The injected clock is additive; if it had ever
    /// become required, this would not build — which is the point of asserting
    /// it here rather than trusting a code review.
    func testTheSpecifiedInitialisersStillCompile() async {
        let three = TeeTimeStore(
            remote: B3FakeRemote(.success(B3Fixtures.payload(slots: 1))),
            cache: B3MemoryCache(),
            policy: policy)
        let threeSnapshot = await three.snapshot
        XCTAssertFalse(threeSnapshot.hasPayload)
        XCTAssertEqual(threeSnapshot.staleness, .hard)

        let two = TeeTimeStore(
            remote: B3FakeRemote(.success(B3Fixtures.payload(slots: 1))),
            cache: B3MemoryCache())
        let twoSnapshot = await two.snapshot
        XCTAssertFalse(twoSnapshot.isRefreshing)
        XCTAssertNil(twoSnapshot.lastError)
    }
}
