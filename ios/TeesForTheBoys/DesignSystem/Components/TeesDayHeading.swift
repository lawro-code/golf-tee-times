import SwiftUI

/// The `.day-heading` — the rule a results list is divided by.
///
/// A flag at the leading edge, the day in serif deep green, and a short gold
/// underline beneath it. Golfers search by day before anything else, so this is
/// the only landmark in a list that may be two thousand rows long.
///
/// **"Today" and "Tomorrow" before a date.** `docs/app.js` always writes the
/// full day, which is right for a page someone lands on cold and wrong for an
/// app opened at 6am to find a round this morning. Days 0 and 1 are the two the
/// scraper refreshes every twenty minutes, and they are the two a golfer is
/// nearly always looking at.
///
/// **Why the reference date is injectable.** A heading that formats against
/// `Date()` is untestable — "Today" is only "Today" on one day — and this
/// target has no snapshot library to catch it. `Model.init` takes the day it
/// should compare against, defaulting to now, so `TeesDayHeadingTests` can pin
/// it.
///
/// **Time zone.** `tee_date` is the wall-clock calendar date at the course
/// (`CONTRACT.md` §4), so "today" means today in Sydney, not today wherever the
/// phone happens to be. A golfer on a stopover in Singapore still sees the
/// Sydney day.
public struct TeesDayHeading: View {

    /// The formatted day, ready to draw and ready to assert.
    public struct Model: Equatable, Sendable {

        /// `"Today"`, `"Tomorrow"`, or `"Saturday 20 September"`.
        public let title: String

        /// The courses are all in Sydney, and `tee_date` is local to them.
        public static let courseTimeZone = TimeZone(identifier: "Australia/Sydney") ?? .current

        /// The designated initialiser, for previews and tests.
        public init(title: String) {
            self.title = title
        }

        /// Format a `YYYY-MM-DD` tee date relative to a reference day.
        ///
        /// - Parameters:
        ///   - teeDate: the contract's `tee_date` — the wall-clock calendar
        ///     date at the course.
        ///   - reference: the day to call "Today". Defaults to now; pass a
        ///     fixed date in a test.
        ///   - timeZone: the zone both dates are read in. Defaults to Sydney.
        ///
        /// A string that is not a date falls back to itself. A results list
        /// with a raw `2026-09-20` in one heading is readable; one that has
        /// dropped a heading is not.
        public init(teeDate: String, reference: Date = Date(), timeZone: TimeZone = Model.courseTimeZone) {
            self.title = Model.title(for: teeDate, reference: reference, timeZone: timeZone)
        }

        // MARK: - The formatting rules

        /// The day and month names, hard-coded exactly as `docs/app.js`
        /// hard-codes them.
        ///
        /// Not `DateFormatter`: a formatter reads the device locale, so the
        /// same tee date would render "Saturday 20 September" on one phone and
        /// "土曜日" on another, and a test asserting either would be asserting
        /// the simulator's settings. The app is Sydney-only and English-only,
        /// and the website it is a port of already decided this.
        static let weekdayNames = [
            "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
        ]

        static let monthNames = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        ]

        static func title(for teeDate: String, reference: Date, timeZone: TimeZone) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone

            guard let components = parse(teeDate),
                  let day = calendar.date(from: components),
                  let weekday = calendar.dateComponents([.weekday], from: day).weekday,
                  (1 ... 12).contains(components.month ?? 0),
                  (1 ... 7).contains(weekday)
            else {
                return teeDate
            }

            // Whole days between midnights, so a heading does not flip at the
            // wrong moment because one of the two dates carried a time.
            let today = calendar.startOfDay(for: reference)
            let offset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: day)).day

            switch offset {
            case 0: return "Today"
            case 1: return "Tomorrow"
            default:
                let month = Model.monthNames[(components.month ?? 1) - 1]
                return "\(Model.weekdayNames[weekday - 1]) \(components.day ?? 0) \(month)"
            }
        }

        /// `YYYY-MM-DD` → date components. Strict: three numeric parts, a
        /// four-digit year, and ranges that exist. `Calendar` would happily
        /// turn month 13 into next January, which is how a scraper bug becomes
        /// a plausible-looking heading.
        static func parse(_ teeDate: String) -> DateComponents? {
            let parts = teeDate.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  parts[0].count == 4,
                  let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                  (1 ... 12).contains(month), (1 ... 31).contains(day)
            else {
                return nil
            }
            return DateComponents(year: year, month: month, day: day)
        }
    }

    private let model: Model

    public init(model: Model) {
        self.model = model
    }

    /// Convenience for the common case — a heading straight off a tee date.
    public init(teeDate: String, reference: Date = Date()) {
        self.init(model: Model(teeDate: teeDate, reference: reference))
    }

    /// `.day-flag` is 22px, and it scales with the heading beside it.
    @ScaledMetric(relativeTo: .title2) private var glyphSize: CGFloat = 22

    /// `.day-heading::after` is `width: 40px; height: 2px`.
    ///
    /// There is no 2pt stroke token — `TeesStroke.underline` is 3 and belongs
    /// to the active tab — and a 40pt rule length is this ornament's alone.
    /// Both are flagged to the D lead as candidate tokens; neither is a colour
    /// or a type value.
    @ScaledMetric(relativeTo: .title2) private var ruleWidth: CGFloat = 40
    @ScaledMetric(relativeTo: .title2) private var ruleHeight: CGFloat = 2

    public var body: some View {
        VStack(alignment: .leading, spacing: TeesSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: TeesSpacing.sm) {
                TeesFlagGlyph()
                    .fill(TeesColor.green)
                    .frame(width: glyphSize, height: glyphSize)
                    // The glyph is decoration; the heading text says the day.
                    .accessibilityHidden(true)
                    // Baseline-aligned inside a row of text, a fixed-size shape
                    // has no baseline of its own, so it is nudged onto the
                    // text's instead of floating above it.
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }

                Text(verbatim: model.title)
                    .font(TeesFont.heading)
                    .foregroundStyle(TeesColor.greenDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle()
                .fill(TeesColor.gold)
                .frame(width: ruleWidth, height: ruleHeight)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - The flag

/// The `#i-flag` symbol from `docs/index.html`, redrawn as a fillable path.
///
/// One `Shape` rather than an SF Symbol because this mark is the site's crest —
/// it is on the masthead, the day headings and the submit button — and an
/// approximation of it would be the first thing to make the app stop looking
/// like the website. The SVG strokes the pole and fills the pennant; a shape
/// can only do one, so the pole is drawn as a rounded 1.6-wide bar, which is
/// what a 1.6 round-capped stroke renders as anyway.
private struct TeesFlagGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // The symbol's own 24x24 viewBox, scaled to fit and centred.
        let scale = min(rect.width, rect.height) / 24
        let originX = rect.minX + (rect.width - 24 * scale) / 2
        let originY = rect.minY + (rect.height - 24 * scale) / 2

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()

        // The pole: M5 21 V3, stroke-width 1.6, round caps.
        path.addRoundedRect(
            in: CGRect(
                x: originX + 4.2 * scale, y: originY + 3 * scale,
                width: 1.6 * scale, height: 18 * scale),
            cornerSize: CGSize(width: 0.8 * scale, height: 0.8 * scale))

        // The pennant: M5 4 L19 7.5 L5 11 Z.
        path.move(to: point(5, 4))
        path.addLine(to: point(19, 7.5))
        path.addLine(to: point(5, 11))
        path.closeSubpath()

        // The foot: a circle at (5, 21), r 1.4.
        path.addEllipse(
            in: CGRect(
                x: originX + 3.6 * scale, y: originY + 19.6 * scale,
                width: 2.8 * scale, height: 2.8 * scale))

        return path
    }
}

// MARK: - Previews

#Preview("Day headings") {
    VStack(alignment: .leading, spacing: TeesSpacing.xl) {
        TeesDayHeading(model: .init(title: "Today"))
        TeesDayHeading(model: .init(title: "Tomorrow"))
        TeesDayHeading(model: .init(title: "Saturday 20 September"))
    }
    .padding(TeesSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(TeesColor.background)
}
