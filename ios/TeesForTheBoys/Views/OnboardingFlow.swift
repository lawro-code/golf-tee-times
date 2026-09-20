import SwiftUI

/// Whether this device has already been through onboarding.
///
/// Its own type rather than a `Bool` on the view so the "runs once" rule can be
/// asserted on without rendering anything — the same reason every other
/// decision in track C sits in a pure type.
///
/// Keys are namespaced exactly like `ViewsPreferences.Key`. They are declared
/// here rather than there because `ViewsPreferences` belongs to ticket C1 and
/// Stage 1 tickets do not edit each other's files; Stage 2 can fold them
/// together if it wants one list.
public enum OnboardingState {

    public static let completedKey = "tees.views.onboarding.completed.v1"

    /// Anything other than the exact stored marker counts as not complete. A
    /// value written by another build showing onboarding a second time is a mild
    /// annoyance; skipping it for someone who has never seen it is worse.
    public static func isComplete(in store: ViewsKeyValueStore) -> Bool {
        store.string(forKey: completedKey) == "1"
    }

    public static func markComplete(in store: ViewsKeyValueStore) {
        store.set("1", forKey: completedKey)
    }

    /// Sign-out, or a golfer asking to see it again.
    public static func reset(in store: ViewsKeyValueStore) {
        store.set(nil, forKey: completedKey)
    }
}

/// Every string in the flow's first step.
public enum OnboardingCopy {
    public static let watchTitle = "Tees watches for cancellations"

    public static let watchBody = """
        Fifteen public courses around Sydney, checked around the clock. Search \
        what's free right now, or save what you're after — a Saturday morning \
        near Bondi, say — and Tees keeps looking after you've closed it.
        """

    public static let watchDetail = "Booking still happens on the club's own site. Tees finds the tee time and hands you straight to it."

    public static let continueTitle = "Next"
    public static let skipTitle = "Skip"
}

/// The short sequence after first sign-in: what the app does, then permission
/// to tell you about it.
///
/// Two steps, and the second is the only one that asks for anything. It runs
/// once per device — completion is written through ``ViewsKeyValueStore``, the
/// track's only persistence seam — and **every step is skippable**, including
/// the last: a golfer who skips straight out still finishes onboarding and is
/// never shown it again. Nothing in the app is gated on having said yes to
/// notifications.
///
/// Completion is recorded on the way out whatever the route — finish, skip from
/// step one, or deny at the system prompt — so "runs once" cannot be defeated by
/// choosing the unusual exit.
public struct OnboardingFlow: View {

    /// The two steps, in order. Public so Stage 2 can deep-link into one
    /// without this view growing an integer.
    public enum Step: Int, CaseIterable, Sendable {
        case whatWeWatch
        case notifications
    }

    private let store: ViewsKeyValueStore
    private let requester: NotificationPermissionRequesting
    private let onFinished: (Bool) -> Void

    @State private var step: Step = .whatWeWatch

    /// - Parameters:
    ///   - store: the persistence seam, so a test never writes to the
    ///     simulator's defaults.
    ///   - requester: the notification permission seam.
    ///   - onFinished: called exactly once, with whether notifications ended up
    ///     granted. `false` covers a skip, a no, and a denial at the system
    ///     prompt — the caller does not need to tell those apart, because none
    ///     of them changes what happens next.
    public init(
        store: ViewsKeyValueStore = UserDefaultsViewsStore(),
        requester: NotificationPermissionRequesting = SystemNotificationPermission(),
        onFinished: @escaping (Bool) -> Void
    ) {
        self.store = store
        self.requester = requester
        self.onFinished = onFinished
    }

    public var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .whatWeWatch:
                whatWeWatch
            case .notifications:
                NotificationPrimingScreen(requester: requester) { granted in
                    finish(granted: granted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Not `.overlay(alignment: .topTrailing)`: an overlay reserves no
        // space, so at larger accessibility text sizes the wrapped title in
        // `whatWeWatch` renders straight underneath the pinned button. A
        // `safeAreaInset` is what `SearchScreen` already uses in this
        // codebase to dock chrome over scrollable content without it — it
        // pushes the content down by exactly the button's own height instead.
        .safeAreaInset(edge: .top, alignment: .trailing, spacing: 0) { skipButton }
    }

    private var whatWeWatch: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(OnboardingCopy.watchTitle)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(OnboardingCopy.watchBody)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text(OnboardingCopy.watchDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    step = .notifications
                } label: {
                    Text(OnboardingCopy.continueTitle)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    /// Present on every step, including the last. An onboarding sequence with no
    /// way out is a sequence people quit the app to escape.
    private var skipButton: some View {
        Button(OnboardingCopy.skipTitle) { finish(granted: false) }
            .font(.subheadline)
            .padding(16)
            .accessibilityHint("Skips the rest of the introduction")
    }

    private func finish(granted: Bool) {
        OnboardingState.markComplete(in: store)
        onFinished(granted)
    }
}

#if DEBUG
#Preview("Onboarding") {
    OnboardingFlow(
        store: InMemoryViewsStore(),
        requester: StubNotificationPermission(answer: false)
    ) { _ in }
}
#endif
