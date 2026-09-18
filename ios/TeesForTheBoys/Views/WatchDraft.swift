import Foundation
import TeesContract

/// A watch, as the golfer would say it out loud, built from the filters that
/// are already on screen.
///
/// The whole point of ticket C3 is that creating an alert is **one tap**. That
/// only works if the active filters already describe the watch completely — so
/// this type is the proof that they do. It takes a `SearchFilters` and turns it
/// into two sentences, and those sentences are the entire user-facing surface
/// of the feature: the button's accessibility label, the confirmation, and the
/// empty-state headline are all one of these two strings.
///
/// ## Why the sentences are stored, not computed on demand
///
/// They are pure functions of `(filters, courses, today)`, which is what makes
/// them testable without rendering anything — `ios/project.yml` is frozen, so
/// there is no ViewInspector and a screen's body cannot be asserted on. Every
/// product decision about wording therefore lives in a `static` function here
/// and is pinned by `WatchDraftTests`.
///
/// ## The two sentences
///
/// | Property | Used as | Shape |
/// |---|---|---|
/// | `sentence` | button label, VoiceOver label, confirmation | `Alert me when a morning tee time opens on Saturday at The Coast` |
/// | `emptySentence` | empty-state headline | `No morning tee times on Saturday at The Coast — alert me when one opens.` |
///
/// ## Rules the wording follows
///
/// Only **active** filters are named. An unset dimension is not mentioned at
/// all: "any day" and "any club" are how the adjust sheet labels an empty
/// picker (see `AlertAdjustSheet`), not words that belong in a sentence — and
/// a standard, untouched filter set has to read exactly
/// `Alert me when any tee time opens`, which contains neither.
///
/// - Days are named by weekday, except today and tomorrow, which say so. That
///   is the only thing the injected `today` is used for. Days are always
///   `tee_date` strings; nothing here recomputes an instant (CONTRACT.md §4).
/// - Holes are mentioned only when they are not the default 18 (CONTRACT.md §2
///   — 18 is a real choice a golfer made, so it is the silent default).
/// - Price is mentioned only when a ceiling is set, players only above one.
/// - **Drive time is mentioned when it is set**, even though the ticket's list
///   of qualifiers does not name it. `SearchFilters.activeCount` counts it, so
///   a golfer can set it; a sentence that quietly dropped it would be telling
///   them their watch is something it is not.
///
/// Grammar has to survive every combination of the above, which is why the
/// pieces are assembled as clauses rather than interpolated into a template.
public struct WatchDraft: Equatable, Sendable, Identifiable {

    /// Stable across an edit. `updating(filters:)` keeps it, so the data layer
    /// in Stage 2 can upsert the watch a golfer adjusted rather than saving a
    /// second one.
    public let id: UUID

    /// The filters this watch was built from.
    ///
    /// - Warning: assigning to this does **not** rebuild the sentences — they
    ///   are `let` by design, so a draft is never half-updated mid-render. Use
    ///   `updating(filters:)`, which returns a whole new draft with the same
    ///   `id`.
    public var filters: SearchFilters

    /// The sentence used when results exist.
    public let sentence: String

    /// The sentence used as the empty-state headline.
    public let emptySentence: String

    /// The frozen fifteen, so a slug can be turned into a club's name. Carried
    /// on the draft because `AlertAdjustSheet` needs them to offer the club
    /// picker and it is only ever handed a draft.
    public let courses: [Course]

    /// The Sydney wall-clock date the sentences were phrased against.
    public let today: String

    public init(filters: SearchFilters, courses: [Course], today: String) {
        self.init(id: UUID(), filters: filters, courses: courses, today: today)
    }

    /// The identity-preserving init. Used by `updating(filters:)` and by any
    /// caller re-hydrating a watch it already saved.
    public init(id: UUID, filters: SearchFilters, courses: [Course], today: String) {
        self.id = id
        self.filters = filters
        self.courses = courses
        self.today = today
        self.sentence = WatchSentence.statement(filters: filters, courses: courses, today: today)
        self.emptySentence = WatchSentence.empty(filters: filters, courses: courses, today: today)
    }

    /// The same watch with different filters and both sentences rebuilt.
    ///
    /// This is what the adjust sheet calls on every keystroke to restate the
    /// sentence live, and what it hands back on Save.
    public func updating(filters: SearchFilters) -> WatchDraft {
        WatchDraft(id: id, filters: filters, courses: courses, today: today)
    }
}

// MARK: - Sentence composition

/// Every wording decision in ticket C3, as pure functions.
///
/// Separate from `WatchDraft` so the assembly can be read top to bottom without
/// the storage in the way, and so each clause can be reasoned about on its own.
enum WatchSentence {

    // MARK: Whole sentences

    /// `Alert me when a morning tee time opens on Saturday at The Coast, 9 holes`
    static func statement(filters: SearchFilters, courses: [Course], today: String) -> String {
        "Alert me when \(subject(filters, plural: false)) opens"
            + context(filters, courses: courses, today: today)
    }

    /// `No morning tee times on Saturday at The Coast — alert me when one opens.`
    static func empty(filters: SearchFilters, courses: [Course], today: String) -> String {
        "No \(subject(filters, plural: true))"
            + context(filters, courses: courses, today: today)
            + " \u{2014} alert me when one opens."
    }

    /// Everything after the noun: when, where, and the qualifiers. Identical in
    /// both sentences, which is why it is built once.
    private static func context(
        _ filters: SearchFilters, courses: [Course], today: String
    ) -> String {
        var text = dayClause(filters, today: today) + clubClause(filters, courses: courses)
        let extras = qualifiers(filters)
        if !extras.isEmpty {
            text += ", " + extras.joined(separator: ", ")
        }
        return text
    }

    // MARK: The noun

    /// `any tee time` / `a morning tee time` / `morning tee times`.
    ///
    /// The unfiltered singular is deliberately "any tee time" rather than "a
    /// tee time": with no other clause it has to stand alone as
    /// `Alert me when any tee time opens`.
    static func subject(_ filters: SearchFilters, plural: Bool) -> String {
        let noun = plural ? "tee times" : "tee time"
        let buckets = SearchFilters.TimeOfDay.allCases
            .filter { filters.timesOfDay.contains($0) }
            .map { $0.title.lowercased() }

        guard !buckets.isEmpty else {
            return plural ? noun : "any \(noun)"
        }
        let times = list(buckets)
        return plural ? "\(times) \(noun)" : "\(article(for: times)) \(times) \(noun)"
    }

    // MARK: When

    /// `` / ` today` / ` on Saturday` / ` on Saturday or Sunday` / ` on 4 days`.
    static func dayClause(_ filters: SearchFilters, today: String) -> String {
        guard !filters.days.isEmpty else { return "" }

        if filters.days.count > 3 {
            return " on \(filters.days.count) days"
        }
        let labels = filters.days.sorted().map { dayLabel(for: $0, today: today) }
        // "on today" is not English, so the preposition is dropped as soon as a
        // relative label is in the list: " today or Saturday".
        let relative = labels.contains { $0 == "today" || $0 == "tomorrow" }
        return (relative ? " " : " on ") + list(labels)
    }

    /// `today`, `tomorrow`, or the weekday name. Falls back to the raw
    /// `YYYY-MM-DD` if it will not parse, which is the same thing
    /// `SlotFormatting` does — an unreadable date is still a real watch.
    static func dayLabel(for date: String, today: String) -> String {
        if date == today { return "today" }
        if let tomorrow = SlotFormatting.dayAfter(today), date == tomorrow { return "tomorrow" }
        guard let parsed = dateParser.date(from: date) else { return date }
        return weekdayName.string(from: parsed)
    }

    // MARK: Where

    /// `` / ` at The Coast` / ` at 3 clubs`.
    static func clubClause(_ filters: SearchFilters, courses: [Course]) -> String {
        switch filters.courseSlugs.count {
        case 0:
            return ""
        case 1:
            guard let slug = filters.courseSlugs.first else { return "" }
            guard let course = courses.first(where: { $0.slug == slug }) else {
                // A slug with no course behind it is a stale saved watch, not a
                // reason to lose the club from the sentence.
                return " at \(slug)"
            }
            return " at \(SlotFormatting.shortCourseName(course.name))"
        default:
            return " at \(filters.courseSlugs.count) clubs"
        }
    }

    // MARK: The qualifiers

    /// The trailing comma-separated clauses, in a fixed order so the sentence
    /// reads the same way every time.
    static func qualifiers(_ filters: SearchFilters) -> [String] {
        var extras: [String] = []

        switch filters.holes {
        case .eighteen: break                       // the default, so it is silent
        case .nine: extras.append("9 holes")
        case .any: extras.append("9 or 18 holes")
        }

        if let price = filters.maxPrice {
            extras.append("under \(SlotFormatting.money(price))")
        }
        if filters.players > 1 {
            extras.append("for \(filters.players) players")
        }
        if let minutes = filters.maxDriveMinutes {
            extras.append("within \(minutes) min of Bondi")
        }
        return extras
    }

    // MARK: Grammar

    /// `a` / `b or c` / `a, b or c`. No Oxford comma — this is an Australian
    /// app and the clubs are in Sydney.
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) or \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + " or " + (items.last ?? "")
        }
    }

    /// "an early tee time", "a morning tee time". Only ever sees the five
    /// bucket titles, so a first-letter test is enough.
    static func article(for word: String) -> String {
        guard let first = word.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }

    // MARK: Formatters

    // Pinned to Sydney and en_US_POSIX for the same reason `SlotFormatting` is:
    // a date in this app is a Sydney wall-clock date, and a device set to
    // another region must not change what a saved watch says.
    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = SlotFormatting.sydney
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekdayName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = SlotFormatting.sydney
        f.dateFormat = "EEEE"
        return f
    }()
}
