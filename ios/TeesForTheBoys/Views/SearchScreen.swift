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
            ViewsLoadingState(message: "Finding tee times across the fifteen clubs\u{2026}")
                .frame(maxHeight: .infinity)

        case .failed(let reason):
            ViewsErrorState(
                title: "Couldn't load tee times",
                message: reason,
                retry: onRetry)
                .frame(maxHeight: .infinity)

        case .empty:
            emptyState
                .frame(maxHeight: .infinity)

        case .results:
            resultsList(sections)
        }
    }

    /// No results is not a dead end. The alert is the thing to do about it, so
    /// it is the state's primary action rather than a link tucked underneath.
    ///
    /// Not a `ScrollView`: this content is exactly as tall as `.loading`'s and
    /// `.failed`'s, which sit directly in the `.frame(maxHeight: .infinity)`
    /// `content(presentation:sections:)` gives every one of the four states —
    /// SwiftUI centres that by default. A `ScrollView` here used to accept the
    /// same frame on itself, but a `ScrollView` always lays its content out at
    /// the top of its scroll axis regardless of the frame it is given, so
    /// this was the one state, of the four, pinned under the filter bar
    /// instead of centred (`SearchScreenEmptyStateLayoutTests`).
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
                    ForEach(section.results) { result in
                        NavigationLink(value: result) {
                            SlotRow(result: result)
                        }
                    }
                } header: {
                    Self.dayHeader(for: section)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { onRetry() }
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
            .padding(.horizontal, SearchStyle.gutter)
            .padding(.vertical, SearchStyle.chipSpacing)
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
        Text(section.title)
            .searchSectionHeaderText()
            // The relative heading is a shorthand; VoiceOver gets the day it
            // actually means.
            .accessibilityLabel(SlotFormatting.spokenDayTitle(for: section.date))
            // The plain `Section("Title")` string initialiser gets this trait
            // for free; this custom header (needed for the font and the
            // label split above) opts out of that, so it has to be added
            // back by hand — otherwise VoiceOver's rotor "Headings"
            // navigation has no day sections to jump between.
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Style seam

/// Every measurement and colour the C2 screens use, in one place.
///
/// Track D is writing the real token layer concurrently and today `TeesDesign`
/// contains only `TeesDesignModule.version`, so referencing anything else from
/// it would not compile. Everything below is therefore a SwiftUI semantic role
/// or a system text style — both already adapt to light and dark and to
/// Dynamic Type — held behind names so Stage 2 swaps D's tokens in by editing
/// this one section rather than by touching five screens.
///
/// Nothing here is a fixed height, and nothing ever should be: at AX5 a club
/// name is three lines and a box sized for one clips it.
enum SearchStyle {
    static let gutter: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 6
    static let chipSpacing: CGFloat = 8
    static let chipPadding: CGFloat = 14

    static let calloutShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    static let calloutBackground = Color.orange.opacity(0.14)

    /// The registration warning's text colour on the results row.
    /// `.primary` rather than orange: plain `Color.orange` text on this row's
    /// background (no tint behind it) came out at ~1.8–2.2:1 in light mode,
    /// far under WCAG's 4.5:1 floor for footnote-sized text. `.primary`
    /// already adapts to any background the app draws, which is why the same
    /// warning one screen later — `SlotDetailScreen.registrationCallout`, via
    /// `searchCalloutText()` — was already using it instead of a coloured
    /// label.
    static let warningTextColor = Color.primary

    static func chipBackground(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10)
    }

    static func chipBorder(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor : Color.secondary.opacity(0.28)
    }
}

extension View {
    func searchTitleText() -> some View {
        font(.headline).foregroundStyle(.primary)
    }

    func searchBodyText() -> some View {
        font(.body).foregroundStyle(.primary)
    }

    func searchSecondaryText() -> some View {
        font(.subheadline).foregroundStyle(.secondary)
    }

    func searchCaptionText() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }

    func searchSectionHeaderText() -> some View {
        font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
    }

    func searchChipText() -> some View {
        font(.subheadline.weight(.medium)).foregroundStyle(.primary)
    }

    func searchCalloutText() -> some View {
        font(.subheadline).foregroundStyle(.primary)
    }

    func searchWarningText() -> some View {
        font(.footnote).foregroundStyle(SearchStyle.warningTextColor)
    }

    /// An unknown price is stated quietly rather than dressed up as a number:
    /// "Price at course" is information, not a placeholder.
    func searchPriceText(isKnown: Bool) -> some View {
        font(isKnown ? .headline : .footnote)
            .foregroundStyle(isKnown ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
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
