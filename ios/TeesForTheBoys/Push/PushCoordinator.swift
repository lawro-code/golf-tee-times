import Foundation

/// Turns a tapped notification into a route, and holds onto it until something
/// is listening.
///
/// ## Cold launch is the case that breaks this
///
/// The app is not running. The golfer taps the notification. iOS launches the
/// app and hands the payload over during launch — before the first screen
/// exists, let alone before it has subscribed to anything. An `AsyncStream`
/// with nobody attached drops what it is given, and a dropped cold-launch route
/// means the tap goes nowhere: the golfer lands on the search screen wondering
/// what happened to the tee time they were told about. That is the single most
/// visible failure this feature can hit.
///
/// So a route delivered while nobody is subscribed is **buffered**, and the
/// next subscriber gets it the moment it attaches. Only unconsumed routes are
/// held: once a stream has been handed a route the buffer is empty again, so a
/// screen that subscribes later never gets a tap from twenty minutes ago
/// replayed at it. ``latest`` stays readable for a screen that would rather ask
/// than listen.
///
/// ## Why an `AsyncStream` and not a Combine publisher
///
/// The same reason as `TeeTimeStore`: this module has no UI dependencies and is
/// not acquiring any. `ios/project.yml` gives it `TeesContract` and nothing
/// else.
///
/// ## Where the app hooks in
///
/// ```swift
/// func userNotificationCenter(
///     _: UNUserNotificationCenter,
///     didReceive response: UNNotificationResponse
/// ) async {
///     coordinator.handleTap(userInfo: response.notification.request.content.userInfo)
/// }
/// ```
///
/// and a screen does `for await route in coordinator.routes() { … }`.
@MainActor
public final class PushCoordinator {

    /// The most recent route, tap or not. Survives being consumed from the
    /// stream, so a screen appearing later can ask rather than listen.
    public private(set) var latest: PushRoute?

    /// Routes that arrived while nobody was listening. Drains into the next
    /// subscriber. Capped: a phone that never opens a screen is not a reason to
    /// grow a list forever, and the newest tap is the one that matters.
    private var pending: [PushRoute] = []
    private static let pendingLimit = 4

    private var observers: [UUID: AsyncStream<PushRoute>.Continuation] = [:]

    public init() {}

    /// Routes, as they are tapped.
    ///
    /// The first subscriber also receives anything buffered during launch.
    ///
    /// `.bufferingNewest(4)` because a consumer that has fallen behind wants
    /// where to go now, not a queue of everywhere it was told to go while it
    /// was busy — but four rather than one, because the cold-launch drain can
    /// legitimately deliver more than a single route in one go.
    public func routes() -> AsyncStream<PushRoute> {
        let (stream, continuation) = AsyncStream<PushRoute>.makeStream(
            of: PushRoute.self, bufferingPolicy: .bufferingNewest(4))

        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }

        for route in pending { continuation.yield(route) }
        pending.removeAll()
        return stream
    }

    /// A notification was tapped. Decodes it and publishes where to go.
    ///
    /// - Returns: the route, or nil when the payload named nowhere to go. A nil
    ///   is not an error the golfer should ever see — the app simply stays
    ///   where it is, and the reason is in the log.
    @discardableResult
    public func handleTap(userInfo: [AnyHashable: Any]) -> PushRoute? {
        guard let payload = AlertPayload.decode(userInfo: userInfo) else { return nil }
        guard let route = payload.route else {
            PushLog.rejected("payload named neither a slot nor a watch")
            return nil
        }
        deliver(route)
        return route
    }

    /// Publish a route directly. The seam a test drives, and what Stage 2 uses
    /// for a deep link that did not arrive as a push.
    public func deliver(_ route: PushRoute) {
        latest = route

        guard !observers.isEmpty else {
            // Cold launch, or every screen has gone. Hold it.
            pending.append(route)
            if pending.count > Self.pendingLimit { pending.removeFirst() }
            PushLog.routing.info("buffered a route until a screen is listening")
            return
        }
        for continuation in observers.values { continuation.yield(route) }
    }

    /// Forget the last route once a screen has acted on it, so a later
    /// appearance does not navigate a second time.
    public func clearLatest() {
        latest = nil
    }

    /// Stop every stream. Nothing in the app needs this; a test that would
    /// otherwise wait forever does.
    public func finish() {
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
    }
}
