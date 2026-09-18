import Foundation
import os

/// Track E — alerts, client half.
///
/// This module is everything the phone does about a push: asking for
/// permission, registering with APNs, handing the device token to whoever can
/// store it, and turning a tapped notification into a route. It draws nothing
/// and it talks to no server.
///
/// ## What lives here, and who wires it
///
/// | Type | What it is for | Built by |
/// |---|---|---|
/// | `PushEnvironment` | Which APNs gateway minted a token. Raw values match the `push_tokens.environment` check constraint. | everywhere |
/// | `PushTokenSink` | The seam to the data layer. `register` / `retire` a token; no Supabase in this module. | Stage 2 assembly |
/// | `PushPermission` | `UNUserNotificationCenter` in two functions. Presents no UI of its own. | the priming screen (Track C) |
/// | `PushRegistrar` | `registerForRemoteNotifications`, `Data` → hex, forward to the sink. | the app delegate |
/// | `AlertPayload` | Decodes the `tees` object the alert sender puts in `userInfo`. | `PushCoordinator` |
/// | `PushRoute` | Where a tap should land: one slot, or the watch that matched. | `PushCoordinator` |
/// | `PushCoordinator` | Buffers the tap and publishes the route for a screen to act on. | Stage 2 assembly |
///
/// ## The module boundary
///
/// `ios/project.yml` gives this target exactly one dependency, `TeesContract`.
/// There is deliberately no Supabase here and no SwiftUI: the token goes out
/// through `PushTokenSink` and the route goes out through
/// `PushCoordinator.routes()`, and the app target is the only place that knows
/// about both halves. Anything another track needs from this one is `public`,
/// and the compiler is what enforces that.
///
/// ## Two things this module will not do
///
/// - **It never crashes on a bad push.** The simulator issues no APNs token at
///   all, and a real payload can arrive malformed from a sender we have not
///   shipped yet. Both are logged outcomes, never a `fatalError`.
/// - **It never parses a date itself.** `ContractDate` in `TeesContract`
///   already handles `+10:00` from a fixture and `+00:00` with fractional
///   seconds from Supabase. A second date parser in this repo is a bug waiting
///   for the October changeover.
public enum TeesPushModule {
    public static let version = "1.0.0"
}

/// Logging for the push layer.
///
/// ## What never goes in a log line
///
/// **An APNs device token.** Not truncated, not hashed, not "just in debug" —
/// it identifies a device, and `PushTokenRepository` in Track B holds the same
/// rule for the same reason. A watch id or a slot id is fine: both are
/// meaningless without the database. Everything here is marked `.public` on
/// purpose, which is exactly why what goes in matters.
public enum PushLog {
    public static let subsystem = "code.lawro.TeesForTheBoys"

    /// Permission, registration, token hand-off.
    public static let registration = Logger(subsystem: subsystem, category: "push")
    /// Decoding a payload and routing a tap.
    public static let routing = Logger(subsystem: subsystem, category: "push-routing")

    /// A push arrived that we could not make sense of.
    ///
    /// The reason is kept because the alternative is a tap that goes nowhere
    /// and no way to find out why after the fact.
    public static func rejected(_ reason: String) {
        routing.error("rejected a push payload: \(reason, privacy: .public)")
    }
}
