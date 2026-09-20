import UIKit
import UserNotifications

/// The UIKit lifecycle bridge that never existed.
///
/// `TeesPush`'s own doc comments already said who was supposed to build this:
/// `PushRegistrar` is "Built by: the app delegate" (`PushRegistrar.swift`'s
/// header table), and both of its registration callbacks and
/// `UNUserNotificationCenterDelegate`'s tap callback need an app delegate to
/// arrive on. There was none anywhere in `ios/TeesForTheBoys` — no
/// `UIApplicationDelegateAdaptor`, no `AppDelegate`, no
/// `UNUserNotificationCenterDelegate` conformance — so a device token never
/// reached `PushRegistrar` and a tapped notification never reached
/// `PushCoordinator`. This file is only the wiring; `AppSession` does every
/// bit of actual work, exactly as `PushRegistrar`'s and `PushCoordinator`'s
/// own doc comments describe.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set from `TeesForTheBoysApp`'s `.task`, as soon as `AppSession` exists.
    /// Weak: the `@StateObject` owns the app's lifetime, not the other way
    /// round, and a registration or a tap arriving before it is set is simply
    /// dropped — there is no session yet to hand it to.
    weak var session: AppSession?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        session?.handlePushRegistration(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        session?.handlePushRegistrationFailure(error)
    }

    /// A push arriving while Tees is frontmost. Without this, iOS shows
    /// nothing at all in the foreground — the foreground case the defect
    /// named alongside cold and backgrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// The tap. iOS calls this one method whether the app was cold,
    /// backgrounded, or foregrounded — see `PushCoordinator`'s own doc
    /// comment on why cold launch is the case that actually breaks a naive
    /// implementation of the other end of this.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        session?.handlePushTap(userInfo: response.notification.request.content.userInfo)
    }
}
