import Foundation
import TeesContract
import os

/// Logging for the data layer.
///
/// Four categories so a Console filter can isolate one concern:
/// `auth`, `remote`, `cache`, `userdata`.
///
/// ## What never goes in a log line
///
/// An email address, a JWT or refresh token, an APNs device token, a keychain
/// value, or anything else that identifies a person. A user id (a UUID) is
/// fine — it is meaningless without the database. Everything logged here is
/// marked `.public` on purpose, which is exactly why what goes in matters:
/// public tee-time data, error shapes and counts, nothing else.
public enum DataLog {
    public static let subsystem = "code.lawro.TeesForTheBoys"

    /// Sign-in, sign-out, session restore. Never the credentials themselves.
    public static let auth = Logger(subsystem: subsystem, category: "auth")
    /// Fetching and decoding from Supabase.
    public static let remote = Logger(subsystem: subsystem, category: "remote")
    /// The on-disk payload cache and the keychain.
    public static let cache = Logger(subsystem: subsystem, category: "cache")
    /// Watches, bookings, push tokens — anything owned by a signed-in user.
    public static let userdata = Logger(subsystem: subsystem, category: "userdata")

    public enum Category: String, Sendable, CaseIterable {
        case auth, remote, cache, userdata
    }

    public static func logger(for category: Category) -> Logger {
        switch category {
        case .auth: return auth
        case .remote: return remote
        case .cache: return cache
        case .userdata: return userdata
        }
    }

    /// A malformed row was dropped rather than crashing the decode.
    ///
    /// CONTRACT.md requires this: one club changing its HTML must not blank out
    /// the other fourteen, and a dropped row must state why. This is the only
    /// place that reason is allowed to disappear to.
    public static func dropped(collection: String, index: Int, reason: String) {
        remote.error(
            "dropped \(collection, privacy: .public)[\(index, privacy: .public)]: \(reason, privacy: .public)"
        )
    }

    /// Every row the lenient decoder gave up on, logged one line each.
    ///
    /// `ContractPayload.issues` is empty on a clean decode, so the common case
    /// costs nothing.
    public static func dropped(_ issues: [DecodingIssue]) {
        for issue in issues {
            dropped(collection: issue.collection, index: issue.index, reason: issue.reason)
        }
    }

    /// An operation failed. Uses `diagnostic`, not `description` — the log wants
    /// the detail the UI is spared.
    public static func failed(_ operation: String, _ error: DataError, in category: Category) {
        logger(for: category).error(
            "\(operation, privacy: .public) failed: \(error.diagnostic, privacy: .public)"
        )
    }
}
