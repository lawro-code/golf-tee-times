import SwiftUI
import XCTest
@testable import TeesDesign

/// The primary button is the one tap the app is asking for, and the way it
/// fails is silent: `button.primary` is `--green-deep` on `--bg`, and in the
/// dark scheme that is a #002616 button on a #001a0e board — a difference you
/// can measure and cannot see. So the dark primary is a real branch to a gold
/// ground, and these tests are what keeps it one.
///
/// No snapshot library exists here and none may be added, so the assertions
/// are on the resolved tokens the style is built from rather than on pixels.
final class TeesButtonStyleTests: XCTestCase {

    private let aa = 4.5

    private let schemes: [TeesScheme] = [.light, .dark]

    // MARK: - The two emphases are two buttons

    /// Primary is filled and secondary is transparent — secondary resolves to
    /// the page it sits on. If those ever came out the same colour the visual
    /// hierarchy would be gone while both buttons still rendered.
    func testPrimaryAndSecondaryGroundsDifferInBothSchemes() {
        for scheme in schemes {
            let primary = TeesButtonStyle.resolvedGround(.primary, in: scheme)
            let secondary = TeesButtonStyle.resolvedGround(.secondary, in: scheme)

            XCTAssertNotEqual(
                primary, secondary,
                "primary and secondary are the same ground in \(scheme): \(primary.hexString)"
            )

            let separation = primary.contrastRatio(against: secondary)
            XCTAssertGreaterThan(
                separation, 3,
                """
                a filled primary only \(String(format: "%.2f", separation)):1 from the page in \(scheme) \
                does not read as filled
                """
            )
        }
    }

    // MARK: - The dark branch exists

    /// The test that proves the branch is real. If somebody "simplifies" the
    /// style back to one shared `greenDeep` ground, both schemes resolve to
    /// the same colour and this fails — which is the only warning anyone would
    /// get before a button disappeared into the board.
    func testThePrimaryGroundDiffersBetweenLightAndDark() {
        let light = TeesButtonStyle.resolvedGround(.primary, in: .light)
        let dark = TeesButtonStyle.resolvedGround(.primary, in: .dark)

        XCTAssertNotEqual(
            light, dark,
            """
            the primary button uses one ground in both schemes (\(light.hexString)). \
            A deep-green button on a near-black-green board is invisible; dark has to \
            invert to gold.
            """
        )
        XCTAssertEqual(TeesButtonStyle.groundRole(.primary, in: .light), .greenDeep)
        XCTAssertEqual(TeesButtonStyle.groundRole(.primary, in: .dark), .gold)
    }

    /// The dark ground has to be visibly separated from the board it sits on,
    /// which is the failure the branch was introduced to fix. Measured here so
    /// the reason is recorded rather than remembered.
    func testTheStylesheetPrimaryWouldBeInvisibleOnTheDarkBoard() {
        let board = TeesColor.resolved(.background, .dark)
        let stylesheet = TeesColor.resolved(.greenDeep, .dark)
        let ported = TeesButtonStyle.resolvedGround(.primary, in: .dark)

        XCTAssertLessThan(
            stylesheet.contrastRatio(against: board), 1.5,
            "if green-deep now separates from the board, docs/style.css changed and this file should too"
        )
        XCTAssertGreaterThan(
            ported.contrastRatio(against: board), 3,
            "the dark primary does not separate from the board it sits on"
        )
    }

    // MARK: - Contrast

    /// The label is `TeesColor.background` in both schemes — cream on deep
    /// green in light, near-black green on gold in dark. One token, two
    /// pairings, and both have to clear AA.
    func testThePrimaryLabelIsReadableOnItsGroundInBothSchemes() {
        for scheme in schemes {
            let ground = TeesButtonStyle.resolvedGround(.primary, in: scheme)
            let label = TeesButtonStyle.resolvedLabel(.primary, in: scheme)
            let measured = label.contrastRatio(against: ground)

            XCTAssertGreaterThanOrEqual(
                measured, aa,
                """
                the primary button label is \(String(format: "%.2f", measured)):1 in \(scheme) \
                — \(label.hexString) on \(ground.hexString). Below \(aa):1 the app's one \
                call to action cannot be read. Report it to the D lead as a token problem.
                """
            )
        }
    }

    func testTheSecondaryLabelIsReadableOnThePageInBothSchemes() {
        for scheme in schemes {
            let ground = TeesButtonStyle.resolvedGround(.secondary, in: scheme)
            let label = TeesButtonStyle.resolvedLabel(.secondary, in: scheme)
            let measured = label.contrastRatio(against: ground)

            XCTAssertGreaterThanOrEqual(
                measured, aa,
                "the secondary button label is \(String(format: "%.2f", measured)):1 in \(scheme)"
            )
        }
    }

    /// A transparent secondary is only a button because of its border, so the
    /// border has to be visible on the page in both schemes. It is a rule
    /// rather than text, so 3:1 is the threshold.
    func testTheSecondaryBorderIsVisibleOnThePageInBothSchemes() {
        for scheme in schemes {
            let page = TeesColor.resolved(.background, scheme)
            let border = TeesColor.resolved(.hairlineStrong, scheme)
            let measured = border.contrastRatio(against: page)

            XCTAssertGreaterThan(
                measured, 1.3,
                "the secondary button's border is \(String(format: "%.2f", measured)):1 on the page in \(scheme)"
            )
        }
    }

    // MARK: - The call sites

    /// `.teesPrimary` and `.teesSecondary` are what every other track writes.
    /// If either is renamed this stops compiling.
    func testTheStaticCallSitesResolveToTheRightEmphasis() {
        let primary: TeesButtonStyle = .teesPrimary
        let secondary: TeesButtonStyle = .teesSecondary

        let styled = Button("Alert me when one opens") {}.buttonStyle(primary)
        XCTAssertTrue("\(type(of: styled))".contains("ModifiedContent"))

        let plain = Button("Clear filters") {}.buttonStyle(secondary)
        XCTAssertTrue("\(type(of: plain))".contains("ModifiedContent"))
    }

    func testTheLabelRoleDoesNotBranchOnScheme() {
        XCTAssertEqual(TeesButtonStyle.labelRole(.primary), .background)
        XCTAssertEqual(TeesButtonStyle.labelRole(.secondary), .inkSoft)
    }

    /// `.teesPrimary` and `.teesSecondary` are two lines of near-identical
    /// boilerplate sitting next to each other, which is the shape a copy-paste
    /// takes. Both statics returning `TeesButtonStyle(.primary)` compiles,
    /// renders, and passes every other test in this file — the resolved-colour
    /// helpers above all take their emphasis as an argument, so none of them
    /// ever looks at what the call sites actually construct. The result is a
    /// screen with two equally loud filled buttons and no hierarchy at all.
    func testTheStaticCallSitesAreTwoDifferentButtons() {
        guard
            let primary = Self.storedEmphasis(of: .teesPrimary),
            let secondary = Self.storedEmphasis(of: .teesSecondary)
        else {
            return XCTFail("TeesButtonStyle no longer stores the emphasis it was built with")
        }

        XCTAssertTrue(
            Self.isPrimary(primary),
            ".teesPrimary is not the primary emphasis — the app's one call to action renders as an outline")
        XCTAssertFalse(
            Self.isPrimary(secondary),
            ".teesSecondary is a filled primary — every screen would show two equally loud buttons")
    }

    func testTheInitialiserKeepsTheEmphasisItWasGiven() {
        guard
            let primary = Self.storedEmphasis(of: TeesButtonStyle(.primary)),
            let secondary = Self.storedEmphasis(of: TeesButtonStyle(.secondary))
        else {
            return XCTFail("TeesButtonStyle no longer stores the emphasis it was built with")
        }

        XCTAssertTrue(Self.isPrimary(primary))
        XCTAssertFalse(Self.isPrimary(secondary))
    }

    // MARK: - The branch is pinned from both sides

    /// The companion to `testTheStylesheetPrimaryWouldBeInvisibleOnTheDarkBoard`.
    /// That one records why dark cannot keep the light ground; this one records
    /// why light cannot take the dark one. Collapsing the branch to a single
    /// GOLD ground leaves the light button drawing a cream label on gold at
    /// about 1.8:1 — legible as a shape, unreadable as words.
    ///
    /// The two together are what force the branch to stay a branch: there is
    /// no single ground that works in both schemes, and each direction has a
    /// test saying so.
    func testTheDarkPrimaryGroundWouldBeUnreadableInTheLightScheme() {
        let gold = TeesColor.resolved(.gold, .light)
        let label = TeesButtonStyle.resolvedLabel(.primary, in: .light)
        let measured = label.contrastRatio(against: gold)

        XCTAssertLessThan(
            measured, aa,
            """
            gold now carries the light label at \(String(format: "%.2f", measured)):1, so the \
            scheme branch may no longer be necessary — if docs/style.css or the ramp changed, \
            this file changed with it
            """
        )
        XCTAssertEqual(TeesButtonStyle.groundRole(.primary, in: .light), .greenDeep)
    }

    // MARK: - Secondary sits on a card as readily as on the page

    /// Why the secondary ground is `.clear` rather than `TeesColor.background`:
    /// a "Clear filters" under an empty state sits on the page, and the same
    /// button inside a slot detail sits on a raised `surface` card. The
    /// existing contrast test only ever measures it against the page, so a
    /// token change that broke it on a card would not be caught.
    func testTheSecondaryButtonReadsOnACardAsWellAsOnThePage() {
        for scheme in schemes {
            let card = TeesColor.resolved(.surface, scheme)

            let label = TeesButtonStyle.resolvedLabel(.secondary, in: scheme)
            let labelContrast = label.contrastRatio(against: card)
            XCTAssertGreaterThanOrEqual(
                labelContrast, aa,
                """
                the secondary button label is \(String(format: "%.2f", labelContrast)):1 on a \
                surface card in \(scheme) — \(label.hexString) on \(card.hexString)
                """
            )

            let border = TeesColor.resolved(.hairlineStrong, scheme)
            let borderContrast = border.contrastRatio(against: card)
            XCTAssertGreaterThan(
                borderContrast, 1.3,
                """
                the secondary button's border is \(String(format: "%.2f", borderContrast)):1 on a \
                surface card in \(scheme) — a transparent button with no visible edge is not a button
                """
            )
        }
    }

    func testTheSecondaryGroundDoesNotBranchOnScheme() {
        XCTAssertEqual(TeesButtonStyle.groundRole(.secondary, in: .light), .background)
        XCTAssertEqual(
            TeesButtonStyle.groundRole(.secondary, in: .dark), .background,
            "a transparent button reports a ground of its own in dark, so the contrast it is measured at is not the one it renders")
    }

    // MARK: - Helpers

    /// `Emphasis` is `Sendable`, not `Equatable`, so the stored case is read
    /// back by reflection and matched rather than compared.
    private static func storedEmphasis(of style: TeesButtonStyle) -> TeesButtonStyle.Emphasis? {
        Mirror(reflecting: style).descendant("emphasis") as? TeesButtonStyle.Emphasis
    }

    private static func isPrimary(_ emphasis: TeesButtonStyle.Emphasis) -> Bool {
        if case .primary = emphasis { return true }
        return false
    }
}
