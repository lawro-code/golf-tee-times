import Foundation
import TeesContract
import TeesData
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
    @Published private(set) var configurationFailure: String?

    private var teeTimeStore: TeeTimeStore?
    private var authService: AuthService?
    private var watchRepository: WatchRepository?
    private var bookingRepository: BookingRepository?
    private var snapshotTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?

    // MARK: - Launch

    func start() async {
        do {
            // TEES_SUPABASE_URL / TEES_SUPABASE_ANON_KEY, set on the scheme's
            // run arguments so the real key never lands in this file or in
            // git. SupabaseConfiguration.resolve() (called inside
            // SupabaseClientProvider.client()) checks the environment before
            // Info.plist, which is what makes that work.
            let store = try TeeTimeStore.live()
            let client = try SupabaseClientProvider.client()
            teeTimeStore = store

            let auth = AuthService(client: client)
            authService = auth
            watchRepository = WatchRepository(client: client, session: auth)
            bookingRepository = BookingRepository(client: client, session: auth)

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
            errorDescription: snapshot.isEmptyAndFailing ? snapshot.lastError?.description : nil)
        searchStore.isOffline = (snapshot.lastError == .offline)
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
        guard let watchRepository else { return }
        Task {
            do {
                let watches = try await watchRepository.list()
                self.alerts = watches.map(Self.viewsDraft(from:))
            } catch {
                DataLog.userdata.error("could not load watches: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func clearUserData() {
        alerts = []
    }

    /// The active filters already describe the watch completely (CONTRACT.md
    /// "alerts" rule), so this is the whole create path: map, write, and swap
    /// the optimistic local draft for one carrying the server's id.
    func createWatch(_ draft: TeesViews.WatchDraft) {
        guard let watchRepository else { return }
        alerts.append(draft)
        Task {
            do {
                let created = try await watchRepository.create(Self.dataDraft(from: draft.filters))
                if let index = alerts.firstIndex(where: { $0.id == draft.id }) {
                    alerts[index] = TeesViews.WatchDraft(
                        id: created.id, filters: draft.filters, courses: draft.courses, today: draft.today)
                }
            } catch {
                alerts.removeAll { $0.id == draft.id }
                DataLog.userdata.error("could not save watch: \(String(describing: error), privacy: .public)")
            }
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

    /// `ConfirmedBooking` is deliberately thinner than `TeesData.Slot`
    /// (`BookingLedger`'s own doc comment: it holds nothing that would need
    /// `TeesData` to produce). The full slot — course_slug, price, the booking
    /// URL — is recovered here from the live snapshot rather than invented,
    /// which only works while that slot is still in the payload the golfer
    /// searched. A slot that has since gone (booked out, or the next scrape
    /// already marked it gone) cannot be recovered from, so the record is
    /// skipped rather than written with guessed fields. `BookingLedger`
    /// already marked it answered locally either way — see its own docs on
    /// why "asked once" holds regardless of what became of it.
    ///
    /// Cancelling the watches it satisfies is NOT done here. That was track
    /// B's plan when `BookingRepository`'s doc comment was written, but E1
    /// (`alerts_0010_watch_lifecycle.sql`) landed a server-side trigger that
    /// does exactly this on the `bookings` insert — reimplementing
    /// `watch_matches` on the client would be the same rule in two places,
    /// guaranteed to drift. `BookingRepository.swift`'s comment describing a
    /// client-side seam is stale against what E actually shipped; worth a
    /// one-line doc fix, not a functional issue.
    private func persistBooking(_ confirmed: ConfirmedBooking) {
        guard let bookingRepository else { return }
        guard let slot = searchStore.payload?.slots.first(where: { $0.id == confirmed.slotID }) else {
            DataLog.userdata.error("booked slot \(confirmed.slotID, privacy: .public) was not in the live payload; not recorded")
            return
        }
        Task {
            do {
                _ = try await bookingRepository.confirmBooking(slot: slot, players: nil)
            } catch {
                DataLog.userdata.error("could not record booking: \(String(describing: error), privacy: .public)")
            }
        }
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
