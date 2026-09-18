import SwiftUI
import TeesContract

/// The `.slot-price` / `.slot-price-extra` pair, and the one place in track D
/// that decides what a tee time costs.
///
/// **Why price presentation is a component and not a helper on `Slot`.** Every
/// price rule in `CONTRACT.md §3` is a *display* rule — round to whole dollars,
/// cheapest first, strip the year off the label, say "Price at course" when
/// there is no fee published. None of that belongs in the contract type, which
/// is the wire shape and is frozen. Putting it in one component means the slot
/// row, the detail screen and anything track C builds later all round the same
/// way, and there is exactly one file to read when a price looks wrong.
///
/// **The rule that matters most.** 282 of the 1755 slots in the golden fixture
/// — Warringah's whole sheet and most of Bexley's — publish no fee at all.
/// `price_min` is null and `price_tiers` is empty, and that is ordinary data,
/// not an error. `isUnknown` renders "Price at course" in muted ink. It is
/// never hidden, never blank, and never "$0": hiding 17% of the inventory is a
/// worse failure than showing a round whose price we do not know.
///
/// The logic lives on `Model`, which is a plain value, because this target has
/// no snapshot or view-inspection library — `ios/project.yml` is frozen, so an
/// SPM package cannot be added. A rule buried in `body` could not be tested at
/// all. `TeesPriceTierBadgeTests` asserts the model.
public struct TeesPriceTierBadge: View {

    /// The formatted price, ready to draw and ready to assert.
    public struct Model: Equatable, Sendable {

        /// What the golfer reads first: `"$48"`, or `"Price at course"` when
        /// the club publishes no fee.
        public let headline: String

        /// The second, quieter line — `"or $35 Twilight"` — present only when
        /// the slot carries more than one tier. `nil` otherwise.
        public let secondary: String?

        /// The cheapest tier is a twilight rate, so the headline is drawn in
        /// `TeesColor.priceTwilight` rather than `TeesColor.price`.
        public let isTwilight: Bool

        /// No fee is published. Ordinary data — see the type's note.
        public let isUnknown: Bool

        /// What an unpriced slot says. A constant rather than a literal at the
        /// call site so the test and the view cannot drift apart.
        public static let unknownHeadline = "Price at course"

        /// The designated initialiser, for a caller that has already formatted
        /// the strings — previews, tests, and track C composing a badge from
        /// something that is not a `Slot`.
        public init(headline: String, secondary: String?, isTwilight: Bool, isUnknown: Bool) {
            self.headline = headline
            self.secondary = secondary
            self.isTwilight = isTwilight
            self.isUnknown = isUnknown
        }

        /// Apply `CONTRACT.md §3` and `docs/app.js` to one slot.
        ///
        /// The order is deliberate: tiers first (they are richer than
        /// `price_min` and carry the label the secondary line needs), then a
        /// bare `price_min` if a club ever sends one without tiers, then the
        /// unknown case.
        public init(slot: Slot) {
            // Sorted ascending, with a label tie-break so two tiers at the
            // same amount cannot swap places between runs. Swift's sort is not
            // stable, and an unstable cheapest tier would flip `isTwilight`.
            let tiers = slot.priceTiers.sorted { left, right in
                left.amount == right.amount ? left.label < right.label : left.amount < right.amount
            }

            if let cheapest = tiers.first {
                self.headline = Model.wholeDollars(cheapest.amount)
                self.isTwilight = Model.isTwilightLabel(cheapest.label)
                self.isUnknown = false

                // More than one tier: show the dearest as the alternative, the
                // way `docs/app.js` does. One tier needs no "or" line.
                if tiers.count > 1, let dearest = tiers.last {
                    let amount = Model.wholeDollars(dearest.amount)
                    let label = Model.strippingTrailingYear(dearest.label)
                    self.secondary = label.isEmpty ? "or \(amount)" : "or \(amount) \(label)"
                } else {
                    self.secondary = nil
                }
            } else if let minimum = slot.priceMin {
                // Tiers empty but a minimum published. Not a shape the golden
                // fixture contains, but the contract allows it and showing the
                // number we have beats claiming we have none.
                self.headline = Model.wholeDollars(minimum)
                self.secondary = nil
                self.isTwilight = false
                self.isUnknown = false
            } else {
                self.headline = Model.unknownHeadline
                self.secondary = nil
                self.isTwilight = false
                self.isUnknown = true
            }
        }

        // MARK: - The formatting rules

        /// `$48`, never `$48.00`. `docs/app.js` uses `Math.round`, which
        /// rounds a half up; `Double.rounded()` rounds a half away from zero,
        /// and prices are positive, so the two agree.
        ///
        /// The finite guard is not defensive theatre — `Int(_:)` traps on NaN
        /// and on anything past `Int.max`, and a decoder that accepts a
        /// `numeric` sent as a string is one bad club response away from
        /// either.
        static func wholeDollars(_ amount: Double) -> String {
            guard amount.isFinite else { return Model.unknownHeadline }
            let rounded = amount.rounded()
            guard rounded.magnitude < 1_000_000_000 else { return Model.unknownHeadline }
            return "$\(Int(rounded))"
        }

        /// `/twilight/i` from `docs/app.js`. Clubs write it "Twilight",
        /// "TWILIGHT" and "Twilight Rate", so the match is case-insensitive
        /// and unanchored.
        static func isTwilightLabel(_ label: String) -> Bool {
            label.range(of: "twilight", options: .caseInsensitive) != nil
        }

        /// The port of `label.replace(/\s*\d{4}\s*$/, '').trim()`.
        ///
        /// MiClub fee labels carry the season on the end — "Social Twilight
        /// 2026" — and the year is noise next to a price. Anchored at the end
        /// and unbounded on the left exactly as the JavaScript is, so the two
        /// surfaces strip the same labels.
        static func strippingTrailingYear(_ label: String) -> String {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let year = trimmed.range(of: "\\s*[0-9]{4}\\s*$", options: .regularExpression) else {
                return trimmed
            }
            return String(trimmed[trimmed.startIndex ..< year.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// The price as one spoken phrase, for a row that folds its whole
        /// contents into a single accessibility element.
        ///
        /// Lower-cased on the unknown headline because VoiceOver reads it
        /// mid-sentence, after the time and the spots.
        public var spokenDescription: String {
            guard !isUnknown else { return Model.unknownHeadline.lowercased() }
            guard let secondary else { return headline }
            return "\(headline), \(secondary)"
        }
    }

    private let model: Model

    public init(model: Model) {
        self.model = model
    }

    /// Convenience for the common case — a badge straight off a slot.
    public init(slot: Slot) {
        self.init(model: Model(slot: slot))
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: TeesSpacing.xxs) {
            headlineText

            if let secondary = model.secondary {
                // `.slot-price-extra`: uppercase, tracked, muted — the same
                // treatment the stylesheet gives it, and `teesMeta()` already
                // owns the tracking maths across Dynamic Type.
                Text(verbatim: secondary)
                    .teesMeta()
                    .multilineTextAlignment(.trailing)
            }
        }
        // Never shrink a price to fit. At an accessibility size it wraps;
        // a scaled-down dollar figure next to full-size body text reads as a
        // rendering bug.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// An unpriced slot borrows the meta treatment rather than the serif price
    /// face: "PRICE AT COURSE" set in muted tracked caps says *this is a note*,
    /// where "Price at course" in the same bold serif as "$48" would read as
    /// the price itself.
    @ViewBuilder
    private var headlineText: some View {
        if model.isUnknown {
            Text(verbatim: model.headline)
                .teesMeta()
                .multilineTextAlignment(.trailing)
        } else {
            Text(verbatim: model.headline)
                .font(TeesFont.price)
                .foregroundStyle(model.isTwilight ? TeesColor.priceTwilight : TeesColor.price)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Previews

#Preview("Price tiers") {
    VStack(alignment: .trailing, spacing: TeesSpacing.lg) {
        TeesPriceTierBadge(model: .init(headline: "$48", secondary: nil, isTwilight: false, isUnknown: false))
        TeesPriceTierBadge(model: .init(headline: "$35", secondary: "or $62 Weekend", isTwilight: false, isUnknown: false))
        TeesPriceTierBadge(model: .init(headline: "$28", secondary: "or $48 Social", isTwilight: true, isUnknown: false))
        TeesPriceTierBadge(model: .init(
            headline: TeesPriceTierBadge.Model.unknownHeadline,
            secondary: nil, isTwilight: false, isUnknown: true))
    }
    .padding(TeesSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    .background(TeesColor.background)
}
