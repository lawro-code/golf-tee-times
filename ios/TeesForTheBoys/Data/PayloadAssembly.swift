import Foundation
import TeesContract

/// Rows on their way from PostgREST into the frozen `ContractPayload`.
///
/// ## Why this file exists
///
/// Three reads come back from Supabase as three JSON arrays. The app needs one
/// `ContractPayload`, decoded the way Stage 0 decodes a fixture — the whole
/// point of the contract is that a fixture and a live read produce the same
/// shape through the same decoder.
///
/// So assembly does not decode rows itself. It stitches the three arrays into
/// a payload document and hands it to `ContractLoader.decode`, which is the
/// Stage 0 decoder: `decodeLenient` drops a malformed row into
/// `payload.issues` instead of failing, `decodeNumberIfPresent` accepts a
/// price as a JSON number or as `"55.00"`, and `ContractDate` parses both
/// `+00:00`-with-fractional-seconds from Supabase and `+10:00` from a fixture.
/// Writing a second decoder here would mean two sets of those rules, and the
/// live data has already shown what each of them is worth.
///
/// What survives what:
///
/// | Input | Result |
/// |---|---|
/// | One course row missing `slug` | That course dropped, 14 kept, one `DecodingIssue` |
/// | `price_min: null` | An ordinary slot. 282 of 1755 look like this |
/// | `price_min: "55.00"` | 55.0 |
/// | `booking_url` that is not a URL | Kept as a string; `slot.bookingURL` is nil |
/// | `contract_version` that is not ours | `DataError.contractVersionMismatch`, whole payload rejected |
///
/// Only the last of those throws. A bad row is never a `fatalError`, never a
/// thrown error, never a `try!` — it is a `DecodingIssue` and a `DataLog` line.
public struct RawRows {

    /// The payload key these rows belong to — `courses`, `slots` or
    /// `course_days`. Carried so a dropped row can name the collection it came
    /// from in both the issue and the log line.
    public let collection: String

    /// Untouched JSON values, straight out of `JSONSerialization`. Deliberately
    /// not decoded here: the Stage 0 decoder is the only thing that turns these
    /// into model types.
    private(set) var values: [Any]

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    /// An empty set of rows, ready to have pages appended to it.
    public init(collection: String) {
        self.collection = collection
        self.values = []
    }

    /// Parse one PostgREST response body: a JSON array of row objects.
    ///
    /// A body that is not a JSON array is a broken response, not a bad row, so
    /// this throws. Individual rows inside the array are never inspected here.
    public init(collection: String, json data: Data) throws {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let array = parsed as? [Any]
        else {
            throw DataError.decoding(
                reason: "\(collection): expected a JSON array of rows, got \(data.count) bytes that are not one")
        }
        self.collection = collection
        self.values = array
    }

    /// Append a page fetched with `.range(from:to:)`.
    public mutating func append(_ page: RawRows) {
        values.append(contentsOf: page.values)
    }

    /// The newest parsable timestamp under `key` across these rows, or nil when
    /// no row carries one. Used for `generated_at`, which has to say when the
    /// data was *scraped*.
    func newestTimestamp(key: String) -> Date? {
        var newest: Date?
        for row in values {
            guard let object = row as? [String: Any],
                  let raw = object[key] as? String,
                  let parsed = ContractDate.date(from: raw)
            else { continue }
            if let current = newest {
                newest = max(current, parsed)
            } else {
                newest = parsed
            }
        }
        return newest
    }
}

// MARK: - Assembly

public enum PayloadAssembly {

    /// PostgREST caps a default response, and the golden fixture is 1755 slots
    /// over five days. Anything reading slots pages in blocks of this size.
    public static let slotPageSize = 1000

    /// Stitch three PostgREST reads into the frozen payload.
    ///
    /// - Parameters:
    ///   - generatedAt: When the data was scraped. Pass nil and it is taken
    ///     from the newest `last_seen_at` in the slot rows, falling back to the
    ///     newest `last_attempt_at` in the course-day rows, and only then to
    ///     `now`. It is never "when the download finished": a user reading
    ///     "updated 4 minutes ago" is asking when the club was last checked,
    ///     not when their phone last succeeded at talking to us.
    ///   - contractVersion: The version the rows claim to be. A mismatch is the
    ///     one and only reason to reject a whole payload.
    public static func payload(
        courses: RawRows,
        slots: RawRows,
        courseDays: RawRows,
        mode: ContractPayload.Mode,
        days: Int,
        contractVersion: String = Contract.version,
        generatedAt: Date? = nil,
        now: Date = Date()
    ) throws -> ContractPayload {
        guard contractVersion == Contract.version else {
            throw DataError.contractVersionMismatch(
                expected: Contract.version, found: contractVersion)
        }

        let scrapedAt = generatedAt
            ?? slots.newestTimestamp(key: "last_seen_at")
            ?? courseDays.newestTimestamp(key: "last_attempt_at")
            ?? now

        let document: [String: Any] = [
            "contract_version": contractVersion,
            "generated_at": ContractDate.string(from: scrapedAt),
            "mode": mode.rawValue,
            "days": days,
            "courses": courses.values,
            "slots": slots.values,
            "course_days": courseDays.values,
        ]

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: document)
        } catch {
            // Only reachable if a row held something JSONSerialization parsed
            // but will not re-emit, which it does not do. Mapped rather than
            // trapped: a crash on the read path is never the right answer.
            throw DataError.decoding(reason: "payload: \(error)")
        }

        return try decode(payloadJSON: data)
    }

    /// Decode a whole payload document — a fixture, or a payload that reached
    /// the app by some route other than the three-query read path.
    ///
    /// Leniency is Stage 0's: bad rows land in `payload.issues`, and every one
    /// of them is logged here, so a list that is quietly shorter than it should
    /// be always has a reason written down somewhere.
    public static func decode(payloadJSON data: Data) throws -> ContractPayload {
        let payload: ContractPayload
        do {
            payload = try ContractLoader.decode(data)
        } catch {
            // DataError.from maps ContractLoader.Failure.versionMismatch onto
            // .contractVersionMismatch, which is the one rejection this ticket
            // is allowed to make.
            throw DataError.from(error)
        }

        DataLog.dropped(payload.issues)
        return payload
    }
}
