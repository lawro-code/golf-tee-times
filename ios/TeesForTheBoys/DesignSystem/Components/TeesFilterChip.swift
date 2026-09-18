import SwiftUI

/// The pill from `.filter select` and `.lb-tab`.
///
/// Search is the product, so this is the control a golfer touches more than
/// anything else in the app. Two jobs, one shape:
///
/// - `.selector` is a `.filter select` — it shows the CHOSEN VALUE and a
///   chevron. The visible text is "18", not "Holes", because the row of chips
///   reads as a sentence of current settings rather than a form.
/// - `.toggle` is an `.lb-tab` — on or off, and the label is the text.
///
/// **Why the accessibility strings are on the model rather than derived in the
/// body.** The visible text of a selector is just its value, so VoiceOver on
/// the rendered label alone would announce "18" and a golfer would have no
/// idea which filter they had landed on. The model therefore carries an
/// `accessibilityLabel` naming the filter ("Holes") and an
/// `accessibilityValue` holding the value ("18"), which is the same split
/// UIKit's own pickers use: VoiceOver reads "Holes, 18, button, selected".
/// Making them stored properties also means the strings can be asserted on
/// without a view-inspection library, which this repo does not have.
public struct TeesFilterChip: View {

    /// Which of the two pills this is.
    ///
    /// `selector` shows a chevron and a value; `toggle` is on/off.
    public enum Style: Sendable {
        case selector
        case toggle
    }

    /// Everything the chip draws and everything it says. Value type, so a
    /// caller can hold an array of these in state and diff them.
    public struct Model: Equatable, Sendable {

        /// What the filter is: "Holes". Spoken, and shown when there is no
        /// value to show instead.
        public let label: String

        /// The current setting: "18". `nil` for a toggle, which has no value
        /// beyond its own on/off state.
        public let value: String?

        /// Selected chips invert to the accent ground.
        public let isSelected: Bool

        /// What VoiceOver announces first — the filter, not its value.
        public let accessibilityLabel: String

        /// What VoiceOver announces as the current setting. `nil` when there
        /// is nothing to announce, which is every toggle: a toggle's state is
        /// already carried by the `.isSelected` trait, and a value of "on"
        /// on top of that is just noise.
        public let accessibilityValue: String?

        /// The designated initialiser, for a caller that wants to write the
        /// spoken strings itself.
        public init(
            label: String,
            value: String?,
            isSelected: Bool,
            accessibilityLabel: String,
            accessibilityValue: String?
        ) {
            self.label = label
            self.value = value
            self.isSelected = isSelected
            self.accessibilityLabel = accessibilityLabel
            self.accessibilityValue = accessibilityValue
        }

        /// A `.filter select` chip: names a filter and shows its current value.
        ///
        /// VoiceOver reads "Holes, 18, button" — and "…, selected" when this
        /// filter is doing something to the results.
        public static func selector(
            label: String,
            value: String,
            isSelected: Bool = false
        ) -> Model {
            Model(
                label: label,
                value: value,
                isSelected: isSelected,
                accessibilityLabel: label,
                accessibilityValue: value)
        }

        /// An `.lb-tab` chip: on or off, no value.
        public static func toggle(label: String, isOn: Bool = false) -> Model {
            Model(
                label: label,
                value: nil,
                isSelected: isOn,
                accessibilityLabel: label,
                accessibilityValue: nil)
        }

        /// Label and value in the order VoiceOver speaks them.
        ///
        /// Not used to render anything — it exists so a test can assert that
        /// the pair a golfer actually hears carries both the filter and its
        /// setting, which is the whole point of splitting them.
        public var spokenDescription: String {
            [accessibilityLabel, accessibilityValue]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }

        /// The text drawn in the pill. A selector shows its value — the chip
        /// row reads "18 · Morning · Under $60" — and falls back to the label
        /// when it has no value yet. A toggle shows its label.
        var displayText: String {
            guard let value, !value.isEmpty else { return label }
            return value
        }
    }

    private let model: Model
    private let style: Style
    private let action: () -> Void

    public init(model: Model, style: Style = .selector, action: @escaping () -> Void) {
        self.model = model
        self.style = style
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: TeesSpacing.xs) {
                Text(model.displayText)
                    .font(TeesFont.control)
                    // No line limit and no truncation: at an accessibility
                    // size the pill is allowed to grow and wrap rather than
                    // clip its label. `fixedSize` vertically stops a parent
                    // from squeezing the wrapped text back to one line.
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                if style == .selector {
                    // The `.filter select` chevron — the stylesheet draws a
                    // 10x6 down-chevron into the field's background. An SF
                    // Symbol is the same mark and costs no resources phase.
                    Image(systemName: "chevron.down")
                        .font(TeesFont.control)
                        .imageScale(.small)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, TeesSpacing.lg)
            .padding(.vertical, TeesSpacing.sm)
            .frame(minHeight: TeesLayout.minTapTarget)
            .background(shape.fill(ground))
            .overlay(shape.strokeBorder(border, lineWidth: TeesStroke.hairline))
            .contentShape(shape)
        }
        // Plain, so the system tint does not repaint a label whose colour is
        // the entire point of the selected state.
        .buttonStyle(.plain)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityValue(accessibilityValueText)
        .accessibilityAddTraits(traits)
    }

    // MARK: - Shape

    /// `TeesRadius.pill` rather than `Capsule()` so the chip is visibly built
    /// from the same token as every other pill in the system; at 999 the
    /// radius clamps to half the height, which is a capsule.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TeesRadius.pill, style: .continuous)
    }

    // MARK: - Colour
    //
    // Both states are semantic tokens and nothing here is a literal. The
    // selected pairing is the `.lb-tab.active` inversion: accent ground,
    // page-coloured text. `accent` is royal green in light and bright gold in
    // dark, and `background` is cream in light and near-black green in dark,
    // so the inversion holds in both schemes rather than only the one it was
    // drawn in. `TeesFilterChipTests` measures it.

    private var ground: Color {
        model.isSelected ? TeesColor.accent : TeesColor.surface
    }

    private var foreground: Color {
        model.isSelected ? TeesColor.background : TeesColor.ink
    }

    private var border: Color {
        model.isSelected ? TeesColor.accent : TeesColor.hairlineStrong
    }

    // MARK: - Accessibility

    /// An empty `Text` is announced as nothing, which is what a toggle wants;
    /// a conditional modifier would change the view's type for no gain.
    private var accessibilityValueText: Text {
        guard let value = model.accessibilityValue, !value.isEmpty else { return Text(verbatim: "") }
        return Text(verbatim: value)
    }

    /// `.isButton` is stated rather than left to `Button` because the selected
    /// trait is the thing a golfer navigating by VoiceOver needs, and the two
    /// belong in one place.
    private var traits: AccessibilityTraits {
        model.isSelected ? [.isButton, .isSelected] : [.isButton]
    }
}

// MARK: - Previews

#Preview("Filter chips") {
    VStack(alignment: .leading, spacing: TeesSpacing.md) {
        HStack(spacing: TeesSpacing.sm) {
            TeesFilterChip(model: .selector(label: "Holes", value: "18", isSelected: true)) {}
            TeesFilterChip(model: .selector(label: "Time", value: "Morning")) {}
        }
        HStack(spacing: TeesSpacing.sm) {
            TeesFilterChip(model: .toggle(label: "Tee Times", isOn: true), style: .toggle) {}
            TeesFilterChip(model: .toggle(label: "The Leaderboard"), style: .toggle) {}
        }
    }
    .padding(TeesSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TeesColor.background)
}
