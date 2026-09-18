import SwiftUI
import XCTest
@testable import TeesDesign

/// The chip is the control a golfer touches most, so these are the two ways it
/// can quietly stop working: it can go invisible in one scheme, or it can
/// announce itself as a bare number with no clue which filter it belongs to.
/// Neither shows up in a diff.
///
/// There is no snapshot or view-inspection library in this repo and none may
/// be added, so nothing here asserts on a rendered pixel. What it asserts on
/// is the `Model` and the resolved tokens the body is built from — which is
/// where both failures actually live.
final class TeesFilterChipTests: XCTestCase {

    /// WCAG AA for text below 18pt. A chip label is control-sized, so this is
    /// the threshold that applies.
    private let aa = 4.5

    // MARK: - The model

    func testSelectedAndUnselectedModelsAreNotEqual() {
        let off = TeesFilterChip.Model.selector(label: "Holes", value: "18", isSelected: false)
        let on = TeesFilterChip.Model.selector(label: "Holes", value: "18", isSelected: true)

        XCTAssertNotEqual(
            off, on,
            "selection is not part of equality, so a chip row would not redraw when a filter is applied"
        )
        XCTAssertEqual(off, TeesFilterChip.Model.selector(label: "Holes", value: "18", isSelected: false))
    }

    func testASelectorWithAValueHasAnAccessibilityValue() {
        let model = TeesFilterChip.Model.selector(label: "Holes", value: "18")
        XCTAssertEqual(model.accessibilityValue, "18")
    }

    /// A toggle's state is already carried by the `.isSelected` trait, so a
    /// value on top of it would have VoiceOver say the same thing twice.
    func testAToggleHasNoAccessibilityValue() {
        let model = TeesFilterChip.Model.toggle(label: "Tee Times", isOn: true)
        XCTAssertNil(model.accessibilityValue)
        XCTAssertNil(model.value)
    }

    /// The failure this catches: a selector shows only its value — the pill
    /// reads "18" — so if the spoken strings do not also name the filter, a
    /// golfer using VoiceOver hears "18, button" and has no idea what is 18.
    ///
    /// Label and value are deliberately two strings rather than one. Putting
    /// the value in the label as well would have VoiceOver announce
    /// "Holes 18, 18, button". `spokenDescription` is the pair in the order it
    /// is read, which is what this asserts on.
    func testSpokenDescriptionCarriesBothTheFilterAndItsValue() {
        let model = TeesFilterChip.Model.selector(label: "Holes", value: "18", isSelected: true)

        XCTAssertEqual(model.accessibilityLabel, "Holes")
        XCTAssertEqual(model.accessibilityValue, "18")

        let spoken = model.spokenDescription
        XCTAssertTrue(spoken.contains("Holes"), "VoiceOver never names the filter: \(spoken)")
        XCTAssertTrue(spoken.contains("18"), "VoiceOver never reads the value: \(spoken)")
        XCTAssertNotEqual(spoken, "18", "the chip announces a bare value")
    }

    func testAToggleSpeaksItsLabelAndNothingElse() {
        let model = TeesFilterChip.Model.toggle(label: "The Leaderboard")
        XCTAssertEqual(model.spokenDescription, "The Leaderboard")
    }

    /// The pill shows the chosen value, not the filter name — that is what
    /// makes a row of chips read as a sentence of current settings.
    func testDisplayTextIsTheValueWhenThereIsOneAndTheLabelWhenThereIsNot() {
        XCTAssertEqual(TeesFilterChip.Model.selector(label: "Holes", value: "18").displayText, "18")
        XCTAssertEqual(TeesFilterChip.Model.toggle(label: "Tee Times").displayText, "Tee Times")
        XCTAssertEqual(
            TeesFilterChip.Model(
                label: "Holes", value: "", isSelected: false,
                accessibilityLabel: "Holes", accessibilityValue: nil
            ).displayText,
            "Holes",
            "an empty value must not render an empty pill"
        )
    }

    // MARK: - Contrast
    //
    // The selected chip inverts: `TeesColor.accent` ground, `TeesColor.background`
    // label. `accent` is royal green in light and bright gold in dark, and
    // `background` is cream in light and near-black green in dark — so the
    // inversion has to be checked in BOTH schemes rather than in the one it
    // was drawn in. This is the test that catches a dark scheme where the chip
    // goes invisible.

    func testSelectedChipLabelIsReadableOnItsGroundInBothSchemes() {
        for scheme in [TeesScheme.light, .dark] {
            let ground = TeesColor.resolved(.accent, scheme)
            let label = TeesColor.resolved(.background, scheme)
            let measured = label.contrastRatio(against: ground)

            XCTAssertGreaterThanOrEqual(
                measured, aa,
                """
                the SELECTED chip is \(String(format: "%.2f", measured)):1 in \(scheme) \
                — background \(label.hexString) on accent \(ground.hexString). \
                Below \(aa):1 the most-touched control in the app is unreadable. \
                This is a D1 token problem, not something to patch in the chip.
                """
            )
        }
    }

    func testUnselectedChipLabelIsReadableOnItsGroundInBothSchemes() {
        for scheme in [TeesScheme.light, .dark] {
            let ground = TeesColor.resolved(.surface, scheme)
            let label = TeesColor.resolved(.ink, scheme)
            let measured = label.contrastRatio(against: ground)

            XCTAssertGreaterThanOrEqual(
                measured, aa,
                "the unselected chip is \(String(format: "%.2f", measured)):1 in \(scheme)"
            )
        }
    }

    /// Selected and unselected must be tellable apart at a glance, not only by
    /// measurement — a chip row where the applied filter looks like the others
    /// is a filter bar that lies about what it is showing.
    func testSelectedAndUnselectedChipsAreVisiblyDifferentGroundsInBothSchemes() {
        for scheme in [TeesScheme.light, .dark] {
            let selected = TeesColor.resolved(.accent, scheme)
            let unselected = TeesColor.resolved(.surface, scheme)
            let separation = selected.contrastRatio(against: unselected)

            XCTAssertGreaterThan(
                separation, 3,
                "selected and unselected chips are \(String(format: "%.2f", separation)):1 apart in \(scheme)"
            )
        }
    }

    // MARK: - Construction

    /// The names other tracks code against. If an initialiser or a style case
    /// is renamed this stops compiling, which is the point.
    func testTheChipBuildsInBothStyles() {
        let selector = TeesFilterChip(
            model: .selector(label: "Holes", value: "18", isSelected: true),
            style: .selector) {}
        let toggle = TeesFilterChip(
            model: .toggle(label: "Tee Times", isOn: true),
            style: .toggle) {}

        XCTAssertTrue("\(type(of: selector.body))".contains("ModifiedContent"))
        XCTAssertTrue("\(type(of: toggle.body))".contains("ModifiedContent"))
    }

    // MARK: - The model carries what the caller gave it
    //
    // Everything below is a way the chip can be wrong while still rendering a
    // pill, which is why none of it shows up in a review.

    /// Equality is what makes a chip row redraw. The existing selection test
    /// only proves `isSelected` participates; a hand-written `==` that
    /// compares the two visible strings and stops would pass it and still
    /// leave a chip announcing last week's filter name after a rebuild.
    func testEqualityCoversEveryStoredProperty() {
        let base = TeesFilterChip.Model(
            label: "Holes", value: "18", isSelected: false,
            accessibilityLabel: "Holes", accessibilityValue: "18")

        let variants: [(field: String, model: TeesFilterChip.Model)] = [
            ("label", TeesFilterChip.Model(
                label: "Time", value: "18", isSelected: false,
                accessibilityLabel: "Holes", accessibilityValue: "18")),
            ("value", TeesFilterChip.Model(
                label: "Holes", value: "9", isSelected: false,
                accessibilityLabel: "Holes", accessibilityValue: "18")),
            ("isSelected", TeesFilterChip.Model(
                label: "Holes", value: "18", isSelected: true,
                accessibilityLabel: "Holes", accessibilityValue: "18")),
            ("accessibilityLabel", TeesFilterChip.Model(
                label: "Holes", value: "18", isSelected: false,
                accessibilityLabel: "Number of holes", accessibilityValue: "18")),
            ("accessibilityValue", TeesFilterChip.Model(
                label: "Holes", value: "18", isSelected: false,
                accessibilityLabel: "Holes", accessibilityValue: "9")),
        ]

        for variant in variants {
            XCTAssertNotEqual(
                base, variant.model,
                """
                two chips differing only in \(variant.field) compare equal, so a chip row \
                would not redraw when \(variant.field) changes
                """
            )
        }

        XCTAssertEqual(
            base,
            TeesFilterChip.Model(
                label: "Holes", value: "18", isSelected: false,
                accessibilityLabel: "Holes", accessibilityValue: "18"),
            "two identical chips compare unequal, so the row would redraw on every state change")
    }

    /// `isOn` is the whole state of a toggle. A factory that took the argument
    /// and dropped it would leave the active tab drawn as an inactive one —
    /// and every existing toggle assertion (both about `accessibilityValue`)
    /// would still pass.
    func testTheToggleFactoryCarriesItsOnState() {
        XCTAssertTrue(
            TeesFilterChip.Model.toggle(label: "Tee Times", isOn: true).isSelected,
            "an ON toggle is built unselected — the active tab would not look active")
        XCTAssertFalse(TeesFilterChip.Model.toggle(label: "Tee Times", isOn: false).isSelected)
        XCTAssertFalse(
            TeesFilterChip.Model.toggle(label: "Tee Times").isSelected,
            "a toggle defaults to ON, so every tab in a row would look active at once")
    }

    func testTheSelectorFactoryCarriesItsSelectedState() {
        XCTAssertTrue(TeesFilterChip.Model.selector(label: "Holes", value: "18", isSelected: true).isSelected)
        XCTAssertFalse(
            TeesFilterChip.Model.selector(label: "Holes", value: "18").isSelected,
            "a selector defaults to selected, so the filter row would claim filters that are not applied")
    }

    // MARK: - What VoiceOver actually says

    /// Order is the point of splitting the two strings. "18, Holes" contains
    /// both words and is still the wrong sentence — a golfer needs to hear
    /// which filter they have landed on before they hear its setting.
    func testSpokenDescriptionReadsTheFilterBeforeItsValue() {
        XCTAssertEqual(
            TeesFilterChip.Model.selector(label: "Holes", value: "18").spokenDescription,
            "Holes, 18")
    }

    /// A filter that is on the row but not yet set: `value` is empty, so the
    /// pill falls back to naming itself. The spoken string has to fall back
    /// with it. Joining without dropping the empty part gives "Price, " — a
    /// dangling separator VoiceOver reads as a pause into nothing.
    func testAnUnsetSelectorSpeaksTheFilterNameWithNoDanglingSeparator() {
        let unset = TeesFilterChip.Model.selector(label: "Price", value: "")

        XCTAssertEqual(unset.displayText, "Price", "an empty value renders an empty pill")
        XCTAssertEqual(unset.spokenDescription, "Price")
        XCTAssertFalse(
            unset.spokenDescription.hasSuffix(", "),
            "a dangling separator: \(unset.spokenDescription.debugDescription)")
        XCTAssertEqual(
            unset.spokenDescription,
            unset.spokenDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            "stray whitespace: \(unset.spokenDescription.debugDescription)")
    }

    // MARK: - The chip keeps what it was handed

    /// The default style is the `.filter select`, which is the one with the
    /// chevron. Flip the default and every selector chip built without an
    /// explicit style silently loses the mark that says it opens a menu — and
    /// the build-both-styles test, which passes its style explicitly, stays
    /// green through it.
    func testTheDefaultChipStyleIsTheSelector() {
        let chip = TeesFilterChip(model: .selector(label: "Holes", value: "18")) {}

        guard let style = Mirror(reflecting: chip).descendant("style") as? TeesFilterChip.Style else {
            return XCTFail("TeesFilterChip no longer stores the style it was built with")
        }
        XCTAssertTrue(
            Self.isSelector(style),
            "the default chip style is no longer .selector — selector chips lose their chevron")
    }

    func testAToggleChipKeepsTheToggleStyle() {
        let chip = TeesFilterChip(model: .toggle(label: "Tee Times"), style: .toggle) {}

        guard let style = Mirror(reflecting: chip).descendant("style") as? TeesFilterChip.Style else {
            return XCTFail("TeesFilterChip no longer stores the style it was built with")
        }
        XCTAssertFalse(
            Self.isSelector(style),
            "a toggle was built as a selector — an on/off tab would draw a menu chevron")
    }

    /// A chip that drops its caller's closure is a filter bar where nothing
    /// happens on tap. Nothing about the rendered pill would look wrong.
    func testTheChipKeepsTheActionItWasGiven() {
        var taps = 0
        let chip = TeesFilterChip(model: .toggle(label: "Tee Times"), style: .toggle) { taps += 1 }

        guard let action = Mirror(reflecting: chip).descendant("action") as? () -> Void else {
            return XCTFail("TeesFilterChip no longer stores the action it was given")
        }

        action()
        XCTAssertEqual(taps, 1, "the chip dropped its caller's action — every tap on the filter row does nothing")
    }

    // MARK: - The border is what makes an unselected chip a pill
    //
    // In the dark scheme `surface` and `background` are the same colour, so an
    // unselected chip has no ground of its own to be seen by: it is a pill
    // because of its hairline and nothing else. If that rule stops separating
    // from what it is drawn on, the filter row becomes a line of loose words
    // and the contrast tests above — which only measure the LABEL — stay green
    // through it.

    func testTheUnselectedChipBorderIsVisibleAgainstItsOwnGroundInBothSchemes() {
        for scheme in [TeesScheme.light, .dark] {
            let ground = TeesColor.resolved(.surface, scheme)
            let border = TeesColor.resolved(.hairlineStrong, scheme)
            let measured = border.contrastRatio(against: ground)

            XCTAssertGreaterThan(
                measured, 1.3,
                """
                the unselected chip's border is \(String(format: "%.2f", measured)):1 on its own \
                ground in \(scheme) — the pill has no visible edge
                """
            )
        }
    }

    // MARK: - Helpers

    /// `Style` is `Sendable`, not `Equatable`, so the cases are matched rather
    /// than compared.
    private static func isSelector(_ style: TeesFilterChip.Style) -> Bool {
        if case .selector = style { return true }
        return false
    }
}
