import Foundation
import TeesContract
import TeesData
import TeesPush
import TeesViews

/// The Stage 2 composition root.
///
/// Every track built its half of a seam and stopped: `TeesData` ships
/// `TeeTimeStore.live()` but nothing that calls it, `TeesViews` ships
/// `SearchStore.apply(payload:errorDescription:)` but nothing that feeds it,
/// `AuthActions` is a protocol `AuthService` already satisfies but nothing
/// hands to a screen. This type is where those wires actually get joined —
/// deliberately the only place in the app that imports both `TeesData` and
/// `TeesViews`, so the module boundary the five tracks were built behind stays
/// real rather than aspirational.
@MainActor
final class AppSession: ObservableObject, AuthActions {

    let searchStore = SearchStore()
    let ledger = BookingLedger()

    @Published private(set) var email: String?
    @Published private(set) var alerts: [TeesViews.WatchDraft] = []
    /// True from the moment a watches fetch throws until one next succeeds.
    ///
    /// `alerts == []` is not on its own evidence of anything — it is the
    /// initial value, the honest result of an empty list, *and* what a failed
    /// fetch leaves behind (the catch in `refreshAlerts()` never touches
    /// `alerts`). Without this flag, a signed-in golfer whose watches fail to
    /// load offline sees exactly the same "No alerts yet" `AccountScreen`
    /// shows someone who has genuinely never set one — no error, and (until
    /// this flag existed to drive a retry button) no way back short of a full
    /// relaunch. See `AppSessionAlertsOfflineTests`.
    @Published private(set) var alertsLoadFailed = false
    @Published private(set) var configurationFailure: String?

    /// Whether `OnboardingFlow` should be on screen. Set once, after first
    /// sign-in, when this device has never completed it — see
    /// `refreshUserData()`. `OnboardingFlow`'s notification-priming step is
    /// the only place in the app that ever calls
    /// `UNUserNotificationCenter.requestAuthorization` (via
    /// `SystemNotificationPermission`), so until this flow has run once,
    /// `PushPermission.status()` can never be anything but `.notDetermined`
    /// and `pushRegistrar.register()` below is unreachable in practice.
    @Published var showOnboarding = false

    /// Where a tapped push notification says the app should go, for
    /// `TeesForTheBoysApp`/`TeesRootView` to act on. Fed by `pushCoordinator`,
    /// which already buffers a route tapped before this was subscribed to
    /// (cold launch) — see `observePushRoutes()`.
    @Published private(set) var pendingRoute: PushRoute?

    /// Turns a tapped notification into a route. Constructed immediately,
    /// not in `start()`: a cold launch can hand `AppDelegate` a tap before
    /// `start()` has run at all, and `PushCoordinator` is what holds that
    /// until `observePushRoutes()` attaches.
    let pushCoordinator = PushCoordinator()

    private var teeTimeStore: TeeTimeStore?
    private var authService: AuthService?
    private var watchRepository: WatchRepository?
    private var bookingRepository: BookingRepository?
    /// Internal, not private: `AppSession` builds this off a real Supabase
    /// client with no factory seam (`makeTeeTimeStore`'s pattern, applied to
    /// push, was judged not worth it for one call site) — a test that needs
    /// to drive `clearUserData()`'s retire-on-sign-out path assigns a fake
    /// one directly instead. See `AppSessionPushRetireOnSignOutTests`.
    var pushRegistrar: PushRegistrar?
    private var snapshotTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?
    private var pushRouteTask: Task<Void, Never>?

    /// How `start()` gets its store. `TeeTimeStore.live()` by default;
    /// overridable so a test can hand in one built on fakes instead of a real
    /// Supabase client — see `AppSessionTests`.
    private let makeTeeTimeStore: () throws -> TeeTimeStore

    init(makeTeeTimeStore: @escaping () throws -> TeeTimeStore = { try TeeTimeStore.live() }) {
        self.makeTeeTimeStore = makeTeeTimeStore
        // `start()` below has real async work — `makeTeeTimeStore()`,
        // `SupabaseClientProvider.client()`, `await auth.restoreSession()` —
        // before its first `apply(_:)`. `TeesForTheBoysApp` only *schedules*
        // that work (`.task { await session.start() }`); it does not run any
        // part of it before `TeesRootView` mounts. `SearchScreen.onAppear`
        // fires synchronously in that same mount and calls `store.load()`
        // whenever `state == .idle` — `SearchStore`'s own initial value — so
        // without this line a cold launch briefly replayed the bundled
        // `golden.json` fixture as if it were live data, on every launch,
        // before the first real snapshot overwrote it a frame later. Setting
        // this here, synchronously in `init`, is true before any of that:
        // there genuinely is no cache yet and no fetch has landed (`apply`'s
        // own doc comment), so `.loading` is the honest state to start in
        // whenever a live pipeline is coming — which is every case but a
        // preview or a `TeesViews`-only test, neither of which constructs an
        // `AppSession` at all.
        searchStore.apply(payload: nil)
    }

    // MARK: - Launch

    func start() async {
        do {
            // TEES_SUPABASE_URL / TEES_SUPABASE_ANON_KEY, set on the scheme's
            // run arguments so the real key never lands in this file or in
            // git. SupabaseConfiguration.resolve() (called inside
            // SupabaseClientProvider.client()) checks the environment before
            // Info.plist, which is what makes that work.
            let store = try makeTeeTimeStore()
            let client = try SupabaseClientProvider.client()
            teeTimeStore = store

            let auth = AuthService(client: client)
            authService = auth
            watchRepository = WatchRepository(client: client, session: auth)
            bookingRepository = BookingRepository(client: client, session: auth)

            // Built here, not lazily on first use: `AppDelegate` can hand a
            // device token or a tap to this session as soon as `start()`
            // returns, and both need somewhere to land.
            let tokenRepository = PushTokenRepository(client: client, session: auth)
            let registrar = PushRegistrar(sink: PushTokenRepositorySink(repository: tokenRepository))
            pushRegistrar = registrar
            observePushRoutes()

            ledger.onBookingConfirmed = { [weak self] confirmed in
                self?.persistBooking(confirmed)
            }

            _ = try? await auth.restoreSession()
            if case .signedIn(_, let signedInEmail) = auth.state {
                email = signedInEmail
                refreshUserData()
            }
            observeAuth(auth)

            let first = await store.start()
            apply(first)
            observeSnapshots(store)
        } catch {
            configurationFailure = String(describing: error)
        }
    }

    private func observeSnapshots(_ store: TeeTimeStore) {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            let stream = await store.snapshotStream()
            for await snapshot in stream {
                self?.apply(snapshot)
            }
        }
    }

    private func observeAuth(_ auth: AuthService) {
        authTask?.cancel()
        authTask = Task { [weak self] in
            for await state in auth.stateChanges {
                guard let self else { return }
                switch state {
                case .signedIn(_, let signedInEmail):
                    self.email = signedInEmail
                    self.refreshUserData()
                case .signedOut:
                    self.email = nil
                    self.clearUserData()
                }
            }
        }
    }

    private func apply(_ snapshot: TeeTimeSnapshot) {
        searchStore.apply(
            payload: snapshot.payload,
            errorDescription: snapshot.isEmptyAndFailing
                ? snapshot.lastError.map(Self.emptyFailureMessage) : nil)
        // Not `== .offline`: a DNS failure, a refused connection and a 5xx
        // are `.transport`/`.server`, never `.offline` (`DataError.from`),
        // but `isRetryable`'s own doc says offline and transport failures —
        // and any 5xx — are equally "the network's fault". Missing any of
        // them here left a stale cache on screen with no banner at all.
        //
        // Gated on `hasPayload`: `ViewsOfflineBanner`'s copy ("these are the
        // last tee times we loaded") is only true once something actually
        // has been. Without this guard, a cold launch with no cache at all
        // that failed offline set this anyway — the banner sat directly
        // above the full-screen error `isEmptyAndFailing` produces below,
        // both claiming tee times were loaded/saved over a screen where
        // nothing ever was.
        searchStore.isOffline = snapshot.hasPayload && (snapshot.lastError?.isRetryable ?? false)
    }

    /// The full-screen error's message for `TeeTimeSnapshot.isEmptyAndFailing`
    /// — reached only when `payload == nil`, i.e. nothing has ever loaded or
    /// been saved on this device. `DataError.offline.description` ("You are
    /// offline. Showing the last tee times we saved.") is honest everywhere
    /// else that sentence is used (`AuthDisplayableError`, where it is a
    /// generic sign-in failure message with no payload involved at all), but
    /// would be a straightforward lie here, so `.offline` gets its own copy
    /// for this one call site instead of `description`.
    private static func emptyFailureMessage(for error: DataError) -> String {
        guard error == .offline else { return error.description }
        return "You're offline, and no tee times have reached this device yet."
    }

    /// What the search screen's own "Try again" actually runs.
    ///
    /// `SearchStore.load()` only replays the bundled fixture — it is a
    /// fixture-only store's honest fallback, not a network retry. The real
    /// retry is this: re-fire `TeeTimeStore`'s fetch. `observeSnapshots` is
    /// already subscribed to its stream, so the result — success, failure, or
    /// still nothing — reaches `searchStore` the same way every other
    /// snapshot does; nothing here touches `searchStore` directly.
    func retrySearch() {
        guard let teeTimeStore else { return }
        Task { await teeTimeStore.refresh(force: true) }
    }

    /// `TeesRootView`'s `scenePhase` forwarding, the far side of the return
    /// trip.
    ///
    /// This is the only thing that ever asks `TeeTimeStore` to check
    /// staleness again after the one fetch `start()` kicks off at cold
    /// launch: a SwiftUI `.task` runs once per view-lifetime, so nothing else
    /// re-fires it when the app is merely backgrounded and resumed (as
    /// opposed to relaunched). Not `force`: `TeeTimeStore.refresh()`'s own
    /// floor and staleness check still decide whether this is worth a
    /// request — a tap back into the app three seconds after leaving it
    /// should not hit the network any more than any other tab switch does.
    func appDidBecomeActive() {
        guard let teeTimeStore else { return }
        Task { await teeTimeStore.refresh() }
    }

    // MARK: - AuthActions

    func signIn(email: String, password: String) async throws {
        try await requireAuth().signIn(email: email, password: password)
    }

    func signUp(email: String, password: String) async throws {
        try await requireAuth().signUp(email: email, password: password)
    }

    func signOut() async throws {
        try await requireAuth().signOut()
    }

    private func requireAuth() -> AuthService {
        guard let authService else {
            preconditionFailure("AuthActions called before AppSession.start()")
        }
        return authService
    }

    // MARK: - Watches

    /// `onSignedIn`. Also called directly at launch when a restored session is
    /// already signed in — the auth stream only yields on a *change*, and a
    /// restore does not fire one.
    func refreshUserData() {
        guard watchRepository != nil else { return }
        if OnboardingState.isComplete(in: UserDefaultsViewsStore()) {
            // Onboarding already ran on this device — if permission was
            // granted there (or in Settings since), pick registration back
            // up. A no-op when it was not.
            Task { await registerForPushIfAuthorized() }
        } else {
            showOnboarding = true
        }
        refreshAlerts()
    }

    /// Just the watches half of `refreshUserData()`, callable on its own.
    ///
    /// Split out so `AccountScreen`'s retry button can re-run the one thing
    /// that actually failed — a fetch — without also replaying onboarding or
    /// re-attempting push registration, which `refreshUserData()` does
    /// alongside it and which have nothing to do with a stale alerts list.
    func refreshAlerts() {
        guard let watchRepository else { return }
        Task {
            do {
                let watches = try await watchRepository.list()
                applyWatchesOutcome(.success(watches))
            } catch {
                applyWatchesOutcome(.failure(error))
            }
        }
    }

    /// Where a watches fetch's outcome — from `refreshAlerts()`, or a test
    /// standing in for one — actually lands on `alerts`/`alertsLoadFailed`.
    ///
    /// Pulled out to exactly this shape so the failure path is testable with
    /// no `WatchRepository` and no network at all: `AppSession` builds its
    /// `WatchRepository` from a real `SupabaseClient` with no seam for
    /// swapping in a fake one (unlike `TeeTimeStore`, which is fully
    /// injectable — see `makeTeeTimeStore`), so a fake outcome handed
    /// directly here is the only way to pin what a failure actually leaves
    /// behind: `alerts` untouched (never reset to `[]`) and
    /// `alertsLoadFailed` true, which is the whole fix — see
    /// `AppSessionAlertsOfflineTests`.
    func applyWatchesOutcome(_ result: Result<[Watch], Error>) {
        switch result {
        case .success(let watches):
            alerts = watches.map(Self.viewsDraft(from:))
            alertsLoadFailed = false
        case .failure(let error):
            alertsLoadFailed = true
            DataLog.userdata.error("could not load watches: \(String(describing: error), privacy: .public)")
        }
    }

    func clearUserData() {
        alerts = []
        alertsLoadFailed = false

        // Sign-out (or alerts turned off) must give this device's token
        // back — otherwise it stays live in `push_tokens` for whoever was
        // signed in, and a second golfer sharing the phone signs in to find
        // the first golfer still receiving their alerts. `retire()` is a
        // no-op when nothing has ever registered a token, so this is safe to
        // call unconditionally.
        if let pushRegistrar {
            Task { await pushRegistrar.retire() }
        }
    }

    // MARK: - Push

    /// `OnboardingFlow`'s `onFinished`. Notifications were only just granted
    /// (or skipped) at the system prompt, so this is the first moment a
    /// registration attempt can possibly succeed.
    func finishOnboarding(granted: Bool) {
        showOnboarding = false
        guard granted else { return }
        Task { await registerForPushIfAuthorized() }
    }

    /// Ask iOS for a device token, but only if this device is actually
    /// allowed to receive one — calling `register()` with no permission is
    /// harmless but pointless (`PushRegistrar`'s own doc comment).
    private func registerForPushIfAuthorized() async {
        guard let pushRegistrar else { return }
        let status = await PushPermission.status()
        guard status.allowsAlerts else { return }
        pushRegistrar.register()
    }

    /// `AppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    func handlePushRegistration(deviceToken: Data) {
        pushRegistrar?.didRegister(deviceToken: deviceToken)
    }

    /// `AppDelegate.application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    /// Ordinary on a simulator — see `PushRegistrar`'s own doc comment.
    func handlePushRegistrationFailure(_ error: Error) {
        pushRegistrar?.didFailToRegister(error)
    }

    /// `AppDelegate.userNotificationCenter(_:didReceive:)` — cold, backgrounded
    /// or foregrounded, this is the one call iOS makes for a tap in all three.
    @discardableResult
    func handlePushTap(userInfo: [AnyHashable: Any]) -> PushRoute? {
        pushCoordinator.handleTap(userInfo: userInfo)
    }

    /// `TeesRootView` calls this once it has acted on `pendingRoute`, so the
    /// same tap is not navigated to twice.
    func consumePendingRoute() {
        pendingRoute = nil
        pushCoordinator.clearLatest()
    }

    /// Where a route lands, as a tab. Pure and static on purpose — see
    /// `SearchScreen.Presentation`'s own doc comment on why a decision like
    /// this is lifted out into something a test can pin without rendering
    /// anything: `TeesForTheBoysApp` is the only file that imports both
    /// `TeesPush` (for `PushRoute`) and `TeesViews` (for `TeesTab`), so this is
    /// also the only place this mapping is allowed to live.
    ///
    /// `.slot` goes to Search — the tee time itself lives in that list.
    /// `.watch` goes to Account — that is where a golfer's alerts are shown.
    /// Neither lands on the exact row yet (opening `SlotDetailScreen` or
    /// highlighting one alert straight from a tap): real, worth doing, and a
    /// separate, larger change to `SearchScreen`/`AccountScreen` than this
    /// wiring fix. Documented rather than silently claimed as done.
    static func tab(for route: PushRoute) -> TeesTab {
        switch route {
        case .slot: return .search
        case .watch: return .account
        }
    }

    private func observePushRoutes() {
        pushRouteTask?.cancel()
        pushRouteTask = Task { [weak self] in
            guard let self else { return }
            for await route in self.pushCoordinator.routes() {
                self.pendingRoute = route
            }
        }
    }

    /// The active filters already describe the watch completely (CONTRACT.md
    /// "alerts" rule), so this is the whole create path: map, write, and swap
    /// the optimistic local draft for one carrying the server's id.
    /// Returns whether the watch actually landed. `AlertFromSearchButton`
    /// awaits this before it will show "Alert saved" — showing it on the
    /// strength of `alerts.append(draft)` below, before the network call
    /// resolves, was the bug: offline, a DNS failure, Supabase down or a
    /// dropped connection all threw out of `watchRepository.create`, which
    /// this already rolled back locally, but nothing ever told the view.
    @discardableResult
    func createWatch(_ draft: TeesViews.WatchDraft) async -> Bool {
        guard let watchRepository else { return false }
        alerts.append(draft)
        do {
            let created = try await watchRepository.create(Self.dataDraft(from: draft.filters))
            if let index = alerts.firstIndex(where: { $0.id == draft.id }) {
                alerts[index] = TeesViews.WatchDraft(
                    id: created.id, filters: draft.filters, courses: draft.courses, today: draft.today)
            }
            return true
        } catch {
            alerts.removeAll { $0.id == draft.id }
            DataLog.userdata.error("could not save watch: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func deleteWatch(_ draft: TeesViews.WatchDraft) {
        guard let watchRepository else { return }
        let removed = draft
        alerts.removeAll { $0.id == draft.id }
        Task {
            do {
                try await watchRepository.delete(id: draft.id)
            } catch {
                alerts.append(removed)
                DataLog.userdata.error("could not delete watch: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Did-you-book

    /// Cancelling the watches it satisfies is NOT done here. That was track
    /// B's plan when `BookingRepository`'s doc comment was written, but E1
    /// (`alerts_0010_watch_lifecycle.sql`) landed a server-side trigger that
    /// does exactly this on the `bookings` insert — reimplementing
    /// `watch_matches` on the client would be the same rule in two places,
    /// guaranteed to drift. `BookingRepository.swift`'s comment describing a
    /// client-side seam is stale against what E actually shipped; worth a
    /// one-line doc fix, not a functional issue.
    ///
    /// Which is exactly why this method must never silently skip the insert:
    /// a golfer who tapped "Booked it" already told us, and skipping the
    /// write is not just a missing history row, it is a watch that trigger
    /// never runs for and so never gets cancelled. `slotToPersist` below is
    /// what makes that insert unconditional.
    private func persistBooking(_ confirmed: ConfirmedBooking) {
        guard let bookingRepository else { return }
        let slot = Self.slotToPersist(for: confirmed, in: searchStore.payload)
        Task {
            do {
                _ = try await bookingRepository.confirmBooking(slot: slot, players: nil)
            } catch {
                DataLog.userdata.error("could not record booking: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The slot to hand `BookingRepository.confirmBooking`, for a booking the
    /// golfer already confirmed.
    ///
    /// Prefers the live snapshot's own copy — the richer one, with the
    /// current price and booking URL — when the slot the golfer tapped out to
    /// is still in it. But a slot that has since sold out is dropped
    /// *entirely* by the next scrape rather than kept with `spots=0`
    /// (`scraper/scrape.py`'s `if spots_available <= 0: continue`), so "not in
    /// the live payload" is the ordinary shape of a successful booking, not a
    /// reason to give up on recording one. `ConfirmedBooking` already carries
    /// every field `confirmBooking` actually reads off a `Slot` — captured at
    /// tap-out/confirm time, not guessed — so this falls back to rebuilding
    /// one from those instead of skipping the write. The fields
    /// `ConfirmedBooking` does not carry (price, the booking URL, spot counts)
    /// are cosmetic here: `watch_matches` (alerts_0010_watch_lifecycle.sql)
    /// treats an unpriced round as matching a price-capped watch by design,
    /// and none of the rest feeds that predicate at all.
    ///
    /// Never nil: every field `Slot` requires is one `ConfirmedBooking`
    /// already has. `nonisolated`: a pure function of its two arguments, no
    /// actor state involved, so nothing about it needs the main actor.
    nonisolated static func slotToPersist(for confirmed: ConfirmedBooking, in payload: ContractPayload?) -> Slot {
        if let live = payload?.slots.first(where: { $0.id == confirmed.slotID }) {
            return live
        }
        return Slot(
            id: confirmed.slotID,
            courseSlug: confirmed.courseSlug,
            courseName: confirmed.courseName,
            region: "",
            driveMinutesFromBondi: nil,
            par: confirmed.par,
            requiresRegistration: false,
            teeDate: confirmed.teeDate,
            teeTime: confirmed.teeTime,
            teeAt: confirmed.teeAt,
            spotsAvailable: 0,
            totalSpots: 0,
            holes: confirmed.holes,
            priceMin: nil,
            priceMax: nil,
            priceTiers: [],
            bookingType: "",
            bookingURLString: "")
    }

    // MARK: - Mapping

    /// `TeesViews.WatchDraft` is a UI draft with rendered sentences;
    /// `TeesData.WatchDraft` is the wire row `WatchRepository` writes. Two
    /// types with the same name in different modules on purpose — see
    /// `TeesViews/WatchDraft.swift`'s own doc comment — and this is the one
    /// place that is allowed to know both.
    private static func dataDraft(from filters: SearchFilters) -> TeesData.WatchDraft {
        TeesData.WatchDraft(
            courseSlugs: filters.courseSlugs.isEmpty ? nil : Array(filters.courseSlugs).sorted(),
            weekdays: isoWeekdays(from: filters.days),
            timeFrom: timeWindow(for: filters.timesOfDay).from,
            timeTo: timeWindow(for: filters.timesOfDay).to,
            minPlayers: filters.players,
            holes: holesValue(filters.holes),
            priceMax: filters.maxPrice,
            maxDriveMinutes: filters.maxDriveMinutes,
            active: true)
    }

    /// `filters.days` is a set of specific `tee_date` strings — the near-term
    /// dates the search screen shows, not a recurring pattern. `watches`
    /// only has room for a recurring weekday or a single continuous
    /// `date_from..date_to` window (CONTRACT.md's schema, frozen). A weekday
    /// is the closer fit: a watch is long-running, and "any Saturday" stays
    /// useful long after the 5-day window that produced the original pick has
    /// rolled past. The trade-off is real and worth Will seeing: picking two
    /// non-adjacent Saturdays and a Tuesday becomes "Tuesdays and Saturdays",
    /// slightly broader than the exact dates tapped.
    private static func isoWeekdays(from days: Set<String>) -> [Int]? {
        guard !days.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var isoWeekdays = Set<Int>()
        for day in days {
            guard let date = formatter.date(from: day) else { continue }
            // Foundation's `.weekday` is 1 = Sunday ... 7 = Saturday; the
            // column comment on `watches.weekdays` is ISO-8601, 1 = Monday.
            let sunday1 = calendar.component(.weekday, from: date)
            isoWeekdays.insert(sunday1 == 1 ? 7 : sunday1 - 1)
        }
        return isoWeekdays.isEmpty ? nil : isoWeekdays.sorted()
    }

    /// Same shape of trade-off as the days above, one level smaller: `watches`
    /// holds one continuous `time_from..time_to` window, and the search
    /// screen's five time-of-day buckets (`SearchFilters.TimeOfDay`) are a
    /// multi-select. Early morning **and** twilight, picked together, cannot
    /// be represented without also covering the midday in between — this
    /// takes the widest span across whatever is selected rather than
    /// inventing a gapped window the schema has no room for. Worth a product
    /// call from Will if it comes up in practice; documented rather than
    /// silently narrowed.
    private static func timeWindow(for buckets: Set<SearchFilters.TimeOfDay>) -> (from: String, to: String) {
        guard !buckets.isEmpty else {
            return (TeesData.WatchDraft.defaultTimeFrom, TeesData.WatchDraft.defaultTimeTo)
        }
        let hours: [Range<Int>] = buckets.map { bucket in
            switch bucket {
            case .earlyMorning: return 0..<7
            case .morning: return 7..<11
            case .midday: return 11..<14
            case .afternoon: return 14..<17
            case .twilight: return 17..<24
            }
        }
        let start = hours.map(\.lowerBound).min() ?? 0
        let end = hours.map(\.upperBound).max() ?? 24
        return (
            String(format: "%02d:00:00", start),
            end >= 24 ? "23:59:59" : String(format: "%02d:00:00", end))
    }

    private static func holesValue(_ filter: SearchFilters.HolesFilter) -> Int? {
        switch filter {
        case .nine: return 9
        case .eighteen: return 18
        case .any: return nil
        }
    }

    /// The reverse direction, for redisplaying a watch saved in an earlier
    /// session. There is no exact inverse of `isoWeekdays`/`timeWindow` — a
    /// recurring weekday cannot be turned back into the specific dates that
    /// produced it without knowing which dates are on screen right now — so
    /// this renders with `days` and `timesOfDay` left empty ("any day",
    /// "any time") rather than guessing. The sentence undersells a watch that
    /// actually carries a weekday or time restriction; the delete button and
    /// the label still work correctly, which is what the account tab needs.
    /// A closer redisplay is a real follow-up, not a Stage 2 blocker.
    private static func viewsDraft(from watch: Watch) -> TeesViews.WatchDraft {
        var filters = SearchFilters.standard
        filters.players = watch.minPlayers
        if let holes = watch.holes {
            filters.holes = holes == 9 ? .nine : .eighteen
        } else {
            filters.holes = .any
        }
        filters.maxPrice = watch.priceMax
        filters.maxDriveMinutes = watch.maxDriveMinutes
        filters.courseSlugs = Set(watch.courseSlugs ?? [])
        return TeesViews.WatchDraft(id: watch.id, filters: filters, courses: [], today: "")
    }
}
