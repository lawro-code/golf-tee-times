import SwiftUI
import TeesContract

/// One tap turns the search you are already looking at into an alert.
///
/// This is the most important control in the app. The filters on screen already
/// describe the watch completely — `WatchDraft` is the proof — so there is no
/// wizard, no confirmation step before the fact, and no sheet on the way in.
/// Tap it and the watch exists.
///
/// ## The two paths, and nothing else
///
/// | Who taps | What happens |
/// |---|---|
/// | Signed in | `onCreate(draft)`, then an inline confirmation with one Adjust affordance |
/// | Signed out | `onRequireSignIn()` — the wall, and only ever here |
///
/// The wall is in front of alerts, never in front of search. Browsing the 15
/// clubs works signed out; that is the point of the app being worth opening.
///
/// ## Adjusting is a detour, not the path
///
/// `AlertAdjustSheet` is reachable only from the confirmation, after the watch
/// has been saved. Someone who wants to change the 8am to a 9am can; nobody is
/// made to. The edited draft keeps the same `id`, so Stage 2 upserts it rather
/// than leaving a second watch behind.
///
/// ## The confirmation lasts as long as the search does
///
/// It states what is on screen, so it is cleared the moment the filters change
/// and the button comes back — see `survivingConfirmation(_:filtersNow:)`. A
/// golfer who creates a Saturday-morning alert and then searches Sunday
/// twilight can create that one too.
///
/// ## Never disabled
///
/// A standard, untouched filter set is a legitimate watch — "tell me when
/// anything opens anywhere" is a real thing to want, and it is the one a first
/// time user is most likely to create. `WatchDraft` has a sentence for it, so
/// there is nothing to disable.
public struct AlertFromSearchButton: View {

    /// How loud the button is. Both do exactly the same thing on tap.
    public enum Prominence: Equatable, Sendable {
        /// A compact bar, for sitting above or below a list of results.
        case inline
        /// A full-width call to action carrying `draft.emptySentence`. This is
        /// the empty state's primary action: no results is the moment an alert
        /// is worth the most.
        case primary
    }

    /// What a tap decided. Returned by `tap()` so the decision can be asserted
    /// without rendering anything — `ios/project.yml` is frozen and there is no
    /// ViewInspector in the project.
    public enum TapOutcome: Equatable, Sendable {
        case created
        case signInRequired
        /// Signed in, and `onCreate` ran — but it reported the save never
        /// landed (offline, a dropped connection, the backend down). Never
        /// treat this as `.created`: that is the flag the button uses to show
        /// "Alert saved", and a save that failed must not be confirmed.
        case failed
    }

    private let draft: WatchDraft
    private let prominence: Prominence
    private let isSignedIn: Bool
    /// Creates the watch and reports whether it actually landed. Awaited by
    /// `tap()` before it will call anything `.created` — see `TapOutcome`.
    private let onCreate: (WatchDraft) async -> Bool
    private let onRequireSignIn: () -> Void

    /// Non-nil once the watch has been created; holds the newest version of it
    /// so Adjust edits what was actually saved.
    @State private var saved: WatchDraft?
    @State private var isAdjusting = false

    public init(
        draft: WatchDraft,
        prominence: Prominence,
        isSignedIn: Bool,
        onCreate: @escaping (WatchDraft) async -> Bool,
        onRequireSignIn: @escaping () -> Void
    ) {
        self.draft = draft
        self.prominence = prominence
        self.isSignedIn = isSignedIn
        self.onCreate = onCreate
        self.onRequireSignIn = onRequireSignIn
    }

    // MARK: - The tap

    /// The whole decision a tap makes, as a function.
    ///
    /// The button's action calls this and then updates its own state; a test
    /// calls it directly. Both go through the same two lines, so the test is
    /// testing the shipping behaviour rather than a copy of it.
    ///
    /// Waits on `onCreate` rather than firing it and reporting `.created`
    /// regardless: `onCreate` reaches a network call, and calling it is not
    /// the same thing as it having worked.
    @discardableResult
    public func tap() async -> TapOutcome {
        guard isSignedIn else {
            onRequireSignIn()
            return .signInRequired
        }
        return await onCreate(draft) ? .created : .failed
    }

    // MARK: - The filters moving underneath

    /// Which confirmation, if any, survives a change to the filters below it.
    ///
    /// Hoisted for the same reason `tap()` is: this is the decision, and a test
    /// can call it without rendering anything.
    ///
    /// A confirmation is a claim about what is on screen. This view sits in
    /// `SearchScreen`'s bottom safe area with a stable identity, so when the
    /// golfer moves from Saturday mornings to Sunday twilight the bar comes
    /// with them — and a confirmation left in place would be naming a watch
    /// that no longer matches the list above it, while standing exactly where
    /// the button to create the Sunday alert belongs. Both reasons say the same
    /// thing: put the button back.
    ///
    /// The one case that keeps it: filters that have moved back into agreement
    /// with the saved watch — adjusting the alert to Sunday twilight and then
    /// searching Sunday twilight — still describe it, so it is still true.
    public static func survivingConfirmation(
        _ saved: WatchDraft?, filtersNow filters: SearchFilters
    ) -> WatchDraft? {
        guard let saved, saved.filters == filters else { return nil }
        return saved
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if let saved {
                confirmation(saved)
            } else {
                button
            }
        }
        // Keyed on the filters, not on `draft.id`: `SearchScreen.draft` is a
        // computed property that mints a fresh `UUID()` on every body pass, so
        // `.id(draft.id)` would tear the view down every render.
        .onChange(of: draft.filters) { _, filters in
            saved = Self.survivingConfirmation(saved, filtersNow: filters)
        }
        .sheet(isPresented: $isAdjusting) {
            AlertAdjustSheet(
                draft: saved ?? draft,
                onSave: { edited in
                    // Same rule as `tap()`: only claim it is saved once
                    // `onCreate` says the save actually landed.
                    Task {
                        if await onCreate(edited) {
                            saved = edited
                        }
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var button: some View {
        Button {
            Task {
                if await tap() == .created {
                    withAnimation { saved = draft }
                }
            }
        } label: {
            switch prominence {
            case .inline: inlineLabel
            case .primary: primaryLabel
            }
        }
        .buttonStyle(.plain)
        // Rule 8: the label a screen reader hears is the watch itself. "Create
        // alert button" tells a golfer nothing about which alert they are
        // about to create.
        .accessibilityLabel(Text(draft.sentence))
        .accessibilityHint(Text(isSignedIn ? "Saves this search as an alert" : "Asks you to sign in first"))
    }

    private var inlineLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.badge")
                .imageScale(.medium)
                .accessibilityHidden(true)
            Text(draft.sentence)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                // This bar is pinned over the results list
                // (`SearchScreen.inlineAlertBar`, via `.safeAreaInset(edge:
                // .bottom)`) and its height comes straight out of the list's
                // own viewport. Uncapped, a watch sentence at the largest
                // accessibility text sizes wraps to three or four lines and
                // the bar swells to roughly a third of the screen, leaving no
                // room above it for even one tee-time row. Two lines bounds
                // that growth; the full sentence is never lost, since it is
                // still the accessibility label on the whole button, below.
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        )
        .contentShape(Rectangle())
    }

    private var primaryLabel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.emptySentence)
                .font(.headline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .accessibilityHidden(true)
                Text("Create this alert")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        )
        .contentShape(Rectangle())
    }

    // MARK: - After the tap

    /// One line saying it worked, and one affordance to change it.
    ///
    /// Deliberately not a sheet, a toast or a navigation push: the golfer is
    /// mid-search and the alert is now a fact, not a task.
    private func confirmation(_ watch: WatchDraft) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Alert saved")
                    .font(.subheadline.weight(.semibold))
                Text(watch.sentence)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Adjust") { isAdjusting = true }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityHint(Text("Change this alert before it starts watching"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.10))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Alert saved. \(watch.sentence)"))
    }
}

#Preview("Inline, signed in") {
    AlertFromSearchButton(
        draft: WatchDraft(filters: .standard, courses: [], today: "2026-09-18"),
        prominence: .inline,
        isSignedIn: true,
        onCreate: { _ in true },
        onRequireSignIn: {}
    )
    .padding()
}

#Preview("Primary, signed out") {
    AlertFromSearchButton(
        draft: WatchDraft(
            filters: SearchFilters(days: ["2026-09-19"], timesOfDay: [.morning]),
            courses: [],
            today: "2026-09-18"
        ),
        prominence: .primary,
        isSignedIn: false,
        onCreate: { _ in true },
        onRequireSignIn: {}
    )
    .padding()
}
