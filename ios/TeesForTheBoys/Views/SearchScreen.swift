import SwiftUI
import TeesContract
import TeesDesign

/// Search is the product, and this is the screen it lives on.
///
/// The shape it is trying to have is Airbnb's, not a settings form's: chips
/// across the top, results underneath, and the results moving **as the chips
/// move**. There is no Apply button and no submit step anywhere in this
/// screen — a filter that needs confirming is a filter nobody experiments
/// with, and experimenting is how a golfer finds the 6:16 at Warringah they
/// did not know to ask for.
///
/// Three decisions worth knowing about before editing it:
///
/// - **The alert button changes job with the results.** With rounds on screen
///   it is a quiet inline bar; with none it becomes the empty state's primary
///   call to action. A search that returns nothing is the single moment an
///   alert is worth the most, so that is where the loudest version of the
///   button goes.
/// - **The list is lazy and derives nothing.** `SearchStore` has already run
///   `SlotQuery` once and published `sections`; the body reads that array and
///   nothing else. golden.json is 1755 slots and a `ForEach` that filtered or
///   sorted per row would run that work thousands of times per scroll.
/// - **Time is never recomputed.** Day headings come from
///   `SlotFormatting.dayTitle` against `store.today`. CONTRACT.md §4 resolves
///   Sydney's DST once, on the server; a screen deriving its own calendar day
///   is how a Sunday in October ends up labelled Saturday.
public struct SearchScreen: View {
    @ObservedObject private var store: SearchStore
    @ObservedObject private var ledger: BookingLedger

    private let isSignedIn: Bool
    private let onCreateWatch: (WatchDraft) async -> Bool
    private let onRequireSignIn: () -> Void

    /// What "Try again" on the failed state actually does.
    ///
    /// `TeesViews` has no `TeesData` dependency and `SearchStore.load()` only
    /// ever replays the bundled fixture — it has no network to retry. The
    /// live retry (re-firing `TeeTimeStore`'s fetch) can only be supplied by
    /// whoever composed a live store in, which is `AppSession`, outside this
    /// module. Left `nil` — previews and tests with no live backing behind
    /// them — this falls back to `store.load()`, the only retry a
    /// fixture-only store can honestly offer.
    let onRetry: () -> Void

    /// - Parameters:
    ///   - store: ticket C1's store. Already loaded, or loaded on first appear.
    ///   - ledger: ticket C4's booking ledger, handed down to the detail screen
    ///     so a tap out to a club's site is recorded before the app leaves.
    ///   - isSignedIn: browsing works signed out; alerts are the wall. Passed in
    ///     rather than read here because Stage 2 owns the session.
    ///   - onCreateWatch: called with the draft to create an alert; reports
    ///     whether the save actually landed, so a network failure never shows
    ///     as a confirmed "Alert saved" (`AlertFromSearchButton`'s own doc
    ///     comment on `tap()`).
    ///   - onRequireSignIn: called instead, when there is no session yet.
    ///   - onRetry: called when the golfer taps "Try again" on a failed load.
    ///     `AppSession` wires this to `TeeTimeStore.refresh(force:)`; leaving
    ///     it `nil` falls back to replaying the bundled fixture, which is
    ///     only ever correct in a preview or a test.
    public init(
        store: SearchStore,
        ledger: BookingLedger,
        isSignedIn: Bool,
        onCreateWatch: @escaping (WatchDraft) async -> Bool,
        onRequireSignIn: @escaping () -> Void,
        onRetry: (() -> Void)? = nil
    ) {
        self.store = store
        self.ledger = ledger
        self.isSignedIn = isSignedIn
        self.onCreateWatch = onCreateWatch
        self.onRequireSignIn = onRequireSignIn
        self.onRetry = onRetry ?? { store.load() }
    }

    public var body: some View {
        // Read once per pass. Every branch below agrees on the same snapshot,
        // and nothing in the list re-derives it.
        let sections = store.sections
        let presentation = Presentation(state: store.state, resultCount: store.resultCount)

        NavigationStack {
            content(presentation: presentation, sections: sections)
                .navigationTitle("Tee times")
                .navigationDestination(for: SlotResult.self) { result in
                    SlotDetailScreen(slot: result.slot, today: store.today, ledger: ledger)
                }
                .safeAreaInset(edge: .top, spacing: 0) { topChrome }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if presentation.showsInlineAlertButton { inlineAlertBar }
                }
                .onAppear {
                    // Only on a first appear. Coming back from the Upcoming tab
                    // must not re-read the fixture and scroll the list home.
                    if store.state == .idle { store.load() }
                }
        }
    }

    // MARK: - The four states

    /// Not `private`: `SearchScreenEmptyStateLayoutTests` renders this
    /// directly, isolated from `topChrome`'s own chip-row `ScrollView`, to
    /// measure which of the four states puts a real `UIScrollView` in the
    /// hierarchy — same reasoning as `dayHeader(for:)` and
    /// `emptyMessage(freshness:)` below.
    @ViewBuilder
    func content(presentation: Presentation, sections: [SlotDaySection]) -> some View {
        switch presentation {
        case .loading:
            CenteredWhenItFits {
                ViewsLoadingState(message: "Finding tee times across the fifteen clubs\u{2026}")
            }

        case .failed(let reason):
            CenteredWhenItFits {
                ViewsErrorState(
                    title: "Couldn't load tee times",
                    message: reason,
                    retry: onRetry)
            }

        case .empty:
            CenteredWhenItFits {
                emptyState
            }

        case .results:
            resultsList(sections)
        }
    }

    /// No results is not a dead end. The alert is the thing to do about it, so
    /// it is the state's primary action rather than a link tucked underneath.
    ///
    /// Wrapped in `CenteredWhenItFits` by `content(presentation:sections:)`,
    /// not left to size itself directly — see that type's doc comment for why
    /// a plain `.frame(maxHeight: .infinity)` here truncated and overlapped
    /// this exact headline and message at large Dynamic Type sizes
    /// (`SearchScreenEmptyStateLayoutTests`).
    private var emptyState: some View {
        TeesEmptyState(
            headline: "Nothing open for this search",
            message: Self.emptyMessage(freshness: store.freshness)
        ) {
            AlertFromSearchButton(
                draft: draft,
                prominence: .primary,
                isSignedIn: isSignedIn,
                onCreate: onCreateWatch,
                onRequireSignIn: onRequireSignIn)
        }
    }

    /// A `List` because it is lazy: only the rows on screen are built, which is
    /// what makes 1755 slots scroll.
    ///
    /// `.refreshable` is the only manual retry surface this screen can offer
    /// while a cached payload is on screen: `AppSession.apply` never lets
    /// `SearchStore` reach `.failed` (and so never shows `ViewsErrorState`'s
    /// "Try again" button) unless there is no cached payload at all
    /// (`TeeTimeSnapshot.isEmptyAndFailing`'s own `payload == nil` guard) — so
    /// a golfer staring at this morning's tee times after a failed background
    /// refresh had no gesture that asked for fresh data, only the automatic
    /// backoff retry to wait out. `onRetry` is `AppSession.retrySearch`
    /// wherever this is wired live, which forces `TeeTimeStore.refresh` past
    /// that backoff exactly the way a pull-to-refresh should.
    private func resultsList(_ sections: [SlotDaySection]) -> some View {
        List {
            ForEach(sections) { section in
                Section {
                    // `docs/app.js`'s `.course-block`: nearest club first,
                    // its own slots grouped under one `TeesCourseHeader`
                    // rather than repeating the club's name on every row.
                    ForEach(SlotQuery.courseGroups(section.results)) { group in
                        courseBlock(group)
                    }
                } header: {
                    Self.dayHeader(for: section)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .refreshable { onRetry() }
    }

    /// One `.course-block`: a `TeesCourseHeader` naming the club, then its
    /// slots as `TeesSlotRow` cards. Grouped as one `@ViewBuilder` (not a
    /// nested `List` `Section` — `List` sections do not nest) so the header
    /// and its rows stay adjacent inside the day's own `Section`.
    @ViewBuilder
    private func courseBlock(_ group: SlotCourseGroup) -> some View {
        if let first = group.results.first {
            TeesCourseHeader(slot: first.slot)
                .padding(.horizontal, TeesSpacing.lg)
                .padding(.top, TeesSpacing.md)
                .padding(.bottom, TeesSpacing.xs)

            ForEach(group.results) { result in
                NavigationLink(value: result) {
                    TeesSlotRow(slot: result.slot)
                }
                .padding(.horizontal, TeesSpacing.lg)
                .padding(.vertical, TeesSpacing.xxs)
            }
        }
    }

    // MARK: - Chrome

    private var topChrome: some View {
        VStack(spacing: 0) {
            FilterBar(store: store)

            if store.isOffline {
                ViewsOfflineBanner()
            }
            // Renders nothing when `bannerText` is nil, so it can sit here
            // unconditionally.
            ViewsStaleBanner(summary: store.freshness)
        }
        .background(.bar)
    }

    /// Pinned to the bottom safe area rather than placed at the end of the
    /// list: a thumb reaches it without scrolling past 1755 rows first.
    private var inlineAlertBar: some View {
        AlertFromSearchButton(
            draft: draft,
            prominence: .inline,
            isSignedIn: isSignedIn,
            onCreate: onCreateWatch,
            onRequireSignIn: onRequireSignIn)
            .padding(.horizontal, TeesSpacing.lg)
            .padding(.vertical, TeesSpacing.sm)
            .background(.bar)
    }

    private var draft: WatchDraft {
        WatchDraft(filters: store.filters, courses: store.courses, today: store.today)
    }

    // MARK: - What the screen is showing, as a value

    /// The screen's state, lifted out of the body.
    ///
    /// `ios/project.yml` is frozen for Stage 1 — no ViewInspector, no snapshot
    /// library — so a `body` cannot be asserted on. Naming the state selection
    /// makes the two decisions that matter testable: which of the four states
    /// is on screen, and which prominence the alert button takes.
    public enum Presentation: Equatable, Sendable {
        case loading
        case failed(String)
        case empty
        case results(Int)

        /// `.idle` presents as loading rather than as empty: "we have not
        /// looked yet" and "we looked and there is nothing" are different
        /// claims, and showing the second one first is a lie that lasts about
        /// a frame but reads as a broken screen.
        public init(state: SearchStore.LoadState, resultCount: Int) {
            switch state {
            case .idle, .loading:
                self = .loading
            case .failed(let reason):
                self = .failed(reason)
            case .loaded:
                self = resultCount == 0 ? .empty : .results(resultCount)
            }
        }

        /// Loud when there is nothing else on the screen, quiet when there is.
        public var alertProminence: AlertFromSearchButton.Prominence {
            self == .empty ? .primary : .inline
        }

        /// The pinned bar belongs on screen only when there are results behind
        /// it. In the empty state the same button is already the primary
        /// action, and two of them is a screen arguing with itself.
        public var showsInlineAlertButton: Bool {
            if case .results = self { return true }
            return false
        }
    }

    /// The empty state's second line.
    ///
    /// CONTRACT.md §5: a club we reached that had nothing free is a different
    /// fact from a club we could not reach, and the golfer is owed the first
    /// one here. The stale banner above already carries the second.
    static func emptyMessage(freshness: FreshnessSummary) -> String {
        let base = "No tee times match these filters right now."
        guard let clubs = freshness.emptyClubsText else {
            return "\(base) Set an alert and we'll tell you the moment one opens."
        }
        return "\(base) \(clubs). Set an alert and we'll tell you the moment one opens."
    }

    /// One day-section's header, in `resultsList`: the short on-screen title
    /// ("Today"), replaced for VoiceOver by the full spoken day, and marked
    /// as a heading so the rotor's "Headings" navigation can jump straight
    /// between days.
    ///
    /// Pulled out to a name — rather than left inline as `resultsList`'s
    /// `header:` closure — only so `SearchScreenSectionHeaderAccessibilityTests`
    /// can assert on it directly, the way `emptyMessage(freshness:)` above
    /// was pulled out for the same reason. A live `List` rendered in a plain
    /// `XCTestCase` (no XCUITest, no assistive-technology client attached)
    /// never actually materialises UIKit's internal accessibility element
    /// graph — confirmed empirically, it reports empty for every node
    /// regardless of what traits are set — so this is the only piece small
    /// enough to inspect directly and prove the trait is really there.
    static func dayHeader(for section: SlotDaySection) -> some View {
        TeesDayHeading(model: .init(title: section.title))
            .padding(.horizontal, TeesSpacing.lg)
            // `TeesDayHeading` already marks itself `.isHeader` and combines
            // its flag, title and rule into one accessibility element inside
            // its own `body` — invisible to `SearchScreenSectionHeaderAccessibilityTests`'s
            // `Mirror` walk, which only sees this call site's own modifier
            // chain, not a nested view's internals. Restating both here is
            // redundant at runtime (SwiftUI unions repeated traits) but is
            // what keeps that test a real assertion rather than one that
            // happens to pass.
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(SlotFormatting.spokenDayTitle(for: section.date))
    }
}

// MARK: - Centred, but not clipped by the chrome above it

/// What `.loading`, `.failed` and `.empty` render into, instead of a bare
/// `.frame(maxHeight: .infinity)`.
///
/// That bare frame gives each state's content a height capped at whatever
/// room `NavigationStack` has below `topChrome` and above the tab bar — fine
/// at the default text size, where none of the three comes close to filling
/// it, and `.frame`'s default `.center` alignment is what puts it in the
/// middle of that space rather than pinned under the filter bar. At large
/// Dynamic Type sizes the empty state's message alone can run to four or five
/// lines: a plain `.frame(maxHeight: .infinity)` still reports its own size as
/// however tall the content actually needs (`TeesEmptyState`'s headline and
/// message both carry `.fixedSize(horizontal: false, vertical: true)`, so
/// neither shrinks to fit), and centring content taller than the space on
/// offer makes it overflow the same amount top and bottom — which, up here
/// where the top edge is `topChrome`'s filter chips and title, reads as the
/// empty state's own text overlapping them.
///
/// A `ScrollView` would be the ordinary fix, but a `ScrollView` anywhere
/// inside `NavigationStack`'s content is what the navigation bar watches to
/// decide when to collapse the large title — introducing one here collapsed
/// "Tee times" to a blank bar on first appearance, for a screen that was
/// never meant to scroll in the first place. So this measures the content's
/// own height instead (the `GeometryReader` + `PreferenceKey` pair below,
/// a standard SwiftUI technique for exactly this), and only adds top padding
/// when there is genuinely room to spare. Content that fits centres, the same
/// as before; content that does not simply starts at the top — under the
/// chrome, never behind it — and is clipped at the bottom rather than
/// overlapping anything above it.
private struct CenteredWhenItFits<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let topInset = contentHeight.map { max(0, (proxy.size.height - $0) / 2) } ?? 0
            content()
                .frame(width: proxy.size.width)
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(key: MeasuredHeightKey.self, value: inner.size.height)
                    }
                )
                .padding(.top, topInset)
        }
        .onPreferenceChange(MeasuredHeightKey.self) { contentHeight = $0 }
    }
}

private struct MeasuredHeightKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

#if DEBUG
#Preview("Search \u{2014} golden") {
    SearchScreen(
        store: SearchStore.previewStore(fixture: "golden"),
        ledger: BookingLedger(),
        isSignedIn: true,
        onCreateWatch: { _ in true },
        onRequireSignIn: {})
}
#endif
