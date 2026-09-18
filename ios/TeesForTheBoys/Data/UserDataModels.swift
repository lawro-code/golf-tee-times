import Foundation
import Supabase
import TeesContract

/// The four user-owned tables, as Swift.
///
/// Everything in this file mirrors `supabase/migrations/0002_user_tables.sql`
/// exactly — column names, nullability and every `check` constraint. That
/// migration is frozen, so when the two disagree this file is wrong.
///
/// ## Two rules that shape all of it
///
/// **`null` on a filter column means "any".** Not "unset", not "the default" —
/// any. A watch with `holes = null` matches a 9-hole booking and an 18-hole
/// one. The app's holes *filter* defaults to 18 (CONTRACT.md #2), but a watch's
/// `holes` may legitimately be null and nothing here may quietly substitute a
/// value for it.
///
/// **A `date` is `YYYY-MM-DD` and a `time` is `HH:MM:SS`, both as strings.**
/// The same way the frozen contract carries `tee_date` and `tee_time`. Putting
/// a `Date` in a date column means the value is re-resolved through whatever
/// time zone the phone happens to be in, which is the exact bug CONTRACT.md #4
/// exists to stop. A calendar date at a golf course in Sydney is not an
/// instant and must not be stored as one.
///
/// ## Where the checks happen
///
/// Both ends. The database has the real constraints; these types run the same
/// ones locally before the round trip so a mistake is a readable
/// `DataError.invalidInput` with the offending field named, not a 400 with a
/// Postgres constraint name in it.

// MARK: - Column formats

/// Parsing and validation for the `date` and `time` columns, and for the
/// timestamps that come back from PostgREST.
public enum UserDataFormat {

    /// Every calendar decision in this ticket is made at the course, which is
    /// in Sydney. Never `TimeZone.current`.
    public static let sydney = TimeZone(identifier: "Australia/Sydney")
        ?? TimeZone(identifier: "UTC")!

    static var sydneyCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sydney
        return calendar
    }

    /// `YYYY-MM-DD`, and a real day: `2026-02-30` is refused here rather than
    /// by Postgres.
    public static func validatedDate(_ raw: String, field: String) throws -> String {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let resolved = sydneyCalendar.date(
                from: DateComponents(year: year, month: month, day: day)),
              sydneyCalendar.component(.month, from: resolved) == month,
              sydneyCalendar.component(.day, from: resolved) == day
        else {
            throw DataError.invalidInput(
                field: field, reason: "\(field) must be a real date written as YYYY-MM-DD.")
        }
        return raw
    }

    /// `HH:MM:SS`. `HH:MM` is accepted and widened, because that is what the
    /// migration's own defaults are written as (`'05:00'`) while PostgREST
    /// renders the column back as `05:00:00`.
    public static func validatedTime(_ raw: String, field: String) throws -> String {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard (parts.count == 2 || parts.count == 3),
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else {
            throw DataError.invalidInput(
                field: field, reason: "\(field) must be a time of day written as HH:MM:SS.")
        }
        var second = 0
        if parts.count == 3 {
            guard let parsed = Int(parts[2]), (0...59).contains(parsed) else {
                throw DataError.invalidInput(
                    field: field, reason: "\(field) must be a time of day written as HH:MM:SS.")
            }
            second = parsed
        }
        return String(format: "%02d:%02d:%02d", hour, minute, second)
    }

    /// The instant a calendar day ends at the course.
    ///
    /// Midnight at the *start of the following day*, resolved with a Sydney
    /// calendar so the two awkward nights a year are the calendar's problem and
    /// not ours: 4 October 2026 is 23 hours long and 5 April 2026 is 25.
    public static func endOfDay(_ date: String, field: String) throws -> Date {
        _ = try validatedDate(date, field: field)
        let parts = date.split(separator: "-").compactMap { Int($0) }
        let calendar = sydneyCalendar
        guard parts.count == 3,
              let midnight = calendar.date(
                from: DateComponents(
                    year: parts[0], month: parts[1], day: parts[2],
                    hour: 0, minute: 0, second: 0)),
              let end = calendar.date(byAdding: .day, value: 1, to: midnight)
        else {
            throw DataError.invalidInput(
                field: field, reason: "\(field) is not a date this calendar can resolve.")
        }
        return end
    }

    /// A `timestamptz` as PostgREST renders it.
    ///
    /// `ContractDate` first, because it is the frozen parser the whole app
    /// shares. The fallback is for Postgres microsecond precision: six
    /// fractional digits are more than `ISO8601DateFormatter` will always take,
    /// and a session that cannot read its own `created_at` back is a silly way
    /// to lose a watch.
    public static func timestamp(from raw: String) -> Date? {
        if let parsed = ContractDate.date(from: raw) { return parsed }
        guard let dot = raw.firstIndex(of: ".") else { return nil }
        let afterFraction = raw[dot...].firstIndex { $0 == "+" || $0 == "-" || $0 == "Z" }
            ?? raw.endIndex
        return ContractDate.date(from: String(raw[raw.startIndex..<dot] + raw[afterFraction...]))
    }

    /// The wire form of a `timestamptz`. Sydney-offset ISO-8601, the same
    /// string the contract writes for `tee_at`.
    public static func string(from date: Date) -> String {
        ContractDate.string(from: date)
    }
}

// MARK: - Decoding helpers

extension KeyedDecodingContainer {
    /// A `numeric` column. Postgres numerics reach us as a JSON number from
    /// some clients and as `"55.00"` from others — the contract says so about
    /// `price_min` and it is just as true of `price_max` and `bookings.price`.
    /// `TeesContract` has the same helper, but it is internal to that module.
    func decodeNumericIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let number = try? decode(Double.self, forKey: key) { return number }
        if let text = try? decode(String.self, forKey: key) { return Double(text) }
        return nil
    }

    /// A `timestamptz` column that must be there.
    func decodeTimestamp(forKey key: Key) throws -> Date {
        let raw = try decode(String.self, forKey: key)
        guard let parsed = UserDataFormat.timestamp(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "\(raw) is not an ISO-8601 timestamp")
        }
        return parsed
    }

    /// A nullable `timestamptz` column. A missing key and an explicit null read
    /// the same, which is what PostgREST's `select=*` and a partial
    /// representation both produce.
    func decodeTimestampIfPresent(forKey key: Key) throws -> Date? {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let parsed = UserDataFormat.timestamp(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "\(raw) is not an ISO-8601 timestamp")
        }
        return parsed
    }
}

// MARK: - Watch

/// A saved search, owned by one user.
///
/// The active filters describe it completely — that is why creating one is a
/// single button and never a wizard (BUILD-PLAN.md), and why these are columns
/// rather than a `jsonb` blob: the matcher runs them as a SQL predicate.
public struct Watch: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Always the signed-in user. Set server-side from the insert the
    /// repository built; a caller never supplies it.
    public let userID: UUID
    public let label: String?
    /// nil means every course. Non-nil is never empty — the database refuses it.
    public let courseSlugs: [String]?
    /// ISO-8601 weekdays: 1 = Monday … 7 = Sunday. nil means any day.
    public let weekdays: [Int]?
    /// `YYYY-MM-DD`, or nil for "from whenever".
    public let dateFrom: String?
    /// `YYYY-MM-DD`, or nil for "until whenever".
    public let dateTo: String?
    /// `HH:MM:SS` wall clock at the course.
    public let timeFrom: String
    public let timeTo: String
    /// 1–4. How many of you need to get on.
    public let minPlayers: Int
    /// 9, 18, or nil for either.
    public let holes: Int?
    public let priceMax: Double?
    public let maxDriveMinutes: Int?
    public let active: Bool
    public let createdAt: Date
    public let updatedAt: Date
    /// When this watch stops being worth matching — the end of `dateTo` in
    /// Sydney, or nil when the watch has no end date.
    public let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, label, weekdays, holes, active
        case userID = "user_id"
        case courseSlugs = "course_slugs"
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case timeFrom = "time_from"
        case timeTo = "time_to"
        case minPlayers = "min_players"
        case priceMax = "price_max"
        case maxDriveMinutes = "max_drive_minutes"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        userID = try c.decode(UUID.self, forKey: .userID)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        courseSlugs = try c.decodeIfPresent([String].self, forKey: .courseSlugs)
        weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdays)
        dateFrom = try c.decodeIfPresent(String.self, forKey: .dateFrom)
        dateTo = try c.decodeIfPresent(String.self, forKey: .dateTo)
        timeFrom = try c.decode(String.self, forKey: .timeFrom)
        timeTo = try c.decode(String.self, forKey: .timeTo)
        minPlayers = try c.decode(Int.self, forKey: .minPlayers)
        holes = try c.decodeIfPresent(Int.self, forKey: .holes)
        // numeric(10,2) arrives as a JSON number from some clients and as
        // "55.00" from others, exactly as the contract warns for price_min.
        priceMax = try c.decodeNumericIfPresent(forKey: .priceMax)
        maxDriveMinutes = try c.decodeIfPresent(Int.self, forKey: .maxDriveMinutes)
        active = try c.decode(Bool.self, forKey: .active)
        createdAt = try c.decodeTimestamp(forKey: .createdAt)
        updatedAt = try c.decodeTimestamp(forKey: .updatedAt)
        expiresAt = try c.decodeTimestampIfPresent(forKey: .expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userID, forKey: .userID)
        try c.encode(label, forKey: .label)
        try c.encode(courseSlugs, forKey: .courseSlugs)
        try c.encode(weekdays, forKey: .weekdays)
        try c.encode(dateFrom, forKey: .dateFrom)
        try c.encode(dateTo, forKey: .dateTo)
        try c.encode(timeFrom, forKey: .timeFrom)
        try c.encode(timeTo, forKey: .timeTo)
        try c.encode(minPlayers, forKey: .minPlayers)
        try c.encode(holes, forKey: .holes)
        try c.encode(priceMax, forKey: .priceMax)
        try c.encode(maxDriveMinutes, forKey: .maxDriveMinutes)
        try c.encode(active, forKey: .active)
        try c.encode(UserDataFormat.string(from: createdAt), forKey: .createdAt)
        try c.encode(UserDataFormat.string(from: updatedAt), forKey: .updatedAt)
        try c.encode(expiresAt.map(UserDataFormat.string(from:)), forKey: .expiresAt)
    }

    public init(
        id: UUID, userID: UUID, label: String?, courseSlugs: [String]?, weekdays: [Int]?,
        dateFrom: String?, dateTo: String?, timeFrom: String, timeTo: String,
        minPlayers: Int, holes: Int?, priceMax: Double?, maxDriveMinutes: Int?,
        active: Bool, createdAt: Date, updatedAt: Date, expiresAt: Date?
    ) {
        self.id = id
        self.userID = userID
        self.label = label
        self.courseSlugs = courseSlugs
        self.weekdays = weekdays
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.timeFrom = timeFrom
        self.timeTo = timeTo
        self.minPlayers = minPlayers
        self.holes = holes
        self.priceMax = priceMax
        self.maxDriveMinutes = maxDriveMinutes
        self.active = active
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
}

/// What a caller hands ``WatchRepository`` — the filters, and nothing else.
///
/// No `id`, no `user_id`, no `expires_at`: the repository owns all three. A
/// draft that a caller could put someone else's user id in would be a draft
/// that RLS has to catch, and a wall you can lean on is not a wall.
public struct WatchDraft: Codable, Sendable, Equatable {

    /// The migration's own defaults, so a draft and a fresh row agree.
    public static let defaultTimeFrom = "05:00:00"
    public static let defaultTimeTo = "19:00:00"

    public var label: String?
    /// nil = every course. An empty array is not nil and is refused.
    public var courseSlugs: [String]?
    /// ISO-8601: 1 = Monday … 7 = Sunday. nil = any day.
    public var weekdays: [Int]?
    public var dateFrom: String?
    public var dateTo: String?
    public var timeFrom: String
    public var timeTo: String
    public var minPlayers: Int
    /// Defaults to nil, meaning **either**. The app's holes filter defaults to
    /// 18 and track C passes whatever the golfer chose; this type does not
    /// invent 18 for a caller who said nothing, because null and 18 are
    /// different watches.
    public var holes: Int?
    public var priceMax: Double?
    public var maxDriveMinutes: Int?
    public var active: Bool

    public init(
        label: String? = nil,
        courseSlugs: [String]? = nil,
        weekdays: [Int]? = nil,
        dateFrom: String? = nil,
        dateTo: String? = nil,
        timeFrom: String = WatchDraft.defaultTimeFrom,
        timeTo: String = WatchDraft.defaultTimeTo,
        minPlayers: Int = 1,
        holes: Int? = nil,
        priceMax: Double? = nil,
        maxDriveMinutes: Int? = nil,
        active: Bool = true
    ) {
        self.label = label
        self.courseSlugs = courseSlugs
        self.weekdays = weekdays
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.timeFrom = timeFrom
        self.timeTo = timeTo
        self.minPlayers = minPlayers
        self.holes = holes
        self.priceMax = priceMax
        self.maxDriveMinutes = maxDriveMinutes
        self.active = active
    }

    /// Edit an existing watch: the round trip a "change this alert" screen needs.
    public init(watch: Watch) {
        self.init(
            label: watch.label,
            courseSlugs: watch.courseSlugs,
            weekdays: watch.weekdays,
            dateFrom: watch.dateFrom,
            dateTo: watch.dateTo,
            timeFrom: watch.timeFrom,
            timeTo: watch.timeTo,
            minPlayers: watch.minPlayers,
            holes: watch.holes,
            priceMax: watch.priceMax,
            maxDriveMinutes: watch.maxDriveMinutes,
            active: watch.active)
    }

    enum CodingKeys: String, CodingKey {
        case label, weekdays, holes, active
        case courseSlugs = "course_slugs"
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case timeFrom = "time_from"
        case timeTo = "time_to"
        case minPlayers = "min_players"
        case priceMax = "price_max"
        case maxDriveMinutes = "max_drive_minutes"
    }

    /// Every constraint `public.watches` carries, run here first.
    ///
    /// Returns a normalised copy — times widened to `HH:MM:SS`, weekdays sorted
    /// and de-duplicated, blank label dropped — so what goes on the wire is
    /// what the database would have stored anyway.
    ///
    /// - Throws: ``DataError/invalidInput(field:reason:)``, naming the column.
    public func validated() throws -> WatchDraft {
        var normalised = self

        if let label = normalised.label?.trimmingCharacters(in: .whitespacesAndNewlines) {
            normalised.label = label.isEmpty ? nil : label
        }

        // constraint watches_courses_sane
        if let slugs = normalised.courseSlugs {
            let cleaned = slugs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !cleaned.isEmpty else {
                throw DataError.invalidInput(
                    field: "course_slugs",
                    reason: "Pick at least one course, or leave it on every course.")
            }
            normalised.courseSlugs = cleaned
        }

        // constraint watches_weekdays_sane
        if let weekdays = normalised.weekdays {
            guard !weekdays.isEmpty else {
                throw DataError.invalidInput(
                    field: "weekdays", reason: "Pick at least one day, or leave it on any day.")
            }
            guard weekdays.allSatisfy({ (1...7).contains($0) }) else {
                throw DataError.invalidInput(
                    field: "weekdays",
                    reason: "Days must be 1 (Monday) to 7 (Sunday).")
            }
            normalised.weekdays = Array(Set(weekdays)).sorted()
        }

        // The date and time columns, as formats first
        if let dateFrom = normalised.dateFrom {
            normalised.dateFrom = try UserDataFormat.validatedDate(dateFrom, field: "date_from")
        }
        if let dateTo = normalised.dateTo {
            normalised.dateTo = try UserDataFormat.validatedDate(dateTo, field: "date_to")
        }
        normalised.timeFrom = try UserDataFormat.validatedTime(
            normalised.timeFrom, field: "time_from")
        normalised.timeTo = try UserDataFormat.validatedTime(normalised.timeTo, field: "time_to")

        // constraint watches_date_order. Both are zero-padded, so the string
        // order is the calendar order.
        if let from = normalised.dateFrom, let to = normalised.dateTo, from > to {
            throw DataError.invalidInput(
                field: "date_to", reason: "The last date has to be on or after the first one.")
        }

        // constraint watches_time_order
        if normalised.timeFrom > normalised.timeTo {
            throw DataError.invalidInput(
                field: "time_to", reason: "The latest tee time has to be after the earliest one.")
        }

        // check (min_players between 1 and 4)
        guard (1...4).contains(normalised.minPlayers) else {
            throw DataError.invalidInput(
                field: "min_players", reason: "A group is between 1 and 4 players.")
        }

        // check (holes is null or holes in (9, 18))
        if let holes = normalised.holes, holes != 9, holes != 18 {
            throw DataError.invalidInput(
                field: "holes", reason: "A round is 9 or 18 holes.")
        }

        // check (price_max is null or price_max >= 0)
        if let priceMax = normalised.priceMax, priceMax < 0 {
            throw DataError.invalidInput(
                field: "price_max", reason: "A maximum price cannot be negative.")
        }

        // check (max_drive_minutes is null or max_drive_minutes >= 0)
        if let drive = normalised.maxDriveMinutes, drive < 0 {
            throw DataError.invalidInput(
                field: "max_drive_minutes", reason: "A drive cannot take negative minutes.")
        }

        return normalised
    }
}

// MARK: - Booking

/// A tee time the golfer said yes to.
///
/// Course name, tee time and price are copied off the ``Slot`` rather than
/// referenced, because `slot_id` is `on delete set null` and a slot stops being
/// listed the moment someone books it. An upcoming round has to keep rendering
/// after the row it came from is gone.
public struct Booking: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let userID: UUID
    /// nil once the slot row it came from has been deleted. The round survives.
    public let slotID: String?
    public let courseSlug: String
    public let courseName: String
    public let teeAt: Date
    /// `YYYY-MM-DD` at the course.
    public let teeDate: String
    /// `HH:MM:SS` at the course.
    public let teeTime: String
    public let players: Int?
    public let holes: Int?
    public let price: Double?
    /// Kept as a string, like the contract does: a malformed URL must not fail
    /// the decode.
    public let bookingURLString: String?
    public let confirmedAt: Date
    public let cancelledAt: Date?

    public var bookingURL: URL? { bookingURLString.flatMap(URL.init(string:)) }
    public var isCancelled: Bool { cancelledAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, players, holes, price
        case userID = "user_id"
        case slotID = "slot_id"
        case courseSlug = "course_slug"
        case courseName = "course_name"
        case teeAt = "tee_at"
        case teeDate = "tee_date"
        case teeTime = "tee_time"
        case bookingURLString = "booking_url"
        case confirmedAt = "confirmed_at"
        case cancelledAt = "cancelled_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        userID = try c.decode(UUID.self, forKey: .userID)
        slotID = try c.decodeIfPresent(String.self, forKey: .slotID)
        courseSlug = try c.decode(String.self, forKey: .courseSlug)
        courseName = try c.decode(String.self, forKey: .courseName)
        teeAt = try c.decodeTimestamp(forKey: .teeAt)
        teeDate = try c.decode(String.self, forKey: .teeDate)
        teeTime = try c.decode(String.self, forKey: .teeTime)
        players = try c.decodeIfPresent(Int.self, forKey: .players)
        holes = try c.decodeIfPresent(Int.self, forKey: .holes)
        price = try c.decodeNumericIfPresent(forKey: .price)
        bookingURLString = try c.decodeIfPresent(String.self, forKey: .bookingURLString)
        confirmedAt = try c.decodeTimestamp(forKey: .confirmedAt)
        cancelledAt = try c.decodeTimestampIfPresent(forKey: .cancelledAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userID, forKey: .userID)
        try c.encode(slotID, forKey: .slotID)
        try c.encode(courseSlug, forKey: .courseSlug)
        try c.encode(courseName, forKey: .courseName)
        try c.encode(UserDataFormat.string(from: teeAt), forKey: .teeAt)
        try c.encode(teeDate, forKey: .teeDate)
        try c.encode(teeTime, forKey: .teeTime)
        try c.encode(players, forKey: .players)
        try c.encode(holes, forKey: .holes)
        try c.encode(price, forKey: .price)
        try c.encode(bookingURLString, forKey: .bookingURLString)
        try c.encode(UserDataFormat.string(from: confirmedAt), forKey: .confirmedAt)
        try c.encode(cancelledAt.map(UserDataFormat.string(from:)), forKey: .cancelledAt)
    }

    public init(
        id: UUID, userID: UUID, slotID: String?, courseSlug: String, courseName: String,
        teeAt: Date, teeDate: String, teeTime: String, players: Int?, holes: Int?,
        price: Double?, bookingURLString: String?, confirmedAt: Date, cancelledAt: Date?
    ) {
        self.id = id
        self.userID = userID
        self.slotID = slotID
        self.courseSlug = courseSlug
        self.courseName = courseName
        self.teeAt = teeAt
        self.teeDate = teeDate
        self.teeTime = teeTime
        self.players = players
        self.holes = holes
        self.price = price
        self.bookingURLString = bookingURLString
        self.confirmedAt = confirmedAt
        self.cancelledAt = cancelledAt
    }
}

// MARK: - Push token

/// Which APNs environment a token was minted in. A sandbox token sent to the
/// production gateway is rejected, and the other way round, so the row has to
/// remember.
public enum PushEnvironment: String, Codable, Sendable, CaseIterable {
    case sandbox
    case production
}

/// One APNs device token for one user.
///
/// Keyed on `(user_id, token)`, never on the token alone — two mates sharing an
/// iPhone is an ordinary case for an app about a group of blokes booking golf,
/// and the migration explains at length what a token-only key does to the
/// second one to sign in.
public struct PushToken: Codable, Sendable, Equatable {
    /// The only platform the check constraint allows today.
    public static let platformIOS = "ios"

    public let userID: UUID
    public let token: String
    public let platform: String
    public let environment: PushEnvironment
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case token, platform, environment
        case userID = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        token = try c.decode(String.self, forKey: .token)
        platform = try c.decode(String.self, forKey: .platform)
        environment = try c.decode(PushEnvironment.self, forKey: .environment)
        createdAt = try c.decodeTimestamp(forKey: .createdAt)
        updatedAt = try c.decodeTimestamp(forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID, forKey: .userID)
        try c.encode(token, forKey: .token)
        try c.encode(platform, forKey: .platform)
        try c.encode(environment, forKey: .environment)
        try c.encode(UserDataFormat.string(from: createdAt), forKey: .createdAt)
        try c.encode(UserDataFormat.string(from: updatedAt), forKey: .updatedAt)
    }

    public init(
        userID: UUID, token: String, platform: String = PushToken.platformIOS,
        environment: PushEnvironment, createdAt: Date, updatedAt: Date
    ) {
        self.userID = userID
        self.token = token
        self.platform = platform
        self.environment = environment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - The rows that go on the wire

/// A `watches` row as an insert or a PATCH.
///
/// Every filter column is written explicitly, including the nil ones. That is
/// the whole reason this is not `WatchDraft` with synthesised `Encodable`:
/// synthesis uses `encodeIfPresent`, a nil column would be left out of the
/// PATCH, and "clear the price limit" would silently do nothing.
struct WatchWriteRow: Encodable {
    /// Set on insert, absent on update — the owner of a row never changes, and
    /// a PATCH that re-sent it would be a PATCH that RLS has to argue with.
    var userID: UUID?
    let draft: WatchDraft
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case label, weekdays, holes, active
        case userID = "user_id"
        case courseSlugs = "course_slugs"
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case timeFrom = "time_from"
        case timeTo = "time_to"
        case minPlayers = "min_players"
        case priceMax = "price_max"
        case maxDriveMinutes = "max_drive_minutes"
        case expiresAt = "expires_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let userID { try c.encode(userID, forKey: .userID) }
        try c.encode(draft.label, forKey: .label)
        try c.encode(draft.courseSlugs, forKey: .courseSlugs)
        try c.encode(draft.weekdays, forKey: .weekdays)
        try c.encode(draft.dateFrom, forKey: .dateFrom)
        try c.encode(draft.dateTo, forKey: .dateTo)
        try c.encode(draft.timeFrom, forKey: .timeFrom)
        try c.encode(draft.timeTo, forKey: .timeTo)
        try c.encode(draft.minPlayers, forKey: .minPlayers)
        try c.encode(draft.holes, forKey: .holes)
        try c.encode(draft.priceMax, forKey: .priceMax)
        try c.encode(draft.maxDriveMinutes, forKey: .maxDriveMinutes)
        try c.encode(draft.active, forKey: .active)
        try c.encode(expiresAt.map(UserDataFormat.string(from:)), forKey: .expiresAt)
    }
}

/// A `bookings` upsert. `confirmed_at` is deliberately absent: the database
/// defaults it on insert, and on a second yes the original stands.
struct BookingWriteRow: Encodable {
    let userID: UUID
    let slotID: String
    let courseSlug: String
    let courseName: String
    let teeAt: Date
    let teeDate: String
    let teeTime: String
    let players: Int?
    let holes: Int?
    let price: Double?
    let bookingURL: String?

    enum CodingKeys: String, CodingKey {
        case players, holes, price
        case userID = "user_id"
        case slotID = "slot_id"
        case courseSlug = "course_slug"
        case courseName = "course_name"
        case teeAt = "tee_at"
        case teeDate = "tee_date"
        case teeTime = "tee_time"
        case bookingURL = "booking_url"
        case cancelledAt = "cancelled_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID, forKey: .userID)
        try c.encode(slotID, forKey: .slotID)
        try c.encode(courseSlug, forKey: .courseSlug)
        try c.encode(courseName, forKey: .courseName)
        try c.encode(UserDataFormat.string(from: teeAt), forKey: .teeAt)
        try c.encode(teeDate, forKey: .teeDate)
        try c.encode(teeTime, forKey: .teeTime)
        try c.encode(players, forKey: .players)
        try c.encode(holes, forKey: .holes)
        try c.encode(price, forKey: .price)
        try c.encode(bookingURL, forKey: .bookingURL)
        // Saying yes after a cancel un-cancels the round. Sent as an explicit
        // null so the merge actually clears it.
        try c.encodeNil(forKey: .cancelledAt)
    }
}

/// A `push_tokens` upsert on `(user_id, token)`.
struct PushTokenWriteRow: Encodable {
    let userID: UUID
    let token: String
    let platform: String
    let environment: PushEnvironment
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case token, platform, environment
        case userID = "user_id"
        case updatedAt = "updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID, forKey: .userID)
        try c.encode(token, forKey: .token)
        try c.encode(platform, forKey: .platform)
        try c.encode(environment, forKey: .environment)
        try c.encode(UserDataFormat.string(from: updatedAt), forKey: .updatedAt)
    }
}

// MARK: - One request

/// Runs one PostgREST request against a user-owned table and turns every
/// failure into a ``DataError``.
///
/// It lives here rather than in one of the three repositories because all three
/// need it and none of them owns the others. The catch ladder deliberately
/// matches `SupabaseSlotsRemote`'s: one module, one set of rules about what a
/// failure means.
enum UserDataRequest {

    /// The raw response body. Decoding is the caller's, because a repository
    /// knows whether it asked for one row or many.
    static func data(_ build: () throws -> PostgrestBuilder) async throws -> Data {
        do {
            return try await build().execute().data
        } catch let error as HTTPError {
            // The one foreign error `DataError.from` does not know, handled the
            // same way `SupabaseSlotsRemote` handles it: a non-2xx body that is
            // not PostgREST's JSON. Left to `from` it would read as
            // `.transport` and the UI would blame the user's signal for
            // something the server did.
            throw DataError.server(
                status: error.response.statusCode,
                message: String(data: error.data, encoding: .utf8))
        } catch {
            throw DataError.from(error)
        }
    }

    /// Fire and forget — a DELETE whose body we do not care about.
    static func send(_ build: () throws -> PostgrestBuilder) async throws {
        _ = try await data(build)
    }

    static func decode<T: Decodable>(
        _ type: T.Type, from data: Data, table: String
    ) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DataError.decoding(reason: "\(table): \(DataError.from(error).diagnostic)")
        }
    }

    /// No date strategy on purpose: every timestamp in this ticket is decoded
    /// from its string by ``UserDataFormat``, which is the parser the frozen
    /// contract already uses.
    private static let decoder = JSONDecoder()
}
