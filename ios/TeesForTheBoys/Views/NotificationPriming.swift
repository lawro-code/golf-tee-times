import SwiftUI
import UserNotifications

/// Asking iOS for permission to send notifications.
///
/// A protocol rather than a direct `UNUserNotificationCenter` call because the
/// system prompt is one-shot per install: a test that reached the real centre
/// would either hang waiting for a tap that never comes, or burn the app's one
/// chance to ask on a simulator. Everything above this seam is testable; the
/// one implementation below it that touches the system is four lines and has no
/// branches worth asserting on.
public protocol NotificationPermissionRequesting: AnyObject {
    /// Shows the system prompt and returns what the user chose. Never throws:
    /// a failure to ask is indistinguishable, from the screen's point of view,
    /// from being told no.
    func requestAuthorization() async -> Bool
}

/// The shipping implementation.
public final class SystemNotificationPermission: NotificationPermissionRequesting {

    public init() {}

    public func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Asking failed — not the same as a refusal, but the golfer sees
            // the same thing either way and there is nothing useful to say
            // about it on an onboarding screen.
            return false
        }
    }
}

/// The test and preview twin. Counting the calls is how a test proves the
/// screen asks once and does not ask again after a no.
public final class StubNotificationPermission: NotificationPermissionRequesting {

    public private(set) var requestCount = 0
    private let answer: Bool

    public init(answer: Bool) {
        self.answer = answer
    }

    public func requestAuthorization() async -> Bool {
        requestCount += 1
        return answer
    }
}

/// Every string on the priming screen, in one place.
///
/// Public and pure for the same reason as `SlotFormatting`: with
/// `ios/project.yml` frozen there is no ViewInspector in this target, so copy
/// lifted out of the body is the only part of a screen a test can hold.
public enum NotificationPrimingCopy {
    public static let title = "Want to know the moment one opens?"

    /// Says what the notification *is*, in the golfer's terms. The system
    /// prompt that follows says "Tees would like to send you notifications",
    /// which tells nobody anything — this screen is the one that has to earn
    /// the yes, which is the entire point of priming before the real prompt
    /// rather than cold on launch.
    public static let body = """
        Sydney's public courses fill up weeks out, and the good tee times only \
        come free when somebody cancels. Save what you're after and we'll check \
        every twenty minutes. When a tee time matching one of your alerts opens \
        up, you get one notification with the details.
        """

    /// The reassurance that makes the yes an honest one rather than a
    /// cornered one.
    public static let reassurance = "Nothing else. No daily digest, no marketing."

    public static let allowTitle = "Turn on alerts"
    public static let skipTitle = "Not now"

    /// Shown under the skip button. A "not now" that comes with a threat is not
    /// a real choice, so this says plainly that everything still works.
    public static let skipFooter = "You can still search and browse tee times, and turn alerts on later in Settings."
}

/// Explains what a notification from this app is, then hands over to the system
/// prompt.
///
/// **Never shown cold.** The system prompt can only be answered once per
/// install, so it is worth spending a screen first. Shown after first sign-in,
/// as the last step of ``OnboardingFlow``.
///
/// A no here means the system prompt is never shown at all, which leaves it
/// available if the golfer changes their mind later — the opposite of the usual
/// pattern, where an early refusal burns the one chance to ask.
///
/// ## Layout
///
/// Nothing has a fixed height and the whole thing is in a `ScrollView`. At AX5
/// the body copy is fifteen or more lines tall on a small phone; a screen laid
/// out to fit it at the default size clips it, and clipped priming copy is
/// worse than none.
public struct NotificationPrimingScreen: View {

    private let requester: NotificationPermissionRequesting
    private let onDecision: (Bool) -> Void

    @State private var isAsking = false

    /// - Parameters:
    ///   - requester: the permission seam. A `StubNotificationPermission` in a
    ///     test or preview never reaches `UNUserNotificationCenter`.
    ///   - onDecision: called with what happened — `true` only if the golfer
    ///     said yes here *and* iOS then granted it. Called for a skip too, with
    ///     `false`: the flow moves on either way.
    public init(
        requester: NotificationPermissionRequesting = SystemNotificationPermission(),
        onDecision: @escaping (Bool) -> Void
    ) {
        self.requester = requester
        self.onDecision = onDecision
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(NotificationPrimingCopy.title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(NotificationPrimingCopy.body)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text(NotificationPrimingCopy.reassurance)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                buttons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            Button(action: ask) {
                Text(NotificationPrimingCopy.allowTitle)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isAsking)

            Button(NotificationPrimingCopy.skipTitle) { onDecision(false) }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(isAsking)

            Text(NotificationPrimingCopy.skipFooter)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// Disabled while in flight so a double tap cannot ask twice. The system
    /// prompt would coalesce them, but the second `onDecision` would move the
    /// flow on twice.
    private func ask() {
        guard !isAsking else { return }
        isAsking = true
        Task { @MainActor in
            let granted = await requester.requestAuthorization()
            isAsking = false
            onDecision(granted)
        }
    }
}

#if DEBUG
#Preview("Priming") {
    NotificationPrimingScreen(requester: StubNotificationPermission(answer: true)) { _ in }
}
#endif
