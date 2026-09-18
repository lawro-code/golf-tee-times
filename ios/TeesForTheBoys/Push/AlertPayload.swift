import Foundation
import TeesContract

/// Why a push payload could not be read, or what was wrong with part of it.
///
/// Kept rather than discarded because the alternative is a tap that goes
/// nowhere and no way to find out afterwards why.
public enum AlertPayloadIssue: Error, Equatable, Sendable, CustomStringConvertible {
    /// `userInfo` had no `tees` object at all. Somebody else's notification, or
    /// a sender that has not been updated.
    case noTeesObject
    /// `tees` was there but was not an object.
    case teesNotAnObject
    /// No `v`. The payload is versioned on purpose; an unversioned one is not
    /// guessed at.
    case missingVersion
    /// A `v` this build has never heard of. Ignored rather than interpreted —
    /// a future sender is allowed to change the shape underneath it, and
    /// reading it with this build's assumptions is how a tap lands on the wrong
    /// tee time.
    case unsupportedVersion(Int)
    case missingField(String)
    case malformedField(name: String, value: String)

    public var description: String {
        switch self {
        case .noTeesObject: return "no tees object in userInfo"
        case .teesNotAnObject: return "tees is not an object"
        case .missingVersion: return "tees.v is missing"
        case .unsupportedVersion(let v): return "tees.v is \(v), this build reads 1"
        case .missingField(let name): return "tees.\(name) is missing"
        case .malformedField(let name, let value): return "tees.\(name) is malformed: \(value)"
        }
    }
}

/// The `tees` object the alert sender puts alongside `aps`.
///
/// The whole payload looks like this, and only the second half is ours:
///
/// ```json
/// {
///   "aps": {
///     "alert": { "title": "…", "body": "…" },
///     "sound": "default",
///     "thread-id": "watch:<watch_id>",
///     "interruption-level": "time-sensitive"
///   },
///   "tees": {
///     "v": 1,
///     "watch_id": "<uuid>",
///     "slot_ids": ["the-coast:2026-09-20:0758:public-play"],
///     "primary_slot_id": "the-coast:2026-09-20:0758:public-play",
///     "course_slug": "the-coast",
///     "course_name": "The Coast Golf Club",
///     "tee_at": "2026-09-20T07:58:00+10:00",
///     "count": 3
///   }
/// }
/// ```
///
/// `aps` is iOS's half — it decides what the banner says and which thread it
/// joins, and nothing in this app has to read it. `tees` is what the tap needs.
///
/// ## Lenient, in the same spirit as the contract decoder
///
/// A malformed push must never crash the app, and one bad field must not throw
/// away a payload that can still be routed. So there are two tiers:
///
/// - **Rejections** — no `tees`, no `v`, a `v` we do not know, or an
///   unreadable `tee_at` or `count`. These return `nil` with a reason, because
///   what is left cannot be trusted or cannot be routed.
/// - **Issues** — a missing course name, a `slot_ids` that is not an array of
///   strings. These land in ``issues`` and the payload still decodes, exactly
///   as `ContractPayload.issues` carries a dropped row without blanking the
///   other fourteen courses.
///
/// ## `tee_at` is parsed by `ContractDate`, never here
///
/// The contract's parser already reads `+10:00` from a fixture and `+00:00`
/// with fractional seconds from Supabase. A second date parser in this repo is
/// a bug waiting for the next changeover, and this repo has already paid for
/// that one.
public struct AlertPayload: Equatable, Sendable {

    /// The key the sender writes the object under.
    public static let userInfoKey = "tees"
    /// The only payload version this build reads.
    public static let supportedVersion = 1

    public let version: Int
    /// The watch that matched. Optional only because a payload can arrive
    /// without one; the sender always sends it.
    public let watchID: String?
    /// Every slot this push is about. May be empty.
    public let slotIDs: [String]
    /// The one slot to open when there is only one worth opening.
    public let primarySlotID: String?
    public let courseSlug: String
    public let courseName: String
    /// The absolute instant of the tee time, resolved server-side. Clients
    /// never recompute it.
    public let teeAt: Date
    /// How many matching slots this push covers. The routing rule turns on it.
    public let count: Int
    /// Fields that were wrong but not fatal. Empty on a clean decode.
    public let issues: [AlertPayloadIssue]

    public init(
        version: Int = AlertPayload.supportedVersion,
        watchID: String?,
        slotIDs: [String],
        primarySlotID: String?,
        courseSlug: String,
        courseName: String,
        teeAt: Date,
        count: Int,
        issues: [AlertPayloadIssue] = []
    ) {
        self.version = version
        self.watchID = watchID
        self.slotIDs = slotIDs
        self.primarySlotID = primarySlotID
        self.courseSlug = courseSlug
        self.courseName = courseName
        self.teeAt = teeAt
        self.count = count
        self.issues = issues
    }

    /// Where a tap on this notification should land. See ``PushRoute/route(watchID:primarySlotID:count:)``.
    public var route: PushRoute? {
        PushRoute.route(watchID: watchID, primarySlotID: primarySlotID, count: count)
    }

    // MARK: - Decoding

    /// Read the payload, or nil if it cannot be trusted. The reason is logged.
    public static func decode(userInfo: [AnyHashable: Any]) -> AlertPayload? {
        switch read(userInfo: userInfo) {
        case .success(let payload):
            for issue in payload.issues { PushLog.rejected(issue.description) }
            return payload
        case .failure(let issue):
            PushLog.rejected(issue.description)
            return nil
        }
    }

    /// The same read, with the reason returned instead of logged. This is the
    /// one a test asserts against.
    public static func read(
        userInfo: [AnyHashable: Any]
    ) -> Result<AlertPayload, AlertPayloadIssue> {
        guard let raw = userInfo[userInfoKey] else { return .failure(.noTeesObject) }
        guard let tees = object(raw) else { return .failure(.teesNotAnObject) }

        guard let version = integer(tees["v"]) else {
            return .failure(tees["v"] == nil ? .missingVersion : .malformedField(
                name: "v", value: describe(tees["v"])))
        }
        guard version == supportedVersion else {
            return .failure(.unsupportedVersion(version))
        }

        guard let rawTeeAt = string(tees["tee_at"]) else {
            return .failure(.missingField("tee_at"))
        }
        guard let teeAt = ContractDate.date(from: rawTeeAt) else {
            return .failure(.malformedField(name: "tee_at", value: rawTeeAt))
        }

        guard let count = integer(tees["count"]) else {
            return .failure(tees["count"] == nil ? .missingField("count") : .malformedField(
                name: "count", value: describe(tees["count"])))
        }

        var issues: [AlertPayloadIssue] = []

        let slotIDs = stringArray(tees["slot_ids"], name: "slot_ids", issues: &issues)
        let courseSlug = required(tees["course_slug"], name: "course_slug", issues: &issues)
        let courseName = required(tees["course_name"], name: "course_name", issues: &issues)

        return .success(AlertPayload(
            version: version,
            watchID: string(tees["watch_id"]),
            slotIDs: slotIDs,
            primarySlotID: string(tees["primary_slot_id"]),
            courseSlug: courseSlug,
            courseName: courseName,
            teeAt: teeAt,
            count: count,
            issues: issues))
    }

    // MARK: - Reading loosely typed JSON

    /// APNs hands the payload over as a Foundation dictionary, so everything in
    /// it is bridged: a JSON number is an `NSNumber`, a nested object may be an
    /// `NSDictionary` keyed on `AnyHashable`. These four helpers are the whole
    /// reason this is hand-rolled rather than `JSONDecoder` — re-serialising
    /// the dictionary just to decode it would be slower and would lose exactly
    /// the leniency the tiers above depend on.
    private static func object(_ value: Any?) -> [String: Any]? {
        if let typed = value as? [String: Any] { return typed }
        guard let loose = value as? [AnyHashable: Any] else { return nil }
        return loose.reduce(into: [String: Any]()) { result, pair in
            if let key = pair.key as? String { result[key] = pair.value }
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func describe(_ value: Any?) -> String {
        guard let present = value else { return "nil" }
        return String(describing: present)
    }

    private static func stringArray(
        _ value: Any?, name: String, issues: inout [AlertPayloadIssue]
    ) -> [String] {
        guard let present = value else {
            issues.append(.missingField(name))
            return []
        }
        guard let elements = present as? [Any] else {
            issues.append(.malformedField(name: name, value: describe(present)))
            return []
        }
        let strings = elements.compactMap { $0 as? String }
        if strings.count != elements.count {
            issues.append(.malformedField(name: name, value: describe(present)))
        }
        return strings
    }

    private static func required(
        _ value: Any?, name: String, issues: inout [AlertPayloadIssue]
    ) -> String {
        guard let text = string(value) else {
            issues.append(value == nil ? .missingField(name) : .malformedField(
                name: name, value: describe(value)))
            return ""
        }
        return text
    }
}
