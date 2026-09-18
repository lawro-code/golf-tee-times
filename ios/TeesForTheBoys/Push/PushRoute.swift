import Foundation

/// Where a tapped notification should land.
///
/// Two cases, because a push says one of two things: "this exact tee time is
/// free" or "several things you were watching for opened up".
public enum PushRoute: Equatable, Sendable {
    /// Open one tee time. The id is a contract slot id —
    /// `{course_slug}:{YYYY-MM-DD}:{HHMM}:{tee}`.
    case slot(id: String)
    /// Open the watch that matched, so the golfer can see all of them.
    case watch(id: String)

    /// Decide where a tap goes.
    ///
    /// The rule, and the reason for it:
    ///
    /// | `count` | Goes to | Why |
    /// |---|---|---|
    /// | 0 or 1 | the slot | There is one thing to look at. Dropping the golfer on a list of one is a wasted tap, and the thing they want — the book button — is a screen further away. |
    /// | 2 or more | the watch | They have several matches. Picking one of them for them is guessing, and the other matches disappear from view. |
    ///
    /// Either id can be missing from a payload, so this degrades rather than
    /// insisting:
    ///
    /// - a watch id and no primary slot id routes to the watch whatever the
    ///   count says — the sender has told us it cannot name a single slot;
    /// - a primary slot id and no watch id routes to the slot for the same
    ///   reason in reverse;
    /// - neither returns `nil`, and the caller leaves the app where it is. A
    ///   push that names nothing is a sender bug, not a navigation event.
    public static func route(
        watchID: String?, primarySlotID: String?, count: Int
    ) -> PushRoute? {
        let watchID = watchID.flatMap(nonEmpty)
        let primarySlotID = primarySlotID.flatMap(nonEmpty)

        if count > 1, let watchID {
            return .watch(id: watchID)
        }
        if let primarySlotID {
            return .slot(id: primarySlotID)
        }
        if let watchID {
            return .watch(id: watchID)
        }
        return nil
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
