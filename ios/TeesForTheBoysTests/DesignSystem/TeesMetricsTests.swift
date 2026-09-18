import SwiftUI
import UIKit
import XCTest
@testable import TeesDesign

/// Spacing, radius, stroke and elevation. These are cheap assertions, and they
/// exist because the failure they catch — a port that kept the names and threw
/// away the values — is invisible in a diff and obvious on screen.
final class TeesMetricsTests: XCTestCase {

    private static let spacing: [(name: String, value: CGFloat)] = [
        ("xxs", TeesSpacing.xxs),
        ("xs", TeesSpacing.xs),
        ("sm", TeesSpacing.sm),
        ("md", TeesSpacing.md),
        ("lg", TeesSpacing.lg),
        ("xl", TeesSpacing.xl),
        ("xxl", TeesSpacing.xxl),
        ("xxxl", TeesSpacing.xxxl),
    ]

    // MARK: - Spacing

    func testSpacingScaleStrictlyIncreases() {
        for index in 1 ..< Self.spacing.count {
            let previous = Self.spacing[index - 1]
            let current = Self.spacing[index]
            XCTAssertGreaterThan(
                current.value, previous.value,
                "TeesSpacing.\(current.name) (\(current.value)) does not exceed .\(previous.name) (\(previous.value))"
            )
        }
    }

    func testSpacingScaleIsTheEightStepsTheStylesheetUses() {
        XCTAssertEqual(Self.spacing.map(\.value), [2, 4, 8, 12, 16, 24, 32, 48])
    }

    func testEverySpacingStepIsPositive() {
        for step in Self.spacing {
            XCTAssertGreaterThan(step.value, 0, "TeesSpacing.\(step.name) is not a usable gap")
        }
    }

    // MARK: - Radius

    /// The three radii are three different decisions. A port that collapsed
    /// them onto one value would still compile and would quietly round off
    /// every card on the site.
    func testTheThreeRadiiAreThreeDifferentValues() {
        XCTAssertEqual(TeesRadius.sharp, 2, "the sheet-of-paper card corner is 2, as everywhere in docs/style.css")
        XCTAssertNotEqual(TeesRadius.sharp, TeesRadius.control, "cards and text fields do not share a corner")
        XCTAssertNotEqual(TeesRadius.control, TeesRadius.pill)
        XCTAssertNotEqual(TeesRadius.sharp, TeesRadius.pill)
        XCTAssertEqual(Set([TeesRadius.sharp, TeesRadius.control, TeesRadius.pill]).count, 3)
    }

    func testPillIsFullyRound() {
        XCTAssertGreaterThanOrEqual(
            TeesRadius.pill, 999,
            "pill must exceed half the height of anything it is applied to"
        )
    }

    func testRadiiAscendFromCardToPill() {
        XCTAssertLessThan(TeesRadius.sharp, TeesRadius.control)
        XCTAssertLessThan(TeesRadius.control, TeesRadius.pill)
    }

    // MARK: - Stroke

    func testStrokeWeights() {
        XCTAssertEqual(TeesStroke.hairline, 1)
        XCTAssertEqual(TeesStroke.leadingRule, 3, "the green bar down the left of a slot row")
        XCTAssertEqual(TeesStroke.underline, 3, "the gold rule under the active tab")
        XCTAssertLessThan(
            TeesStroke.hairline, TeesStroke.leadingRule,
            "a hairline border must be lighter than a rule that carries meaning"
        )
    }

    // MARK: - Layout

    func testTapTargetsClearApplesMinimum() {
        XCTAssertGreaterThanOrEqual(
            TeesLayout.minTapTarget, 44,
            "anything below 44pt fails Apple's own guidance and is hard to hit on a phone"
        )
    }

    // MARK: - Elevation

    func testTheThreeShadowsAreThreeDifferentShadows() {
        let shadows = [TeesShadow.card, TeesShadow.lifted, TeesShadow.board]

        XCTAssertNotEqual(TeesShadow.card, TeesShadow.lifted, "resting and lifted are the same shadow — there is no press feedback")
        XCTAssertNotEqual(TeesShadow.lifted, TeesShadow.board)
        XCTAssertNotEqual(TeesShadow.card, TeesShadow.board)
        XCTAssertEqual(Set(shadows.map { "\($0)" }).count, 3)
    }

    /// Elevation has to read as elevation: a lifted card throws a wider, lower
    /// shadow than a resting one, and the board is heavier than both.
    func testElevationIncreasesFromCardToLiftedToBoard() {
        XCTAssertGreaterThan(TeesShadow.lifted.radius, TeesShadow.card.radius)
        XCTAssertGreaterThan(TeesShadow.lifted.y, TeesShadow.card.y)
        XCTAssertGreaterThan(TeesShadow.board.radius, TeesShadow.lifted.radius)
        XCTAssertGreaterThan(TeesShadow.board.y, TeesShadow.lifted.y)
    }

    /// Every shadow falls straight down. The site has no side-lit surfaces.
    func testShadowsHaveNoHorizontalOffset() {
        for shadow in [TeesShadow.card, TeesShadow.lifted, TeesShadow.board] {
            XCTAssertEqual(shadow.x, 0, "shadows fall straight down, as they do in docs/style.css")
            XCTAssertGreaterThan(shadow.y, 0)
            XCTAssertGreaterThan(shadow.radius, 0)
        }
    }

    func testShadowIsMemberwiseConstructibleByOtherTracks() {
        let custom = TeesShadow(color: .black, radius: 3, x: 1, y: 2)
        XCTAssertEqual(custom.radius, 3)
        XCTAssertEqual(custom.x, 1)
        XCTAssertEqual(custom.y, 2)
        XCTAssertNotEqual(custom, TeesShadow.card)
    }

    func testShadowModifierChangesTheView() {
        let base = Color.clear
        let styled = base.teesShadow(.card)
        XCTAssertNotEqual(
            "\(type(of: styled))", "\(type(of: base))",
            "teesShadow(_:) returned the view unchanged"
        )
    }

    // MARK: - The values, against docs/style.css
    //
    // The tests above prove the three shadows are three different shadows and
    // that they get heavier in order. All of that stays true if the colours
    // were flattened to black and the blur was carried across from CSS
    // unhalved, which is the port people actually write.

    /// Resolve a `Color` back to sRGB. `SwiftUI.Color` is opaque, so this is
    /// the only way to assert what a shadow is actually made of.
    private func srgb(_ color: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    /// docs/style.css, verbatim:
    ///
    ///     .slot            box-shadow: 0  1px  2px rgba(0, 28, 18, 0.04)
    ///     .slot:hover      box-shadow: 0  4px 14px rgba(0, 28, 18, 0.12)
    ///     .round-of-week   box-shadow: 0 14px 32px rgba(0, 60, 42, 0.28)
    private static let stylesheet: [(name: String, shadow: TeesShadow, y: CGFloat, blur: CGFloat, rgb: (CGFloat, CGFloat, CGFloat), alpha: CGFloat)] = [
        ("card", .card, 1, 2, (0, 28, 18), 0.04),
        ("lifted", .lifted, 4, 14, (0, 28, 18), 0.12),
        ("board", .board, 14, 32, (0, 60, 42), 0.28),
    ]

    /// CSS blur is roughly twice SwiftUI's shadow radius. Carrying the blur
    /// across unhalved keeps every ordering assertion above green and doubles
    /// the softness of every surface in the app.
    func testShadowGeometryIsTheStylesheetsOffsetAndHalfItsBlur() {
        for item in Self.stylesheet {
            XCTAssertEqual(
                item.shadow.y, item.y,
                "\(item.name) sits \(item.shadow.y)pt down; docs/style.css says \(item.y)px"
            )
            XCTAssertEqual(
                item.shadow.radius, item.blur / 2,
                "\(item.name) has radius \(item.shadow.radius); \(item.blur)px of CSS blur is \(item.blur / 2)pt of SwiftUI radius"
            )
        }
    }

    /// The shadows are two different greens, not black at two opacities. On
    /// cream that difference is visible, and `.black.opacity(0.04)` is the
    /// first thing a port reaches for.
    func testShadowColoursAreTheStylesheetsGreensNotBlack() {
        for item in Self.stylesheet {
            let c = srgb(item.shadow.color)
            XCTAssertEqual(c.r, item.rgb.0 / 255, accuracy: 0.004, "\(item.name) red channel")
            XCTAssertEqual(c.g, item.rgb.1 / 255, accuracy: 0.004, "\(item.name) green channel")
            XCTAssertEqual(c.b, item.rgb.2 / 255, accuracy: 0.004, "\(item.name) blue channel")
            XCTAssertEqual(c.a, item.alpha, accuracy: 0.002, "\(item.name) opacity")
        }

        XCTAssertGreaterThan(
            srgb(TeesShadow.board.color).g, 0.15,
            "the scoreboard shadow has gone plain black — docs/style.css casts it in rgba(0, 60, 42, …)"
        )
        XCTAssertNotEqual(
            srgb(TeesShadow.board.color).g, srgb(TeesShadow.card.color).g, accuracy: 0.01,
            "card and board share one shadow colour; the stylesheet gives them different greens"
        )
    }

    /// The text-field radius, which nothing above pins. 2pt on a text input
    /// looks broken on iOS, which is the whole reason this third value exists.
    func testControlRadiusIsTheStylesheetsTextFieldCorner() {
        XCTAssertEqual(
            TeesRadius.control, 10,
            "docs/style.css sets .form-field input/select to border-radius: 10px"
        )
    }

    /// Every `Double`/`CGFloat` reachable from a value, so a modifier's stored
    /// geometry can be asserted without naming SwiftUI's private types.
    private func reachableNumbers(in value: Any, depth: Int = 0) -> [Double] {
        guard depth < 8 else { return [] }
        var found: [Double] = []
        if let double = value as? Double {
            found.append(double)
        } else if let float = value as? CGFloat {
            found.append(Double(float))
        }
        for child in Mirror(reflecting: value).children {
            found += reachableNumbers(in: child.value, depth: depth + 1)
        }
        return found
    }

    /// `teesShadow(_:)` has four fields to forward and `testShadowModifierChangesTheView` above is satisfied by forwarding none of them. A
    /// version that dropped the y offset, or ignored its argument entirely,
    /// still returns a different view type.
    func testShadowModifierForwardsTheGeometryAndNotJustTheColour() {
        let board = reachableNumbers(in: Rectangle().teesShadow(.board))
        XCTAssertFalse(
            board.isEmpty,
            "reflection found no numbers at all — this test can no longer see what it is checking"
        )
        XCTAssertTrue(
            board.contains { abs($0 - 16) < 0.0001 },
            "board's 16pt radius never reached the view: \(board)"
        )
        XCTAssertTrue(
            board.contains { abs($0 - 14) < 0.0001 },
            "board's 14pt y offset never reached the view: \(board)"
        )

        let card = reachableNumbers(in: Rectangle().teesShadow(.card))
        XCTAssertFalse(
            card.contains { abs($0 - 16) < 0.0001 },
            "teesShadow(_:) ignores its argument — a card and the scoreboard come out identical"
        )
    }

    /// The three-shadows test leans on `Equatable` meaning something. A
    /// hand-written `==` that compared only the radius would keep it green.
    func testShadowEqualityNoticesEveryField() {
        let base = TeesShadow(color: .black, radius: 4, x: 1, y: 2)
        XCTAssertEqual(base, TeesShadow(color: .black, radius: 4, x: 1, y: 2))
        XCTAssertNotEqual(base, TeesShadow(color: .white, radius: 4, x: 1, y: 2), "colour is not compared")
        XCTAssertNotEqual(base, TeesShadow(color: .black, radius: 5, x: 1, y: 2), "radius is not compared")
        XCTAssertNotEqual(base, TeesShadow(color: .black, radius: 4, x: 9, y: 2), "x is not compared")
        XCTAssertNotEqual(base, TeesShadow(color: .black, radius: 4, x: 1, y: 9), "y is not compared")
    }
}
