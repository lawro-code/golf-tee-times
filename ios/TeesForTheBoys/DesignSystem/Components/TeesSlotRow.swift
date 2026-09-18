import SwiftUI
import TeesContract

/// The `.slot` card — one bookable tee time.
///
/// This is the product. A golfer scrolling the results sees hundreds of these
/// and almost nothing else, so the row carries the four facts that decide
/// whether a tee time is worth tapping — when, how many spots, what kind of
/// round, what it costs — and nothing else.
///
/// **Why the model is a bag of pre-formatted strings.** No snapshot or
/// view-inspection library is available here (`ios/project.yml` is frozen, so
/// an SPM package cannot be added), which means anything computed inside
/// `body` is untestable. Every rule below — 12-hour time, singular "1 spot",
/// an omitted par — is therefore decided in `Model.init(slot:)` and asserted by
/// `TeesSlotRowTests`. The view only draws.
///
/// **Two rules the live data paid for:**
///
/// - `slot.teeTime` is `HH:MM:SS`, not `HH:MM`. That is how PostgREST renders
///   a Postgres `time`, and a two-component parse turns `06:16:00` into
///   nonsense. `CONTRACT.md` §"Serialisation details".
/// - `slot.holes` is THE BOOKING's hole count, never the course's. Bankstown,
///   Beverley Park and Brighton Lakes are 18-hole courses selling 9-hole tee
///   times — 125 slots in the golden fixture. Substituting `course.holes` here
///   shows a golfer 18 holes when the club is selling 9. `CONTRACT.md` §2.
public struct TeesSlotRow: View {

    /// Everything the row draws and everything it says.
    public struct Model: Equatable, Sendable {

        /// `"6:16 am"` — 12-hour, lowercase meridiem, as `docs/app.js` sets it.
        public let time: String

        /// `"2 spots"`, or `"1 spot"`. The singular is not cosmetic: one spot
        /// left is the most urgent state a row has.
        public let spotsLabel: String

        /// `"18 holes · Par 70"`. Par and holes are both on the slot display
        /// per BUILD-PLAN; par is dropped when the club does not publish one.
        public let detailLabel: String

        /// The formatted price. See `TeesPriceTierBadge.Model`.
        public let price: TeesPriceTierBadge.Model

        /// The club requires a free public-member registration before it will
        /// take a booking. Marked so that tapping through to MiClub and being
        /// asked to sign up is not a surprise.
        public let requiresRegistration: Bool

        /// One spoken sentence: time, detail, spots, price. The row is a single
        /// accessibility element, so this is the whole announcement — VoiceOver
        /// never reads the individual labels.
        public let accessibilityLabel: String

        /// The designated initialiser, for previews, tests and any caller
        /// composing a row from something that is not a `Slot`.
        public init(
            time: String,
            spotsLabel: String,
            detailLabel: String,
            price: TeesPriceTierBadge.Model,
            requiresRegistration: Bool,
            accessibilityLabel: String
        ) {
            self.time = time
            self.spotsLabel = spotsLabel
            self.detailLabel = detailLabel
            self.price = price
            self.requiresRegistration = requiresRegistration
            self.accessibilityLabel = accessibilityLabel
        }

        /// Format one slot for display.
        public init(slot: Slot) {
            let time = Model.formattedTime(slot.teeTime)
            let spots = Model.spotsLabel(slot.spotsAvailable)
            let segments = Model.detailSegments(holes: slot.holes, par: slot.par)
            let price = TeesPriceTierBadge.Model(slot: slot)

            self.time = time
            self.spotsLabel = spots
            self.detailLabel = segments.joined(separator: " \(Model.separator) ")
            self.price = price
            self.requiresRegistration = slot.requiresRegistration

            // Commas, not the gold middot: VoiceOver reads "·" aloud as
            // "middle dot" or swallows it, and either way the pause a comma
            // buys is what makes the sentence land.
            var spoken: [String] = [time]
            spoken.append(contentsOf: segments)
            spoken.append(spots)
            spoken.append(price.spokenDescription)
            if slot.requiresRegistration {
                spoken.append(Model.registrationSpoken)
            }
            self.accessibilityLabel = spoken.joined(separator: ", ")
        }

        // MARK: - The formatting rules

        /// The gold `·` between detail segments, matching
        /// `.course-meta-divider` in `docs/style.css`.
        static let separator = "·"

        /// What VoiceOver says in place of the gold registration marker, which
        /// a screen reader cannot see.
        static let registrationSpoken = "free registration required"

        /// `HH:MM:SS` → `"6:16 am"`.
        ///
        /// Three components, not two. Seconds are always `00` in the contract
        /// but they are always *present*, and `Int("16:00")` is `nil`.
        ///
        /// Midnight and noon are where 12-hour formatting breaks, so they are
        /// written out rather than left to `%`: hour 0 is 12 am and hour 12 is
        /// 12 pm. An unparseable string falls back to itself — a raw
        /// `06:16:00` on screen is ugly, a crash or a blank row is worse.
        static func formattedTime(_ raw: String) -> String {
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 2,
                  let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0 ... 23).contains(hour), (0 ... 59).contains(minute)
            else {
                return raw
            }

            let meridiem = hour < 12 ? "am" : "pm"
            let hour12 = hour % 12 == 0 ? 12 : hour % 12
            let paddedMinute = minute < 10 ? "0\(minute)" : "\(minute)"
            return "\(hour12):\(paddedMinute) \(meridiem)"
        }

        /// `"1 spot"` / `"2 spots"`.
        static func spotsLabel(_ spots: Int) -> String {
            spots == 1 ? "1 spot" : "\(spots) spots"
        }

        /// `["18 holes", "Par 70"]`, or just `["9 holes"]` when the club
        /// publishes no par.
        ///
        /// A nil par drops the segment entirely rather than printing "Par nil"
        /// or, worse, "Par 0" — which reads like a real number and is not one.
        static func detailSegments(holes: Int, par: Int?) -> [String] {
            var segments = ["\(holes) holes"]
            if let par, par > 0 {
                segments.append("Par \(par)")
            }
            return segments
        }
    }

    private let model: Model
    private let onTap: (() -> Void)?

    public init(model: Model, onTap: (() -> Void)? = nil) {
        self.model = model
        self.onTap = onTap
    }

    /// Convenience for the common case — a row straight off a slot.
    public init(slot: Slot, onTap: (() -> Void)? = nil) {
        self.init(model: Model(slot: slot), onTap: onTap)
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The registration dot scales with the text beside it, or it turns into a
    /// speck at accessibility sizes.
    @ScaledMetric(relativeTo: .caption) private var markerDiameter: CGFloat = 6

    public var body: some View {
        card
            .contentShape(shape)
            // One element, one sentence. Without `.ignore` VoiceOver reads
            // four separate labels and a golfer swiping a list of 200 rows
            // hears 800 fragments.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .modifier(TeesTapAction(action: onTap))
    }

    // MARK: - The card

    private var card: some View {
        layout
            .padding(.leading, TeesSpacing.lg)
            .padding(.trailing, TeesSpacing.md)
            .padding(.vertical, TeesSpacing.md)
            .frame(maxWidth: .infinity, minHeight: TeesLayout.minTapTarget, alignment: .leading)
            .background(TeesColor.surface)
            // `border-left: 3px solid var(--green)` — the bar that makes a row
            // read as a line on a scorecard rather than an item in a list.
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(TeesColor.leadingRule)
                    .frame(width: TeesStroke.leadingRule)
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(TeesColor.hairline, lineWidth: TeesStroke.hairline) }
            .teesShadow(.card)
    }

    /// Time and price sit on one line until the text gets big enough that they
    /// would fight, then the price drops underneath. The alternative — letting
    /// them share a cramped row — truncates the time, and the time is the one
    /// thing on the card that must never be guessed at.
    @ViewBuilder
    private var layout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TeesSpacing.sm) {
                details
                TeesPriceTierBadge(model: model.price)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: TeesSpacing.sm) {
                details
                Spacer(minLength: TeesSpacing.sm)
                TeesPriceTierBadge(model: model.price)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: TeesSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: TeesSpacing.xs) {
                Text(verbatim: model.time)
                    .font(TeesFont.slotTime)
                    .foregroundStyle(TeesColor.ink)
                    // No `minimumScaleFactor` anywhere near this: the time
                    // wraps to a second line at accessibility sizes rather
                    // than shrinking, and `fixedSize` stops a parent squeezing
                    // the wrap back out.
                    .fixedSize(horizontal: false, vertical: true)

                if model.requiresRegistration {
                    registrationMarker
                }
            }

            Text(verbatim: model.spotsLabel).teesMeta()
            Text(verbatim: model.detailLabel).teesMeta()
        }
    }

    /// A small gold dot. Deliberately a mark and not a word: the row has room
    /// for four facts and "registration required" is not one of them. The
    /// words are in `accessibilityLabel`, and the screen that opens on tap —
    /// track C's — explains it in full before anyone reaches MiClub.
    private var registrationMarker: some View {
        Circle()
            .fill(TeesColor.gold)
            .frame(width: markerDiameter, height: markerDiameter)
            .accessibilityHidden(true)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TeesRadius.sharp, style: .continuous)
    }
}

// MARK: - Tap

/// Applies a tap gesture only when there is something to call.
///
/// A row with no handler must not swallow taps — track C composes these into
/// scrolling lists, and an always-on `onTapGesture` with an empty closure eats
/// the gesture a parent was waiting for.
private struct TeesTapAction: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

// MARK: - Previews

#Preview("Slot rows") {
    VStack(spacing: TeesSpacing.sm) {
        TeesSlotRow(model: .init(
            time: "6:16 am",
            spotsLabel: "2 spots",
            detailLabel: "18 holes · Par 70",
            price: .init(headline: "$48", secondary: nil, isTwilight: false, isUnknown: false),
            requiresRegistration: false,
            accessibilityLabel: "6:16 am, 18 holes, Par 70, 2 spots, $48"))

        TeesSlotRow(model: .init(
            time: "1:42 pm",
            spotsLabel: "1 spot",
            detailLabel: "9 holes",
            price: .init(headline: "$28", secondary: "or $45 Social", isTwilight: true, isUnknown: false),
            requiresRegistration: true,
            accessibilityLabel: "1:42 pm, 9 holes, 1 spot, $28, or $45 Social, free registration required"))

        TeesSlotRow(model: .init(
            time: "12:00 pm",
            spotsLabel: "4 spots",
            detailLabel: "18 holes · Par 72",
            price: .init(
                headline: TeesPriceTierBadge.Model.unknownHeadline,
                secondary: nil, isTwilight: false, isUnknown: true),
            requiresRegistration: false,
            accessibilityLabel: "12:00 pm, 18 holes, Par 72, 4 spots, price at course"))
    }
    .padding(TeesSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(TeesColor.background)
}
