import Foundation
import TeesContract

/// Everything a screen needs to draw, in one immutable value.
///
/// Deliberately not an observable object and deliberately free of UI types:
/// this module has none and must not grow any. Track C observes the stream,
/// holds the latest snapshot, and renders it.
public struct TeeTimeSnapshot: Sendable, Equatable {
    /// The last payload we managed to get hold of, from cache or network. Nil
    /// only before the first successful fetch on a device that has never had
    /// one.
    public let payload: ContractPayload?
    /// When this device last heard from the server — not when the scrape ran.
    /// `payload.generatedAt` answers that other question.
    public let fetchedAt: Date?
    public let staleness: Staleness
    public let isRefreshing: Bool
    /// The failure from the last attempt, if there was one. It sits
    /// **alongside** the payload rather than replacing it: an offline phone
    /// still shows this morning's tee times with a note, not an error screen.
    /// Cleared by the next success.
    public let lastError: DataError?

    public var slots: [Slot] { payload?.slots ?? [] }
    public var courses: [Course] { payload?.courses ?? [] }
    public var courseDays: [CourseDay] { payload?.courseDays ?? [] }
    public var hasPayload: Bool { payload != nil }

    /// True when there is nothing to draw and nothing on the way — the only
    /// state that earns a full-screen error rather than a banner.
    public var isEmptyAndFailing: Bool { payload == nil && lastError != nil && !isRefreshing }

    public init(
        payload: ContractPayload?,
        fetchedAt: Date?,
        staleness: Staleness,
        isRefreshing: Bool,
        lastError: DataError?
    ) {
        self.payload = payload
        self.fetchedAt = fetchedAt
        self.staleness = staleness
        self.isRefreshing = isRefreshing
        self.lastError = lastError
    }
}

/// The public face of the data track: the one object the app reads tee times
/// from.
///
/// An actor because the invariant that matters most here is a concurrency one.
/// Fifteen things can ask for a refresh at once — a tab switch, a
/// scroll-to-top, a push arriving, the app returning from the background, four
/// screens appearing — and they must produce **one** request, not fifteen.
/// Serialising the decision inside an actor is what makes that provable rather
/// than hopeful.
///
/// Three behaviours, in the order they matter:
///
/// 1. **Cache first, always.** `start()` publishes whatever is on disk and
///    returns. It never awaits the network, so first paint is disk-speed even
///    on a dead connection.
/// 2. **Single-flight.** Concurrent callers join the fetch already running.
/// 3. **A failure never destroys good data.** The last payload stays on
///    screen; the error rides alongside it and feeds the backoff.
public actor TeeTimeStore {

    private let remote: any SlotsFetching
    private let cache: any PayloadCaching
    public let policy: RefreshPolicy

    /// Injected so tests can assert on a staleness boundary rather than sleep
    /// through six hours of it.
    private let clock: @Sendable () -> Date

    private var payload: ContractPayload?
    private var fetchedAt: Date?
    private var lastFailureAt: Date?
    private var failureCount = 0
    private var lastError: DataError?
    private var isRefreshing = false
    private var didStart = false

    /// The single in-flight fetch, or nil. This one property is the
    /// thundering-herd guarantee.
    private var inFlight: Task<Void, Never>?

    private var observers: [UUID: AsyncStream<TeeTimeSnapshot>.Continuation] = [:]

    public init(
        remote: any SlotsFetching,
        cache: any PayloadCaching,
        policy: RefreshPolicy = RefreshPolicy.standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.remote = remote
        self.cache = cache
        self.policy = policy
        self.clock = now
    }

    /// The composition the app uses: Supabase in front, disk behind.
    ///
    /// - Throws: `DataError.notConfigured` when no Supabase URL or anon key
    ///   could be resolved. Nothing else in here can fail.
    public static func live(
        policy: RefreshPolicy = RefreshPolicy.standard
    ) throws -> TeeTimeStore {
        TeeTimeStore(
            remote: SupabaseSlotsRemote(client: try SupabaseClientProvider.client()),
            cache: DiskPayloadCache(),
            policy: policy)
    }

    // MARK: - Reading

    public var snapshot: TeeTimeSnapshot {
        TeeTimeSnapshot(
            payload: payload,
            fetchedAt: fetchedAt,
            staleness: policy.staleness(of: fetchedAt, now: clock()),
            isRefreshing: isRefreshing,
            lastError: lastError)
    }

    /// A stream of snapshots, newest-wins.
    ///
    /// The current snapshot is yielded immediately on subscribe, so a screen
    /// that appears halfway through the app's life draws straight away instead
    /// of waiting for something to change. `.bufferingNewest(1)` because a slow
    /// consumer wants the current state, not a queue of the states it missed.
    ///
    /// An `AsyncStream` rather than a Combine publisher on purpose: this module
    /// has no UI dependencies and is not acquiring one.
    public func snapshotStream() -> AsyncStream<TeeTimeSnapshot> {
        let (stream, continuation) = AsyncStream<TeeTimeSnapshot>.makeStream(
            of: TeeTimeSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    // MARK: - Lifecycle

    /// Serve the cache, then refresh if the policy says so.
    ///
    /// Synchronous on the actor and returns the first snapshot, so the caller
    /// has tee times back before any network work has been awaited. The
    /// refresh, when one is warranted, runs detached.
    @discardableResult
    public func start() -> TeeTimeSnapshot {
        guard !didStart else { return snapshot }
        didStart = true

        loadCache()
        publish()

        if policy.shouldRefresh(
            lastFetch: fetchedAt, lastFailure: lastFailureAt,
            attempt: failureCount, now: clock(), force: false) {
            beginRefresh()
        }
        return snapshot
    }

    /// Ask for fresh data and wait for the answer.
    ///
    /// `force` is pull-to-refresh: it skips the staleness test and the
    /// sixty-second floor, because a user asking is better evidence than any
    /// timer. It does **not** skip single-flight — ten simultaneous forced
    /// refreshes are still one request.
    public func refresh(force: Bool = false) async {
        if !force,
           !policy.shouldRefresh(
                lastFetch: fetchedAt, lastFailure: lastFailureAt,
                attempt: failureCount, now: clock(), force: false) {
            return
        }
        await beginRefresh().value
    }

    // MARK: - The single flight

    @discardableResult
    private func beginRefresh() -> Task<Void, Never> {
        // Join the one already running. Reached only from actor-isolated code
        // with no suspension between this check and the assignment below, so
        // there is no window for a second caller to slip through.
        if let inFlight { return inFlight }

        isRefreshing = true
        // Explicitly Void: `await self?.performFetch()` on its own infers
        // Task<()?, Never>, which is not the type the single-flight slot holds.
        let task = Task<Void, Never> { [weak self] in
            await self?.performFetch()
        }
        inFlight = task
        publish()
        return task
    }

    private func performFetch() async {
        do {
            let fresh = try await remote.fetchPayload()
            let stamp = clock()
            payload = fresh
            fetchedAt = stamp
            lastError = nil
            lastFailureAt = nil
            failureCount = 0                  // a success resets the ladder
            writeCache(fresh, fetchedAt: stamp)
        } catch {
            // Keep the payload. An offline phone showing this morning's tee
            // times with a note is useful; an error screen is not.
            let failure = DataError.from(error)
            lastFailureAt = clock()
            failureCount += 1
            lastError = failure
            DataLog.failed("refresh (attempt \(failureCount))", failure, in: .remote)
        }
        inFlight = nil
        isRefreshing = false
        publish()
    }

    // MARK: - The cache, which is never allowed to be fatal

    private func loadCache() {
        do {
            guard let cached = try cache.load() else { return }
            payload = cached.payload
            fetchedAt = cached.fetchedAt
        } catch {
            // DiskPayloadCache does not throw on a bad file — it deletes it and
            // returns nil — but a different PayloadCaching might. Either way, no
            // cache is not a failure worth showing anybody.
            DataLog.failed("cache read", DataError.from(error), in: .cache)
        }
    }

    private func writeCache(_ payload: ContractPayload, fetchedAt stamp: Date) {
        do {
            try cache.save(payload, fetchedAt: stamp)
        } catch {
            // The fetch succeeded; only the next cold launch is poorer for it.
            DataLog.failed("cache write", DataError.from(error), in: .cache)
        }
    }

    // MARK: - Publishing

    private func publish() {
        let current = snapshot
        for continuation in observers.values {
            continuation.yield(current)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}
