import Foundation

/// The frozen data contract, version 1.0.0.
///
/// These types are the Swift half of `contract/payload.schema.json`. The same
/// shape comes back from a fixture file and from a Supabase `open_slots`
/// query, so one decoder serves both.
///
/// Stage 0 owns this file. It does not change during Stage 1. If it has to
/// change, `contract/VERSION`, the JSON Schema, the migrations and these types
/// move together in one commit — never one without the others.
public enum Contract {
    public static let version = "1.0.0"
}

// MARK: - Payload

public struct ContractPayload: Codable, Sendable, Equatable {
    public let contractVersion: String
    public let generatedAt: String
    public let mode: Mode
    public let days: Int
    public let courses: [Course]
    public let slots: [Slot]
    public let courseDays: [CourseDay]

    /// Rows the decoder dropped because they were malformed. Never a reason to
    /// fail the whole payload: one bad course must not blank the other
    /// fourteen. Empty on a clean decode.
    public let issues: [DecodingIssue]

    public enum Mode: String, Codable, Sendable {
        case fast
        case full
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case generatedAt = "generated_at"
        case mode
        case days
        case courses
        case slots
        case courseDays = "course_days"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try c.decode(String.self, forKey: .contractVersion)
        generatedAt = try c.decode(String.self, forKey: .generatedAt)
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? .full
        days = (try? c.decode(Int.self, forKey: .days)) ?? 5

        var collected: [DecodingIssue] = []
        courses = try c.decodeLenient([Course].self, forKey: .courses, into: &collected)
        slots = try c.decodeLenient([Slot].self, forKey: .slots, into: &collected)
        courseDays = try c.decodeLenient([CourseDay].self, forKey: .courseDays, into: &collected)
        issues = collected
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(contractVersion, forKey: .contractVersion)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(mode, forKey: .mode)
        try c.encode(days, forKey: .days)
        try c.encode(courses, forKey: .courses)
        try c.encode(slots, forKey: .slots)
        try c.encode(courseDays, forKey: .courseDays)
    }

    public init(
        contractVersion: String = Contract.version,
        generatedAt: String,
        mode: Mode = .full,
        days: Int = 5,
        courses: [Course],
        slots: [Slot],
        courseDays: [CourseDay],
        issues: [DecodingIssue] = []
    ) {
        self.contractVersion = contractVersion
        self.generatedAt = generatedAt
        self.mode = mode
        self.days = days
        self.courses = courses
        self.slots = slots
        self.courseDays = courseDays
        self.issues = issues
    }
}

/// A row the decoder could not read, kept so the app can log or surface it
/// rather than pretending the data was complete.
public struct DecodingIssue: Codable, Sendable, Equatable {
    public let collection: String
    public let index: Int
    public let reason: String

    public init(collection: String, index: Int, reason: String) {
        self.collection = collection
        self.index = index
        self.reason = reason
    }
}

// MARK: - Course

public struct Course: Codable, Sendable, Hashable, Identifiable {
    public var id: String { slug }

    public let slug: String
    public let name: String
    public let region: String
    public let host: String
    public let feeGroupID: String
    public let holes: Int
    public let par: Int?
    /// Always nil in v1. MiClub does not publish course length and we do not
    /// invent it. The field exists so adding it later is not a contract break.
    public let lengthMetres: Int?
    public let driveMinutesFromBondi: Int?
    /// True when the club makes you create a free public-member account before
    /// checkout. Surfaced in the UI so tapping through is not a surprise.
    public let requiresRegistration: Bool
    public let address: String?
    public let notes: String
    public let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case slug, name, region, host, holes, par, address, notes
        case feeGroupID = "fee_group_id"
        case lengthMetres = "length_metres"
        case driveMinutesFromBondi = "drive_minutes_from_bondi"
        case requiresRegistration = "requires_registration"
        case sortOrder = "sort_order"
    }

    public init(
        slug: String, name: String, region: String, host: String, feeGroupID: String,
        holes: Int, par: Int?, lengthMetres: Int? = nil, driveMinutesFromBondi: Int?,
        requiresRegistration: Bool, address: String?, notes: String, sortOrder: Int
    ) {
        self.slug = slug
        self.name = name
        self.region = region
        self.host = host
        self.feeGroupID = feeGroupID
        self.holes = holes
        self.par = par
        self.lengthMetres = lengthMetres
        self.driveMinutesFromBondi = driveMinutesFromBondi
        self.requiresRegistration = requiresRegistration
        self.address = address
        self.notes = notes
        self.sortOrder = sortOrder
    }
}

// MARK: - Slot

public struct Slot: Codable, Sendable, Hashable, Identifiable {
    /// `course_slug:YYYY-MM-DD:HHMM:tee` — deterministic and stable across
    /// scrapes. Stability is what lets the server send one push for a slot
    /// that stays open across twelve scrapes.
    public let id: String
    public let courseSlug: String
    public let courseName: String
    public let region: String
    public let driveMinutesFromBondi: Int?
    public let par: Int?
    public let lengthMetres: Int?
    public let requiresRegistration: Bool
    /// `YYYY-MM-DD` in the course's local calendar.
    public let teeDate: String
    /// `HH:MM:SS` wall-clock at the course.
    public let teeTime: String
    /// The same moment as `teeDate` + `teeTime`, resolved once on the server in
    /// Australia/Sydney. Never recompute it on the client: the DST rules live
    /// in one place on purpose.
    public let teeAt: Date
    public let spotsAvailable: Int
    public let totalSpots: Int
    /// Holes for THIS booking, which is not always the course's hole count —
    /// three 18-hole courses also sell 9-hole tee times.
    public let holes: Int
    /// Nil is ordinary, not an error: about one slot in six publishes no price.
    public let priceMin: Double?
    public let priceMax: Double?
    public let priceTiers: [PriceTier]
    /// The club's own label for the tee, e.g. "1st Tee Social". At a two-tee
    /// start this is the only thing separating two simultaneous bookings.
    public let bookingType: String
    /// Kept as a string because a malformed URL must not fail the decode.
    public let bookingURLString: String

    public var bookingURL: URL? { URL(string: bookingURLString) }

    /// True when the club publishes no price for this slot.
    public var priceIsUnknown: Bool { priceMin == nil }

    enum CodingKeys: String, CodingKey {
        case id, region, par, holes
        case courseSlug = "course_slug"
        case courseName = "course_name"
        case driveMinutesFromBondi = "drive_minutes_from_bondi"
        case lengthMetres = "length_metres"
        case requiresRegistration = "requires_registration"
        case teeDate = "tee_date"
        case teeTime = "tee_time"
        case teeAt = "tee_at"
        case spotsAvailable = "spots_available"
        case totalSpots = "total_spots"
        case priceMin = "price_min"
        case priceMax = "price_max"
        case priceTiers = "price_tiers"
        case bookingType = "booking_type"
        case bookingURLString = "booking_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        courseSlug = try c.decode(String.self, forKey: .courseSlug)
        courseName = try c.decode(String.self, forKey: .courseName)
        region = (try? c.decode(String.self, forKey: .region)) ?? ""
        driveMinutesFromBondi = try c.decodeIfPresent(Int.self, forKey: .driveMinutesFromBondi)
        par = try c.decodeIfPresent(Int.self, forKey: .par)
        lengthMetres = try c.decodeIfPresent(Int.self, forKey: .lengthMetres)
        requiresRegistration = (try? c.decode(Bool.self, forKey: .requiresRegistration)) ?? false
        teeDate = try c.decode(String.self, forKey: .teeDate)
        teeTime = try c.decode(String.self, forKey: .teeTime)
        teeAt = try ContractDate.decode(from: c, forKey: .teeAt)
        spotsAvailable = try c.decode(Int.self, forKey: .spotsAvailable)
        totalSpots = try c.decode(Int.self, forKey: .totalSpots)
        holes = try c.decode(Int.self, forKey: .holes)
        priceMin = try c.decodeNumberIfPresent(forKey: .priceMin)
        priceMax = try c.decodeNumberIfPresent(forKey: .priceMax)
        // A malformed tier must not take its siblings down with it — same
        // principle as the top-level courses/slots/course_days arrays.
        var tierIssues: [DecodingIssue] = []
        priceTiers = (try? c.decodeLenient([PriceTier].self, forKey: .priceTiers, into: &tierIssues)) ?? []
        bookingType = (try? c.decode(String.self, forKey: .bookingType)) ?? ""
        bookingURLString = (try? c.decode(String.self, forKey: .bookingURLString)) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(courseSlug, forKey: .courseSlug)
        try c.encode(courseName, forKey: .courseName)
        try c.encode(region, forKey: .region)
        try c.encode(driveMinutesFromBondi, forKey: .driveMinutesFromBondi)
        try c.encode(par, forKey: .par)
        try c.encode(lengthMetres, forKey: .lengthMetres)
        try c.encode(requiresRegistration, forKey: .requiresRegistration)
        try c.encode(teeDate, forKey: .teeDate)
        try c.encode(teeTime, forKey: .teeTime)
        try c.encode(ContractDate.string(from: teeAt), forKey: .teeAt)
        try c.encode(spotsAvailable, forKey: .spotsAvailable)
        try c.encode(totalSpots, forKey: .totalSpots)
        try c.encode(holes, forKey: .holes)
        try c.encode(priceMin, forKey: .priceMin)
        try c.encode(priceMax, forKey: .priceMax)
        try c.encode(priceTiers, forKey: .priceTiers)
        try c.encode(bookingType, forKey: .bookingType)
        try c.encode(bookingURLString, forKey: .bookingURLString)
    }

    public init(
        id: String, courseSlug: String, courseName: String, region: String,
        driveMinutesFromBondi: Int?, par: Int?, lengthMetres: Int? = nil,
        requiresRegistration: Bool, teeDate: String, teeTime: String, teeAt: Date,
        spotsAvailable: Int, totalSpots: Int, holes: Int, priceMin: Double?,
        priceMax: Double?, priceTiers: [PriceTier], bookingType: String,
        bookingURLString: String
    ) {
        self.id = id
        self.courseSlug = courseSlug
        self.courseName = courseName
        self.region = region
        self.driveMinutesFromBondi = driveMinutesFromBondi
        self.par = par
        self.lengthMetres = lengthMetres
        self.requiresRegistration = requiresRegistration
        self.teeDate = teeDate
        self.teeTime = teeTime
        self.teeAt = teeAt
        self.spotsAvailable = spotsAvailable
        self.totalSpots = totalSpots
        self.holes = holes
        self.priceMin = priceMin
        self.priceMax = priceMax
        self.priceTiers = priceTiers
        self.bookingType = bookingType
        self.bookingURLString = bookingURLString
    }
}

public struct PriceTier: Codable, Sendable, Hashable {
    public let label: String
    public let amount: Double

    public init(label: String, amount: Double) {
        self.label = label
        self.amount = amount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decode(String.self, forKey: .label)) ?? "Standard"
        amount = try c.decodeNumber(forKey: .amount)
    }
}

// MARK: - Scrape health

/// One course, one day, and whether we actually managed to look. Without this
/// a partial scrape is indistinguishable from a complete one.
public struct CourseDay: Codable, Sendable, Hashable {
    public let courseSlug: String
    public let teeDate: String
    public let ok: Bool
    public let slotCount: Int
    public let error: String?
    public let lastAttemptAt: Date
    public let lastSuccessAt: Date?

    enum CodingKeys: String, CodingKey {
        case ok, error
        case courseSlug = "course_slug"
        case teeDate = "tee_date"
        case slotCount = "slot_count"
        case lastAttemptAt = "last_attempt_at"
        case lastSuccessAt = "last_success_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        courseSlug = try c.decode(String.self, forKey: .courseSlug)
        teeDate = try c.decode(String.self, forKey: .teeDate)
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        slotCount = (try? c.decode(Int.self, forKey: .slotCount)) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        lastAttemptAt = try ContractDate.decode(from: c, forKey: .lastAttemptAt)
        lastSuccessAt = try ContractDate.decodeIfPresent(from: c, forKey: .lastSuccessAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(courseSlug, forKey: .courseSlug)
        try c.encode(teeDate, forKey: .teeDate)
        try c.encode(ok, forKey: .ok)
        try c.encode(slotCount, forKey: .slotCount)
        try c.encode(error, forKey: .error)
        try c.encode(ContractDate.string(from: lastAttemptAt), forKey: .lastAttemptAt)
        try c.encode(lastSuccessAt.map(ContractDate.string(from:)), forKey: .lastSuccessAt)
    }

    public init(
        courseSlug: String, teeDate: String, ok: Bool, slotCount: Int,
        error: String?, lastAttemptAt: Date, lastSuccessAt: Date?
    ) {
        self.courseSlug = courseSlug
        self.teeDate = teeDate
        self.ok = ok
        self.slotCount = slotCount
        self.error = error
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
    }
}
