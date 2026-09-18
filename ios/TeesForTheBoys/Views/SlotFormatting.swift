import Foundation
import TeesContract

/// Wall-clock parsing for the contract's `tee_time`.
///
/// `tee_time` is `HH:MM:SS` — that is how PostgREST renders a Postgres `time`,
/// and the fixtures match it. Parsing is done by hand rather than with a
/// `DateFormatter` because a tee time is a pair of integers, not an instant:
/// turning it into a `Date` would need a time zone and a calendar day, and
/// CONTRACT.md §4 is explicit that the client never resolves either.
enum ViewsWallClock {
    /// Accepts `HH:MM:SS` and, leniently, `HH:MM`. Returns nil for anything
    /// that is not two or three colon-separated numbers in range.
    static func parse(_ teeTime: String) -> (hour: Int, minute: Int)? {
        let parts = teeTime.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return (hour, minute)
    }
}

/// Every string the search screens show, in one place and with no SwiftUI in
/// sight.
///
/// Formatting is the part of a screen worth asserting on — "$55–$110", "2 of 4
/// spots", "Price at course" are product decisions — and `ios/project.yml` is
/// frozen, so there is no ViewInspector and no way to assert on a rendered
/// body. Pushing every string into a pure function is what makes the screens
/// testable at all.
///
/// All formatters are pinned to `en_US_POSIX` and Australia/Sydney. A date in
/// this app is always a Sydney wall-clock date, and a locale-sensitive
/// formatter would make these functions untestable on a device set to another
/// region.
public enum SlotFormatting {

    static let sydney = TimeZone(identifier: "Australia/Sydney") ?? TimeZone(identifier: "UTC")!

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = sydney
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = sydney
        f.dateFormat = "EEE d MMM"
        return f
    }()

    private static let spokenDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = sydney
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    private static var sydneyCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US_POSIX")
        c.timeZone = sydney
        return c
    }()

    // MARK: - Time

    /// `"6:16 am"`. Twelve-hour, no leading zero, lowercase meridiem.
    ///
    /// Falls back to the raw `tee_time` if it will not parse, because a row we
    /// cannot format is still a bookable round (CONTRACT.md §3).
    public static func time(_ slot: Slot) -> String {
        time(teeTime: slot.teeTime)
    }

    /// The same, for callers holding a bare `HH:MM:SS`.
    public static func time(teeTime: String) -> String {
        guard let parts = ViewsWallClock.parse(teeTime) else { return teeTime }
        let meridiem = parts.hour < 12 ? "am" : "pm"
        var hour = parts.hour % 12
        if hour == 0 { hour = 12 }
        return String(format: "%d:%02d %@", hour, parts.minute, meridiem)
    }

    // MARK: - Price

    /// What a slot with no published price says instead of a number.
    ///
    /// 282 of the golden fixture's 1755 slots are in this state — one in six.
    /// It is ordinary data, so the label is plain rather than apologetic.
    public static let priceAtCourse = "Price at course"

    /// `"$55"`, `"$55–$110"`, or `priceAtCourse`.
    public static func price(_ slot: Slot) -> String {
        guard let min = slot.priceMin else { return priceAtCourse }
        guard let max = slot.priceMax, max > min else { return money(min) }
        return "\(money(min))\u{2013}\(money(max))"
    }

    /// The same information as `price`, phrased for VoiceOver. An en dash in
    /// the middle of a currency range is read as a hyphen or skipped entirely.
    public static func priceSpoken(_ slot: Slot) -> String {
        guard let min = slot.priceMin else { return priceAtCourse.lowercased() }
        guard let max = slot.priceMax, max > min else { return money(min) }
        return "from \(money(min)) to \(money(max))"
    }

    /// `$55` for a whole number, `$55.50` otherwise. Club fees are usually
    /// whole dollars and `$55.00` reads like a receipt.
    static func money(_ amount: Double) -> String {
        let rounded = (amount * 100).rounded() / 100
        if abs(rounded.rounded() - rounded) < 0.005 {
            return "$\(Int(rounded.rounded()))"
        }
        return String(format: "$%.2f", rounded)
    }

    // MARK: - The round itself

    /// `"2 of 4 spots"`.
    public static func players(_ slot: Slot) -> String {
        "\(slot.spotsAvailable) of \(slot.totalSpots) spots"
    }

    /// `"18 holes · par 70"`, or just `"18 holes"` when the club publishes no
    /// par. The hole count is the **slot's**, which at Bankstown, Beverley Park
    /// and Brighton Lakes is not the course's.
    public static func holesAndPar(_ slot: Slot) -> String {
        let holes = "\(slot.holes) holes"
        guard let par = slot.par else { return holes }
        return "\(holes) \u{00B7} par \(par)"
    }

    /// `"32 min from Bondi"`, or nil when the drive time is unknown. Nil is a
    /// caller's cue to show nothing, never to show a zero.
    public static func drive(_ slot: Slot) -> String? {
        guard let minutes = slot.driveMinutesFromBondi else { return nil }
        return "\(minutes) min from Bondi"
    }

    // MARK: - Days

    /// `"Today"`, `"Tomorrow"`, else `"Sat 19 Sep"`.
    ///
    /// - Parameters:
    ///   - date: a `tee_date`, `YYYY-MM-DD`.
    ///   - today: the Sydney wall-clock date, which the store derives from its
    ///     injected clock. Passed in rather than read here so every caller in a
    ///     render pass agrees on what "today" is.
    public static func dayTitle(for date: String, today: String) -> String {
        if date == today { return "Today" }
        if let tomorrow = dayAfter(today), date == tomorrow { return "Tomorrow" }
        guard let parsed = dateParser.date(from: date) else { return date }
        return shortDay.string(from: parsed)
    }

    /// `"Saturday 3 October"` — the long form, for VoiceOver. Never relative:
    /// a label read aloud out of context should say which day it means.
    public static func spokenDayTitle(for date: String) -> String {
        guard let parsed = dateParser.date(from: date) else { return date }
        return spokenDay.string(from: parsed)
    }

    /// The calendar day after `date`, in Sydney. The only calendar arithmetic
    /// in the track, and it is on a wall-clock date string — never on `tee_at`.
    public static func dayAfter(_ date: String) -> String? {
        guard let parsed = dateParser.date(from: date),
              let next = sydneyCalendar.date(byAdding: .day, value: 1, to: parsed)
        else { return nil }
        return dateParser.string(from: next)
    }

    // MARK: - Clubs

    /// `"Bayview Golf Club"` → `"Bayview"`.
    ///
    /// Banner and warning copy names a club a dozen times on one screen and the
    /// suffix carries nothing. Only the suffixes the frozen fifteen actually
    /// use are stripped, and a name that ends up empty falls back to the full
    /// one.
    public static func shortCourseName(_ name: String) -> String {
        let suffixes = [
            " Golf Club", " Country Club", " Recreation Club",
            " Golf Links", " Golf Course", " Golf Centre"
        ]
        for suffix in suffixes where name.hasSuffix(suffix) {
            let trimmed = String(name.dropLast(suffix.count))
            return trimmed.isEmpty ? name : trimmed
        }
        return name
    }

    /// Non-nil only when the club makes you create a free account first.
    ///
    /// Bayview is the example in the fixtures. The point is that the surprise
    /// lands here rather than on the club's checkout page.
    public static func registrationNote(for slot: Slot) -> String? {
        guard slot.requiresRegistration else { return nil }
        return "\(shortCourseName(slot.courseName)) needs a free club account before you can book"
    }

    // MARK: - Accessibility

    /// One spoken sentence carrying everything the row shows visually.
    ///
    /// A slot row is six small labels; read one at a time they are noise, so
    /// the row is one accessibility element with this as its label. The
    /// registration warning is appended rather than dropped — it is the one
    /// piece of the row that changes whether a tap is worth making.
    public static func accessibilityLabel(for slot: Slot) -> String {
        var sentence = [
            slot.courseName,
            time(slot),
            spokenDayTitle(for: slot.teeDate),
            holesAndPar(slot).replacingOccurrences(of: " \u{00B7} ", with: ", "),
            priceSpoken(slot),
            players(slot)
        ].joined(separator: ", ")
        sentence += "."
        if let note = registrationNote(for: slot) {
            sentence += " \(note)."
        }
        return sentence
    }
}
