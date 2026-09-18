import Foundation
import TeesContract

/// One row in the results list.
///
/// A thin wrapper rather than a bare `Slot` so the list has a stable
/// `Identifiable` id and so the "we do not know this price" flag is read off
/// one place. The contract's slot id is already unique across a two-tee start
/// — `warringah:2026-10-03:0616:1st-tee-social` and
/// `...:10th-tee-social` — which is exactly why it is safe to key a `ForEach`
/// on it.
public struct SlotResult: Identifiable, Hashable, Sendable {
    public let slot: Slot

    public var id: String { slot.id }

    /// True when the club publishes no fee for this tee time.
    public var priceIsUnknown: Bool { slot.priceMin == nil }

    public init(slot: Slot) {
        self.slot = slot
    }
}

/// One day's worth of results, with the heading already resolved.
public struct SlotDaySection: Identifiable, Hashable, Sendable {
    /// The `tee_date`, `YYYY-MM-DD`. Also the section's identity.
    public let date: String
    /// "Today", "Tomorrow", or "Sat 19 Sep".
    public let title: String
    public let results: [SlotResult]

    public var id: String { date }

    public init(date: String, title: String, results: [SlotResult]) {
        self.date = date
        self.title = title
        self.results = results
    }
}

/// Filtering, ordering and day-grouping. Pure functions over value types, so
/// every ordering decision below is asserted in `SlotQueryTests` instead of
/// being eyeballed in a simulator.
public enum SlotQuery {

    // MARK: - Filtering

    /// Apply the filters and return the matches in the list's canonical order.
    ///
    /// Two rules from CONTRACT.md §3 are enforced here and nowhere else:
    ///
    /// - An **unpriced** slot never fails a `maxPrice` filter. One slot in six
    ///   publishes no fee; hiding 17% of the inventory is worse than showing a
    ///   round whose price we do not know.
    /// - A slot with an **unknown drive time** never fails a
    ///   `maxDriveMinutes` filter, for the same reason.
    ///
    /// `maxPrice` compares against `price_min`: the filter asks "can I play
    /// this for under $X", and the cheapest tier is the honest answer.
    public static func apply(_ filters: SearchFilters, to slots: [Slot]) -> [SlotResult] {
        slots
            .lazy
            .filter { matches(filters, $0) }
            .map(SlotResult.init(slot:))
            .sorted(by: precedes)
    }

    static func matches(_ filters: SearchFilters, _ slot: Slot) -> Bool {
        if !filters.days.isEmpty, !filters.days.contains(slot.teeDate) { return false }

        if !filters.timesOfDay.isEmpty,
           !filters.timesOfDay.contains(where: { $0.matches(teeTime: slot.teeTime) }) {
            return false
        }

        if slot.spotsAvailable < filters.players { return false }

        // The slot's hole count, never the course's.
        if !filters.holes.matches(slot.holes) { return false }

        if let ceiling = filters.maxPrice, let price = slot.priceMin, price > ceiling {
            return false
        }

        if let ceiling = filters.maxDriveMinutes,
           let drive = slot.driveMinutesFromBondi, drive > ceiling {
            return false
        }

        if !filters.courseSlugs.isEmpty, !filters.courseSlugs.contains(slot.courseSlug) {
            return false
        }

        return true
    }

    // MARK: - Ordering

    /// Ascending tee time, then `booking_type`, then id.
    ///
    /// The tie-break is not decoration. Warringah sends a 1st Tee group and a
    /// 10th Tee group out at 06:16 on the same morning: two separate bookings
    /// on the same minute. Sorting on the instant alone leaves their order to
    /// whatever `sorted(by:)` happens to do, which changes between runs and
    /// makes a list animation flicker. Booking type then id is total, so the
    /// order is the same every time.
    public static func precedes(_ lhs: SlotResult, _ rhs: SlotResult) -> Bool {
        if lhs.slot.teeAt != rhs.slot.teeAt { return lhs.slot.teeAt < rhs.slot.teeAt }
        if lhs.slot.bookingType != rhs.slot.bookingType {
            return lhs.slot.bookingType < rhs.slot.bookingType
        }
        return lhs.slot.id < rhs.slot.id
    }

    // MARK: - Grouping

    /// Group results into day sections, ascending by date.
    ///
    /// - Parameters:
    ///   - today: the Sydney wall-clock date, so "Today" and "Tomorrow" are
    ///     resolved once per render rather than per row.
    ///   - priceFilterActive: when true, unpriced slots sink below priced ones
    ///     **within their own day**, still ascending among themselves. They are
    ///     never removed — that is the other half of the §3 rule that
    ///     `apply(_:to:)` starts.
    ///
    /// Days come from the `tee_date` string, never from `tee_at`. The server
    /// resolved Sydney's DST once; deriving a calendar day here is how the two
    /// end up disagreeing on an October morning.
    public static func sections(
        _ results: [SlotResult],
        today: String,
        priceFilterActive: Bool
    ) -> [SlotDaySection] {
        var buckets: [String: [SlotResult]] = [:]
        for result in results {
            buckets[result.slot.teeDate, default: []].append(result)
        }

        // ISO dates sort lexicographically the same way they sort
        // chronologically, so no calendar is needed to order the sections.
        return buckets.keys.sorted().map { date in
            var ordered = (buckets[date] ?? []).sorted(by: precedes)
            if priceFilterActive {
                // A stable partition: both halves keep the order above.
                ordered = ordered.filter { !$0.priceIsUnknown } + ordered.filter(\.priceIsUnknown)
            }
            return SlotDaySection(
                date: date,
                title: SlotFormatting.dayTitle(for: date, today: today),
                results: ordered)
        }
    }
}
