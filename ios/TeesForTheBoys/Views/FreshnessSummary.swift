import Foundation
import TeesContract

/// What the app knows about whether the tee times on screen are real.
///
/// CONTRACT.md §5: **a club that failed and a club with nothing free are not
/// the same thing.** Long Reef scraped perfectly and had zero open tee times;
/// a club returning a 500 also shows zero. Rendering those identically tells a
/// golfer "there is nothing at Castle Cove" when the truth is "we could not
/// look at Castle Cove". `course_day_scrapes` records which, so the app has no
/// excuse for conflating them.
///
/// The type is a value, computed once per payload by `make`, so the banner is
/// not recomputing string interpolation on every render pass.
public struct FreshnessSummary: Equatable, Sendable {

    /// The most recent moment any course was successfully reached. Nil means we
    /// have never reached one.
    public let lastSuccessAt: Date?

    /// Slugs of clubs whose scrape failed — `course_days` with `ok == false`.
    /// Sorted, so the banner text is deterministic.
    public let failedCourseSlugs: [String]

    /// Display names for `failedCourseSlugs`, same order.
    public let failedCourseNames: [String]

    /// Slugs of clubs we reached that had nothing free — `ok == true` and
    /// `slot_count == 0`. Sorted.
    public let healthyButEmptyCourseSlugs: [String]

    /// Display names for `healthyButEmptyCourseSlugs`, same order.
    public let healthyButEmptyCourseNames: [String]

    /// True when the newest success is older than `staleAfter`, or when there
    /// has never been one.
    public let isStale: Bool

    /// The banner. Nil when everything is fresh and every club was reached.
    ///
    /// A healthy-but-empty club does **not** raise a banner: we looked, and
    /// there was nothing. That is an empty-state sentence
    /// (`emptyClubsText`), not a warning.
    public let bannerText: String?

    public init(
        lastSuccessAt: Date?,
        failedCourseSlugs: [String],
        failedCourseNames: [String],
        healthyButEmptyCourseSlugs: [String],
        healthyButEmptyCourseNames: [String],
        isStale: Bool,
        bannerText: String?
    ) {
        self.lastSuccessAt = lastSuccessAt
        self.failedCourseSlugs = failedCourseSlugs
        self.failedCourseNames = failedCourseNames
        self.healthyButEmptyCourseSlugs = healthyButEmptyCourseSlugs
        self.healthyButEmptyCourseNames = healthyButEmptyCourseNames
        self.isStale = isStale
        self.bannerText = bannerText
    }

    /// Before anything has loaded. Not stale, because "we have not looked yet"
    /// is not the same claim as "what you are seeing is old" — the loading
    /// state says the first one, and saying both at once is noise.
    public static let unknown = FreshnessSummary(
        lastSuccessAt: nil,
        failedCourseSlugs: [],
        failedCourseNames: [],
        healthyButEmptyCourseSlugs: [],
        healthyButEmptyCourseNames: [],
        isStale: false,
        bannerText: nil)

    /// "Long Reef has nothing free", for an empty results state. Nil when every
    /// club we reached had something.
    public var emptyClubsText: String? {
        guard !healthyButEmptyCourseNames.isEmpty else { return nil }
        let verb = healthyButEmptyCourseNames.count == 1 ? "has" : "have"
        return "\(Self.nameList(healthyButEmptyCourseNames)) \(verb) nothing free"
    }

    /// True when every club reported in, and recently.
    public var isFullyFresh: Bool { !isStale && failedCourseSlugs.isEmpty }

    // MARK: - Building

    /// - Parameters:
    ///   - courseDays: `payload.course_days`, one row per course per day.
    ///   - courses: used only to turn a slug into a name a golfer recognises.
    ///     A slug with no matching course still gets a readable fallback rather
    ///     than being dropped — an unknown club is still a club we failed on.
    ///   - staleAfter: three hours by default. The scrape runs every 20 minutes
    ///     for days 0-2, so three hours is roughly nine missed runs: long past
    ///     a blip, and short enough that a golfer is warned before acting on it.
    public static func make(
        courseDays: [CourseDay],
        courses: [Course],
        now: Date,
        staleAfter: TimeInterval = 3 * 3600
    ) -> FreshnessSummary {
        var names: [String: String] = [:]
        for course in courses {
            names[course.slug] = SlotFormatting.shortCourseName(course.name)
        }

        var failed: Set<String> = []
        // "Nothing free" is a claim about the whole club, not one of its days
        // — a course open Sunday and full Saturday is not empty. So this has
        // to aggregate every reached day per course before deciding, not flag
        // a course the moment any single day of it shows zero.
        var okSlotsByCourse: [String: Int] = [:]
        var newestSuccess: Date?

        for day in courseDays {
            // lastSuccessAt is "the last time we reached this course", which
            // survives a failed scrape — that is the whole point of remembering
            // it. Gating this read on day.ok threw it away exactly when it
            // mattered: a club down for three hours read as "never reached"
            // instead of "last reached three hours ago".
            if let success = day.lastSuccessAt {
                if let current = newestSuccess {
                    newestSuccess = Swift.max(current, success)
                } else {
                    newestSuccess = success
                }
            }
            if day.ok {
                okSlotsByCourse[day.courseSlug, default: 0] += day.slotCount
            } else {
                failed.insert(day.courseSlug)
            }
        }

        // A club that failed on one day and was merely empty on another is a
        // failure. The stronger claim wins, or the banner under-reports.
        let empty = Set(
            okSlotsByCourse
                .filter { slug, total in total == 0 && !failed.contains(slug) }
                .keys)

        let failedSlugs = failed.sorted()
        let emptySlugs = empty.sorted()
        let failedNames = failedSlugs.map { names[$0] ?? fallbackName(for: $0) }
        let emptyNames = emptySlugs.map { names[$0] ?? fallbackName(for: $0) }

        let stale: Bool
        if let newestSuccess {
            stale = now.timeIntervalSince(newestSuccess) > staleAfter
        } else {
            stale = true
        }

        var parts: [String] = []
        if stale {
            if let newestSuccess {
                parts.append("Tee times last updated \(relativeAge(from: newestSuccess, to: now))")
            } else {
                parts.append("Tee times haven't loaded yet")
            }
        }
        if !failedNames.isEmpty {
            // Name the club. "Couldn't reach Castle Cove" reads differently
            // from "Castle Cove has nothing free", and a golfer deciding
            // whether to drive there needs to know which one it is.
            parts.append("Couldn't reach \(nameList(failedNames))")
        }

        return FreshnessSummary(
            lastSuccessAt: newestSuccess,
            failedCourseSlugs: failedSlugs,
            failedCourseNames: failedNames,
            healthyButEmptyCourseSlugs: emptySlugs,
            healthyButEmptyCourseNames: emptyNames,
            isStale: stale,
            bannerText: parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} "))
    }

    // MARK: - Copy

    /// `"Castle Cove"`, `"Castle Cove and Bayview"`,
    /// `"Castle Cove, Bayview and 2 more"`.
    ///
    /// Capped rather than exhaustive: a banner listing eleven clubs is a
    /// paragraph, and at that point the number is the story.
    public static func nameList(_ names: [String], limit: Int = 2) -> String {
        guard !names.isEmpty else { return "" }
        if names.count <= limit {
            if names.count == 1 { return names[0] }
            return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        let shown = names.prefix(limit).joined(separator: ", ")
        return "\(shown) and \(names.count - limit) more"
    }

    /// Whole units only, and never smaller than the thing being described. The
    /// scrape cadence is 20 minutes, so "37 minutes ago" is as precise as this
    /// number can honestly be.
    public static func relativeAge(from: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(from)
        // A clock that jumped backwards must read as current, not wrap into a
        // negative age.
        guard seconds > 60 else { return "just now" }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        }
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let days = Int(seconds / 86_400)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// `"castle-cove"` → `"Castle Cove"`, for a slug with no course row.
    static func fallbackName(for slug: String) -> String {
        slug.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
