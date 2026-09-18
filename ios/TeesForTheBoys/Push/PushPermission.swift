import Foundation
import UserNotifications

/// What iOS currently thinks about notifications from this app.
///
/// A flat mirror of `UNAuthorizationStatus` so nothing above this module has to
/// import `UserNotifications` to ask a yes/no question.
public enum PushAuthorizationStatus: String, Sendable, Equatable, CaseIterable {
    /// The system prompt has never been shown. The one chance is still unspent.
    case notDetermined
    case denied
    case authorized
    /// Granted quietly, with no prompt — delivered to the notification centre
    /// only. This app does not ask for it, but a user can end up here.
    case provisional
    /// An App Clip's temporary grant.
    case ephemeral
    /// A status a later iOS added that this build has never heard of. Treated
    /// as "not authorised" everywhere it matters.
    case unknown

    /// Whether a push will actually be delivered to the user.
    public var allowsAlerts: Bool {
        self == .authorized || self == .ephemeral
    }
}

/// `UNUserNotificationCenter`, in two functions, presenting nothing.
///
/// ## The system prompt is one-shot per install
///
/// iOS shows the "… would like to send you notifications" alert exactly once.
/// Answer it with a no and it never appears again — Settings is the only way
/// back, and almost nobody goes. So **when** `request()` is called matters more
/// than anything in this file.
///
/// The build plan settles it: permission is asked in context after first
/// sign-in, with an explanation *before* the system prompt, never cold on
/// launch. That explainer is `NotificationPrimingScreen` in Track C — it earns
/// the yes, and only then does it call in here. A golfer who says "not now" to
/// the explainer has not spent the one chance, which is the entire point of
/// priming.
///
/// **Calling `request()` at the wrong moment burns the only chance this app
/// gets.** Nothing here shows UI of its own, precisely so that the decision
/// about when to ask stays with the screen that can explain why.
///
/// ## Why this is not a protocol
///
/// It has no branches worth asserting on and no way to be exercised in a test:
/// a test bundle that reached the real notification centre would either hang
/// waiting for a tap that never comes, or spend the install's one prompt. Track
/// C already owns a protocol seam for the screen's side of this
/// (`NotificationPermissionRequesting`); this is the thin thing behind it.
public enum PushPermission {

    /// What iOS says right now. Never prompts.
    ///
    /// Safe to call on every launch and from anywhere, including before
    /// sign-in — it is the read that tells a screen whether to offer the
    /// explainer at all.
    public static func status() async -> PushAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return map(settings.authorizationStatus)
    }

    /// Shows the system prompt, once per install, and reports what came back.
    ///
    /// Asks for alerts and sound. **Not** badges: nothing in this version
    /// manages a badge count, and asking for a permission the app does not use
    /// is a small lie told at the worst possible moment.
    ///
    /// - Returns: the status *after* the user answered, read back from iOS
    ///   rather than inferred from the granted flag — a "yes" on a device under
    ///   a restriction profile still comes back denied.
    /// - Throws: whatever `UNUserNotificationCenter` throws. Asking and failing
    ///   is not the same as being told no, even though the golfer sees the same
    ///   thing, and the caller deserves the chance to tell them apart.
    @discardableResult
    public static func request() async throws -> PushAuthorizationStatus {
        let granted = try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        let status = await status()
        PushLog.registration.info(
            "notification permission answered: granted=\(granted, privacy: .public) status=\(status.rawValue, privacy: .public)")
        return status
    }

    static func map(_ status: UNAuthorizationStatus) -> PushAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unknown
        }
    }
}
