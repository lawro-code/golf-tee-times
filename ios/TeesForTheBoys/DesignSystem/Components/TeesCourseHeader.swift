import SwiftUI
import TeesContract

/// The `.course-header` — the name of a club and the three facts that decide
/// whether a golfer reads the rows underneath it.
///
/// Serif name leading, a tracked-caps meta run trailing, a hairline underneath:
/// `32 min from Bondi · 18 holes · Northern Beaches`. The drive time comes
/// first because that is the filter golfers actually apply — a course an hour
/// away is not a course, whatever it costs.
///
/// **No map link.** `docs/app.js` appends one to the meta run; this does not.
/// Opening Maps is navigation, navigation is a screen's decision, and screens
/// are track C's. A design-system component that reaches out to `UIApplication`
/// cannot be previewed, cannot be tested and cannot be reused in a sheet.
public struct TeesCourseHeader: View {

    /// Everything the header draws.
    ///
    /// `metaSegments` is an array rather than a joined string so the view can
    /// draw the separators in gold — `.course-meta-divider` is its own colour —
    /// and so a test can assert that a missing source drops its segment
    /// cleanly instead of leaving a dangling `·`.
    public struct Model: Equatable, Sendable {

        /// The club's name, as the club writes it.
        public let name: String

        /// Between zero and three facts, in stylesheet order: drive time,
        /// holes, region. Any segment whose source is nil is absent — never
        /// an empty string, which would render as a separator with nothing
        /// either side of it.
        public let metaSegments: [String]

        /// The club requires a free public-member registration before it will
        /// take a booking.
        public let requiresRegistration: Bool

        /// The designated initialiser, for previews, tests, and a caller
        /// composing a header from something that is not a contract type.
        public init(name: String, metaSegments: [String], requiresRegistration: Bool) {
            self.name = name
            self.metaSegments = metaSegments
            self.requiresRegistration = requiresRegistration
        }

        /// The full header. `Course` is the only type that knows the course's
        /// own hole count, so this is the initialiser that can draw all three
        /// segments.
        public init(course: Course) {
            self.name = course.name
            self.requiresRegistration = course.requiresRegistration
            self.metaSegments = Model.metaSegments(
                driveMinutes: course.driveMinutesFromBondi,
                holes: course.holes,
                region: course.region)
        }

        /// A header built from a slot, for a list that groups by slot and does
        /// not have the `Course` to hand.
        ///
        /// **The holes segment is deliberately absent here.** `slot.holes` is
        /// THE BOOKING's hole count, not the club's — Bankstown, Beverley Park
        /// and Brighton Lakes are 18-hole courses selling 9-hole tee times
        /// (`CONTRACT.md` §2). Putting a booking's 9 into a course header would
        /// label an 18-hole club as a 9-hole one, and which label it got would
        /// depend on whichever slot happened to build the header. The slot
        /// payload carries no course hole count, so the segment drops — which
        /// is exactly what `metaSegments` is built to do.
        public init(slot: Slot) {
            self.name = slot.courseName
            self.requiresRegistration = slot.requiresRegistration
            self.metaSegments = Model.metaSegments(
                driveMinutes: slot.driveMinutesFromBondi,
                holes: nil,
                region: slot.region)
        }

        /// The port of `buildCourseMeta` in `docs/app.js`, minus the map link.
        ///
        /// Each fact appends only if it has a source. Blank-but-present
        /// strings — a region of `""` from a club we have not filled in — are
        /// dropped too, because a separator either side of nothing is the
        /// dangling `·` this function exists to prevent.
        static func metaSegments(driveMinutes: Int?, holes: Int?, region: String?) -> [String] {
            var segments: [String] = []

            if let driveMinutes {
                segments.append("\(driveMinutes) min from Bondi")
            }
            if let holes, holes > 0 {
                segments.append("\(holes) holes")
            }
            if let region {
                let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    segments.append(trimmed)
                }
            }

            return segments
        }

        /// The meta run as one string, separators included. Not used to render
        /// anything — the view builds a coloured run instead — but it is what a
        /// test reads to prove there is no stray separator, and what track C
        /// can fold into a larger spoken sentence.
        public var metaDescription: String {
            metaSegments.joined(separator: " \(TeesSlotRow.Model.separator) ")
        }
    }

    private let model: Model

    public init(model: Model) {
        self.model = model
    }

    /// Convenience for the common cases.
    public init(course: Course) {
        self.init(model: Model(course: course))
    }

    public init(slot: Slot) {
        self.init(model: Model(slot: slot))
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ScaledMetric(relativeTo: .caption) private var markerDiameter: CGFloat = 6

    public var body: some View {
        VStack(alignment: .leading, spacing: TeesSpacing.xs) {
            heading
            // `border-bottom: 1px solid var(--hairline)`.
            Rectangle()
                .fill(TeesColor.hairline)
                .frame(height: TeesStroke.hairline)
                .accessibilityHidden(true)
        }
        // The name and its meta are one thought, and VoiceOver should read
        // them as one. Children are combined rather than ignored so the meta
        // run still reaches a screen reader.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// `.course-header` is `flex-wrap` with the name leading and the meta
    /// trailing. Wrapping in SwiftUI is a decision rather than a default, so
    /// the meta run drops beneath the name once the text is big enough that
    /// the two cannot share a line.
    @ViewBuilder
    private var heading: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TeesSpacing.xs) {
                name
                meta
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: TeesSpacing.sm) {
                name
                Spacer(minLength: TeesSpacing.sm)
                meta
            }
        }
    }

    private var name: some View {
        Text(verbatim: model.name)
            .font(TeesFont.courseName)
            .foregroundStyle(TeesColor.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var meta: some View {
        HStack(alignment: .firstTextBaseline, spacing: TeesSpacing.xs) {
            if model.requiresRegistration {
                // The same gold dot the slot row uses, meaning the same thing.
                Circle()
                    .fill(TeesColor.gold)
                    .frame(width: markerDiameter, height: markerDiameter)
                    .accessibilityHidden(true)
            }

            if !model.metaSegments.isEmpty {
                metaRun
                    .teesMeta()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The segments as one `Text`, with gold separators.
    ///
    /// Built by concatenating `Text` runs because that is the only way to give
    /// one word inside a line its own colour. A run's own `foregroundStyle`
    /// survives the view-level one that `teesMeta()` applies, so the words stay
    /// muted and the dividers stay gold — `.course-meta-divider` in
    /// `docs/style.css`.
    private var metaRun: Text {
        var run = Text(verbatim: "")
        for (index, segment) in model.metaSegments.enumerated() {
            if index > 0 {
                run = run + Text(verbatim: " \(TeesSlotRow.Model.separator) ")
                    .foregroundStyle(TeesColor.gold)
            }
            run = run + Text(verbatim: segment)
        }
        return run
    }
}

// MARK: - Previews

#Preview("Course headers") {
    VStack(alignment: .leading, spacing: TeesSpacing.xl) {
        TeesCourseHeader(model: .init(
            name: "Warringah Golf Club",
            metaSegments: ["32 min from Bondi", "18 holes", "Northern Beaches"],
            requiresRegistration: false))

        TeesCourseHeader(model: .init(
            name: "The Coast Golf Club",
            metaSegments: ["18 holes", "Eastern Suburbs"],
            requiresRegistration: true))

        TeesCourseHeader(model: .init(
            name: "Bexley Golf Club",
            metaSegments: [],
            requiresRegistration: false))
    }
    .padding(TeesSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(TeesColor.background)
}
