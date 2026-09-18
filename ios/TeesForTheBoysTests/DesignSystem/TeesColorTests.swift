import SwiftUI
import UIKit
import XCTest
@testable import TeesDesign

/// These are not "the colours are defined" tests. Every one of them is written
/// to fail against the two ways this ticket could plausibly be done badly:
///
///   1. No dark scheme at all — the statics are static, and cream is the page
///      at midnight.
///   2. A naive inversion — dark is light with the luminance flipped, which
///      gives a grey-brown ground and unreadable status colours.
///
/// Where a colour did not clear WCAG AA, the fix was the colour, not the
/// threshold. Three of them moved; `TeesColor.light(_:)` and `dark(_:)` say
/// which and by how much.
final class TeesColorTests: XCTestCase {

    /// WCAG AA for body and caption text.
    private let aa = 4.5

    // MARK: - Helpers

    private func ratio(
        _ foreground: TeesColorRole,
        on background: TeesColorRole,
        _ scheme: TeesScheme
    ) -> Double {
        TeesColor.resolved(foreground, scheme)
            .contrastRatio(against: TeesColor.resolved(background, scheme))
    }

    private func assertReadable(
        _ foreground: TeesColorRole,
        on background: TeesColorRole,
        _ scheme: TeesScheme,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let measured = ratio(foreground, on: background, scheme)
        XCTAssertGreaterThanOrEqual(
            measured, aa,
            """
            \(foreground.rawValue) on \(background.rawValue) in \(scheme) is \
            \(String(format: "%.2f", measured)):1, short of AA at \(aa):1. \
            Darken or lift the colour — do not lower this threshold.
            """,
            file: file, line: line)
    }

    // MARK: - 1. Text reads, in both schemes

    func testInkClearsAAOnBackgroundInBothSchemes() {
        assertReadable(.ink, on: .background, .light)
        assertReadable(.ink, on: .background, .dark)
    }

    /// `muted` is the one that catches a lazy port: `--muted` #76735a is
    /// 3.86:1 on Augusta cream, so transcribing the stylesheet literally fails
    /// here. It is caption-sized text, so AA applies at 4.5:1.
    func testMutedClearsAAOnBackgroundInBothSchemes() {
        assertReadable(.muted, on: .background, .light)
        assertReadable(.muted, on: .background, .dark)
    }

    /// `muted` in dark is cream at 0.58 — translucent. The ratio must be
    /// measured on the composite, not on the cream, or the test is measuring a
    /// colour that is never drawn.
    func testDarkMutedIsMeasuredComposited() {
        let muted = TeesColor.resolved(.muted, .dark)
        XCTAssertLessThan(muted.a, 1, "dark muted is cream at reduced alpha")
        let composited = muted.composited(over: TeesColor.resolved(.background, .dark))
        XCTAssertEqual(composited.a, 1, accuracy: 0.0001,
                       "composited over an opaque ground, the result is opaque")
        XCTAssertLessThan(composited.relativeLuminance, muted.relativeLuminance,
                          "a near-black ground must pull cream down, not leave it alone")
    }

    // MARK: - 2. Status colours read, in both schemes

    /// The one that catches an unlifted ramp value. On the dark ground
    /// `--twilight` is 3.70:1 and `--masters-red` is 3.09:1; on cream,
    /// `--twilight` is 3.95:1. Three near-misses, none of them obvious by eye.
    func testStatusColoursClearAAOnBackgroundInBothSchemes() {
        for scheme in [TeesScheme.light, .dark] {
            assertReadable(.price, on: .background, scheme)
            assertReadable(.priceTwilight, on: .background, scheme)
            assertReadable(.alert, on: .background, scheme)
        }
    }

    /// Specifically: neither status colour may still be its ramp value on the
    /// dark ground, because both fail there. Stated as its own assertion so
    /// the reason survives a future edit.
    func testDarkStatusColoursAreLiftedOffTheRamp() {
        XCTAssertNotEqual(TeesColor.resolved(.priceTwilight, .dark), TeesPalette.twilight)
        XCTAssertNotEqual(TeesColor.resolved(.alert, .dark), TeesPalette.mastersRed)

        let ground = TeesColor.resolved(.background, .dark)
        XCTAssertLessThan(TeesPalette.twilight.contrastRatio(against: ground), aa,
                          "if the raw ramp now passes, style.css changed and this file should too")
        XCTAssertLessThan(TeesPalette.mastersRed.contrastRatio(against: ground), aa)
    }

    /// An alert that has been lifted so far it reads as the twilight price is
    /// a different bug. They have to stay tellable apart.
    func testDarkAlertAndTwilightStayDistinct() {
        let alert = TeesColor.resolved(.alert, .dark)
        let twilight = TeesColor.resolved(.priceTwilight, .dark)
        let distance = abs(alert.r - twilight.r) + abs(alert.g - twilight.g) + abs(alert.b - twilight.b)
        XCTAssertGreaterThan(distance, 0.25,
                             "red alert and orange twilight must not converge")
    }

    // MARK: - 3. The inverted panel reads too

    func testOnInverseClearsAAOnSurfaceInverseInBothSchemes() {
        assertReadable(.onInverse, on: .surfaceInverse, .light)
        assertReadable(.onInverse, on: .surfaceInverse, .dark)
    }

    // MARK: - 4. Dark is a scoreboard, not a flipped page

    /// The single assertion a missing dark scheme cannot survive: with no dark
    /// scheme the ground is cream at luminance 0.78, not 0.008.
    func testDarkGroundIsNearBlackAndDarkInkIsCream() {
        let ground = TeesColor.resolved(.background, .dark)
        let ink = TeesColor.resolved(.ink, .dark)

        XCTAssertLessThan(ground.relativeLuminance, 0.05,
                          "the dark ground is a scoreboard, not a dim page")
        XCTAssertGreaterThan(ink.relativeLuminance, 0.6,
                             "dark ink is cream, not a mid grey")
    }

    /// And the light scheme is still the website: cream page, near-black ink.
    func testLightGroundIsCreamAndLightInkIsNearBlack() {
        XCTAssertEqual(TeesColor.resolved(.background, .light), TeesPalette.cream)
        XCTAssertGreaterThan(TeesColor.resolved(.background, .light).relativeLuminance, 0.6)
        XCTAssertLessThan(TeesColor.resolved(.ink, .light).relativeLuminance, 0.05)
    }

    // MARK: - 5. Dark is green, not grey

    /// A desaturated inversion lands on grey or brown. Augusta does not.
    func testDarkGroundsAreGreenDominant() {
        for role in [TeesColorRole.background, .backgroundSoft, .surface, .surfaceInverse] {
            let colour = TeesColor.resolved(role, .dark)
            XCTAssertGreaterThan(colour.g, colour.r,
                                 "\(role.rawValue) in dark has no more green than red")
            XCTAssertGreaterThan(colour.g, colour.b,
                                 "\(role.rawValue) in dark has no more green than blue")
        }
    }

    // MARK: - 6. The dark scheme is finished

    /// The brand marks — and only these — are identical in both schemes. A
    /// crest that changes colour at dusk is not a crest.
    private let brandMarks: Set<TeesColorRole> = [
        .green, .greenDeep, .greenBoard, .gold, .goldBright, .goldSoft
    ]

    /// Walks every role. A half-written dark scheme leaves some role equal to
    /// its light value and fails here by name, which is the whole point —
    /// "the dark scheme looks off" is not a bug report.
    func testEveryNonBrandRoleDiffersBetweenSchemes() {
        for role in TeesColorRole.allCases where !brandMarks.contains(role) {
            XCTAssertNotEqual(
                TeesColor.resolved(role, .light),
                TeesColor.resolved(role, .dark),
                "\(role.rawValue) is the same in both schemes — the dark scheme is unfinished there")
        }
    }

    func testBrandMarksAreIdenticalInBothSchemes() {
        for role in brandMarks {
            XCTAssertEqual(
                TeesColor.resolved(role, .light),
                TeesColor.resolved(role, .dark),
                "\(role.rawValue) is a brand mark and must not move between schemes")
        }
    }

    /// Guards the other direction: a role added to the enum without a static
    /// on `TeesColor`, or a static added without a role, is a drift this
    /// count catches. Twenty-two roles, six of them brand marks.
    func testRoleCountMatchesThePinnedAPI() {
        XCTAssertEqual(TeesColorRole.allCases.count, 22)
        XCTAssertEqual(brandMarks.count, 6)
        XCTAssertEqual(Set(TeesColorRole.allCases.map(\.rawValue)).count, 22,
                       "raw values must be unique — they are what a failure message names")
    }

    // MARK: - 7. The ramp is transcribed correctly

    /// Round-trips every ramp colour through the hex initialiser and back.
    /// A mistyped digit in `TeesPalette` fails here rather than shipping a
    /// slightly wrong green nobody notices.
    ///
    /// The ticket said fifteen; `docs/style.css` `:root` defines sixteen
    /// opaque colours, and all sixteen are here. The two hairlines are
    /// `rgba()` in the stylesheet and have no hex form, so they are checked
    /// separately below.
    func testHexRoundTripsForEveryRampColour() {
        XCTAssertEqual(TeesPalette.ramp.count, 16)

        for entry in TeesPalette.ramp {
            XCTAssertEqual(TeesRGBA(hex: entry.hex), entry.color,
                           "\(entry.name): \(entry.hex) did not parse to the stored value")
            XCTAssertEqual(entry.color.hexString, entry.hex,
                           "\(entry.name): round trip changed the hex")
            XCTAssertEqual(entry.color.a, 1, "\(entry.name) is a ramp colour and is opaque")
        }
    }

    func testHairlinesCarryTheStylesheetAlpha() {
        XCTAssertEqual(TeesPalette.hairline.a, 0.16, accuracy: 0.0001)
        XCTAssertEqual(TeesPalette.hairlineStrong.a, 0.32, accuracy: 0.0001)
        XCTAssertEqual(TeesPalette.hairline.r, 0, accuracy: 0.0001)
        XCTAssertEqual(TeesPalette.hairline.g, 28.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(TeesPalette.hairline.b, 18.0 / 255.0, accuracy: 0.0001)
    }

    func testHexInitialiserRejectsRubbishAndAcceptsShorthand() {
        XCTAssertNil(TeesRGBA(hex: "not a colour"))
        XCTAssertNil(TeesRGBA(hex: "#12345"))
        XCTAssertNil(TeesRGBA(hex: ""))
        XCTAssertEqual(TeesRGBA(hex: "#abc"), TeesRGBA(hex: "#aabbcc"))
        XCTAssertEqual(TeesRGBA(hex: "F2E6C2"), TeesPalette.cream, "case and # are both optional")
        XCTAssertEqual(TeesRGBA(hex: "#f2e6c2b3")?.a ?? 0, 179.0 / 255.0, accuracy: 0.0001)
    }

    // MARK: - The WCAG arithmetic itself

    /// If the luminance formula is wrong, every threshold above is measuring
    /// nothing. These are the two fixed points of WCAG 2.1.
    func testContrastArithmeticAgainstKnownValues() {
        let white = TeesRGBA(r: 1, g: 1, b: 1)
        let black = TeesRGBA(r: 0, g: 0, b: 0)

        XCTAssertEqual(white.relativeLuminance, 1, accuracy: 0.0001)
        XCTAssertEqual(black.relativeLuminance, 0, accuracy: 0.0001)
        XCTAssertEqual(white.contrastRatio(against: black), 21, accuracy: 0.0001)
        XCTAssertEqual(white.contrastRatio(against: white), 1, accuracy: 0.0001)

        // Symmetric: the ratio does not care which one is the ground.
        XCTAssertEqual(black.contrastRatio(against: white), 21, accuracy: 0.0001)

        // A translucent foreground is composited before measuring, so cream at
        // half alpha on black is a mid tone, not full cream.
        let half = TeesPalette.cream.opacity(0.5)
        XCTAssertLessThan(half.contrastRatio(against: black),
                          TeesPalette.cream.contrastRatio(against: black))
    }

    // MARK: - The mechanism: one static, two schemes, no theme object

    /// The claim this whole design makes is that a component writes
    /// `TeesColor.ink` once and gets the right ink in both schemes. This test
    /// is that claim, checked through UIKit's real trait resolution rather
    /// than by reading the resolver again: take the published `Color`, resolve
    /// it against a light and then a dark trait collection, and require the
    /// components to match what `resolved(_:_:)` promised.
    ///
    /// It fails if a static is ever hand-written as a flat `Color`, because a
    /// flat colour returns the same components for both trait collections.
    func testEveryRoleResolvesDynamicallyThroughTraitCollections() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        for role in TeesColorRole.allCases {
            let dynamic = UIColor(TeesColor.color(role))
            assertComponents(dynamic.resolvedColor(with: light),
                             match: TeesColor.resolved(role, .light),
                             what: "\(role.rawValue) light")
            assertComponents(dynamic.resolvedColor(with: dark),
                             match: TeesColor.resolved(role, .dark),
                             what: "\(role.rawValue) dark")
        }
    }

    /// And the published statics are those same dynamic colours — spot-checked
    /// across every group, one ground, one ink, one line, one brand, two
    /// status.
    func testPublishedStaticsCarryTheSchemeSwitch() {
        let pairs: [(Color, TeesColorRole)] = [
            (TeesColor.background, .background),
            (TeesColor.surface, .surface),
            (TeesColor.ink, .ink),
            (TeesColor.muted, .muted),
            (TeesColor.onInverseSoft, .onInverseSoft),
            (TeesColor.hairline, .hairline),
            (TeesColor.gold, .gold),
            (TeesColor.priceTwilight, .priceTwilight),
            (TeesColor.alert, .alert),
            (TeesColor.accent, .accent),
            (TeesColor.leadingRule, .leadingRule)
        ]

        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for (published, role) in pairs {
            assertComponents(UIColor(published).resolvedColor(with: dark),
                             match: TeesColor.resolved(role, .dark),
                             what: "TeesColor.\(role.rawValue) in dark")
        }
    }

    private func assertComponents(
        _ resolved: UIColor,
        match expected: TeesRGBA,
        what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a),
                      "\(what): could not read components", file: file, line: line)
        XCTAssertEqual(Double(r), expected.r, accuracy: 0.005, "\(what) red", file: file, line: line)
        XCTAssertEqual(Double(g), expected.g, accuracy: 0.005, "\(what) green", file: file, line: line)
        XCTAssertEqual(Double(b), expected.b, accuracy: 0.005, "\(what) blue", file: file, line: line)
        XCTAssertEqual(Double(a), expected.a, accuracy: 0.005, "\(what) alpha", file: file, line: line)
    }
}

// MARK: - Adversarial suite

/// Written as the tester for D1, against the implementation rather than with
/// it. `TeesColorTests` above is the worker's own suite; every case here is
/// chosen because it survives a mutation that suite does not catch. Each one
/// names, in its doc comment, the specific wrong implementation it exists to
/// fail against — a test that cannot name its mutant is testing nothing.
///
/// Three themes:
///
///   1. **Self-consistent lies.** The round-trip test proves `entry.hex`
///      parses to `entry.color`; it does not prove either is what
///      `docs/style.css` says. So the transcription is re-derived here,
///      independently, from the stylesheet.
///   2. **Spot-checks.** The worker's static test covers 11 of the 22 statics
///      and only in dark, so 11 could be hand-written flat and pass.
///   3. **Passing for the wrong reason.** A grey `muted` and a pure-white dark
///      `ink` both clear every contrast threshold in the suite above while
///      throwing the Augusta palette away.
final class TeesColorAdversarialTests: XCTestCase {

    private let aa = 4.5

    // MARK: - 1. The ramp really is docs/style.css

    /// Transcribed by hand from `docs/style.css` `:root` for this test, not
    /// copied from `TeesPalette`. Sixteen opaque custom properties; the three
    /// `rgba()` ones (`--hairline`, `--hairline-strong`, `--on-green-soft`)
    /// have no hex form and are checked separately.
    private let stylesheet: [(name: String, hex: String)] = [
        ("cream", "#f2e6c2"),           // --bg
        ("creamSoft", "#e5d4a0"),       // --bg-soft
        ("surfaceCream", "#fbf6e0"),    // --surface
        ("ink", "#14180f"),             // --ink
        ("inkSoft", "#353a2c"),         // --ink-soft
        ("muted", "#76735a"),           // --muted
        ("green", "#013d22"),           // --green
        ("greenDeep", "#002616"),       // --green-deep
        ("greenBoard", "#001a0e"),      // --green-board
        ("greenBright", "#007a48"),     // --green-bright
        ("gold", "#c9a04e"),            // --gold
        ("goldBright", "#e6c66f"),      // --gold-bright
        ("goldSoft", "#efd58a"),        // --gold-soft
        ("onGreen", "#f4e9c4"),         // --on-green
        ("mastersRed", "#c8102e"),      // --masters-red
        ("twilight", "#b6541c")         // --twilight
    ]

    /// **Mutant this catches:** a mistyped digit written consistently in both
    /// the constant and its ramp entry — `cream = rgb("#f2e6c3")` with the
    /// entry hex changed to match. `testHexRoundTripsForEveryRampColour` is
    /// self-referential and stays green; the page ships a wrong cream.
    func testRampIsAnIndependentTranscriptionOfTheStylesheet() {
        XCTAssertEqual(TeesPalette.ramp.count, stylesheet.count,
                       "docs/style.css :root defines \(stylesheet.count) opaque colours")

        let shipped = Dictionary(uniqueKeysWithValues: TeesPalette.ramp.map { ($0.name, $0) })
        for entry in stylesheet {
            guard let got = shipped[entry.name] else {
                XCTFail("\(entry.name) is in docs/style.css but missing from TeesPalette.ramp")
                continue
            }
            XCTAssertEqual(got.hex, entry.hex,
                           "\(entry.name): style.css says \(entry.hex), TeesPalette says \(got.hex)")
            XCTAssertEqual(got.color, TeesRGBA(hex: entry.hex),
                           "\(entry.name): the stored components are not \(entry.hex)")
        }

        XCTAssertEqual(Set(shipped.keys), Set(stylesheet.map(\.name)),
                       "TeesPalette.ramp and docs/style.css :root name different colours")
    }

    /// The named constants, not just the ramp array, since screens and the
    /// semantic layer read the constants. A ramp entry could be right while
    /// the `static let` beside it is wrong.
    func testNamedPaletteConstantsMatchTheStylesheet() {
        let constants: [String: TeesRGBA] = [
            "cream": TeesPalette.cream, "creamSoft": TeesPalette.creamSoft,
            "surfaceCream": TeesPalette.surfaceCream, "ink": TeesPalette.ink,
            "inkSoft": TeesPalette.inkSoft, "muted": TeesPalette.muted,
            "green": TeesPalette.green, "greenDeep": TeesPalette.greenDeep,
            "greenBoard": TeesPalette.greenBoard, "greenBright": TeesPalette.greenBright,
            "gold": TeesPalette.gold, "goldBright": TeesPalette.goldBright,
            "goldSoft": TeesPalette.goldSoft, "onGreen": TeesPalette.onGreen,
            "mastersRed": TeesPalette.mastersRed, "twilight": TeesPalette.twilight
        ]
        XCTAssertEqual(constants.count, stylesheet.count)
        for entry in stylesheet {
            XCTAssertEqual(constants[entry.name], TeesRGBA(hex: entry.hex),
                           "TeesPalette.\(entry.name) is not \(entry.hex)")
        }
    }

    // MARK: - 2. Every static is the resolver, in both schemes

    /// All 22 statics paired with their role. If a role is added and this
    /// table is not, `testEveryPublishedStaticIsTheResolverInBothSchemes`
    /// fails on the count before it fails on a colour.
    private var publishedStatics: [(Color, TeesColorRole)] {
        [
            (TeesColor.background, .background),
            (TeesColor.backgroundSoft, .backgroundSoft),
            (TeesColor.surface, .surface),
            (TeesColor.surfaceInverse, .surfaceInverse),
            (TeesColor.ink, .ink),
            (TeesColor.inkSoft, .inkSoft),
            (TeesColor.muted, .muted),
            (TeesColor.onInverse, .onInverse),
            (TeesColor.onInverseSoft, .onInverseSoft),
            (TeesColor.hairline, .hairline),
            (TeesColor.hairlineStrong, .hairlineStrong),
            (TeesColor.green, .green),
            (TeesColor.greenDeep, .greenDeep),
            (TeesColor.greenBoard, .greenBoard),
            (TeesColor.gold, .gold),
            (TeesColor.goldBright, .goldBright),
            (TeesColor.goldSoft, .goldSoft),
            (TeesColor.price, .price),
            (TeesColor.priceTwilight, .priceTwilight),
            (TeesColor.alert, .alert),
            (TeesColor.accent, .accent),
            (TeesColor.leadingRule, .leadingRule)
        ]
    }

    /// **Mutant this catches:** any one of the eleven statics the worker's
    /// spot-check omits — `backgroundSoft`, `surfaceInverse`, `inkSoft`,
    /// `onInverse`, `hairlineStrong`, the four remaining brand marks, `price`
    /// — hand-written as a flat `Color(red:green:blue:)` at its light value.
    /// `testEveryRoleResolvesDynamicallyThroughTraitCollections` calls
    /// `TeesColor.color(_:)`, the function, so it never touches the static and
    /// stays green. Here the *static* is resolved against both traits.
    func testEveryPublishedStaticIsTheResolverInBothSchemes() {
        XCTAssertEqual(publishedStatics.count, TeesColorRole.allCases.count,
                       "a role exists with no static, or a static with no role")
        XCTAssertEqual(Set(publishedStatics.map(\.1)).count, TeesColorRole.allCases.count,
                       "two statics point at the same role")

        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        for (published, role) in publishedStatics {
            let dynamic = UIColor(published)
            assertComponents(dynamic.resolvedColor(with: light),
                             match: TeesColor.resolved(role, .light),
                             what: "TeesColor.\(role.rawValue) light")
            assertComponents(dynamic.resolvedColor(with: dark),
                             match: TeesColor.resolved(role, .dark),
                             what: "TeesColor.\(role.rawValue) dark")
        }
    }

    // MARK: - 3. Light is the stylesheet, minus two documented deviations

    /// Every light role and the `:root` value it must equal. `nil` marks the
    /// two roles the worker deliberately moved for contrast; they get their
    /// own, stricter test below.
    private var lightExpectations: [(TeesColorRole, String?)] {
        [
            (.background, "#f2e6c2"), (.backgroundSoft, "#e5d4a0"),
            (.surface, "#fbf6e0"), (.surfaceInverse, "#002616"),
            (.ink, "#14180f"), (.inkSoft, "#353a2c"),
            (.muted, nil),                              // deviation
            (.onInverse, "#f4e9c4"),
            (.onInverseSoft, nil),                      // rgba(), checked by alpha
            (.hairline, nil), (.hairlineStrong, nil),   // rgba()
            (.green, "#013d22"), (.greenDeep, "#002616"), (.greenBoard, "#001a0e"),
            (.gold, "#c9a04e"), (.goldBright, "#e6c66f"), (.goldSoft, "#efd58a"),
            (.price, "#013d22"),
            (.priceTwilight, nil),                      // deviation
            (.alert, "#c8102e"), (.accent, "#013d22"), (.leadingRule, "#013d22")
        ]
    }

    /// **Mutant this catches:** quietly nudging a light role that already
    /// passes AA — `surface` from #fbf6e0 to #fffdf4, say, or `accent` off
    /// `--green` onto `--green-bright`. Nothing in the worker's suite pins a
    /// light value except `background` and `ink`, so the website and the app
    /// drift apart in silence.
    func testLightSchemeIsTheStylesheetExceptForTheDocumentedDeviations() {
        XCTAssertEqual(lightExpectations.count, TeesColorRole.allCases.count)
        for (role, hex) in lightExpectations {
            guard let hex else { continue }
            XCTAssertEqual(TeesColor.resolved(role, .light), TeesRGBA(hex: hex),
                           "light \(role.rawValue) is not the stylesheet's \(hex)")
        }
        XCTAssertEqual(TeesColor.resolved(.onInverseSoft, .light).a, 0.7, accuracy: 0.001,
                       "--on-green-soft is rgba(244, 233, 196, 0.7)")
    }

    /// The deviation rule: the colour moved *along its own hue*, and it moved
    /// only as far as AA required.
    ///
    /// **Mutant this catches:** `muted` set to a neutral grey #4a4a4a. That is
    /// 7.12:1 on cream, so `testMutedClearsAAOnBackgroundInBothSchemes` passes
    /// — and the Augusta palette has quietly become Material. Hue distance
    /// from `--muted` is 53.6 degrees; the shipped #67644e is 0.8.
    func testTheDeviationsKeepTheirStylesheetHue() {
        let cases: [(String, TeesColorRole, TeesScheme, TeesRGBA)] = [
            ("muted", .muted, .light, TeesPalette.muted),
            ("priceTwilight", .priceTwilight, .light, TeesPalette.twilight),
            ("priceTwilight", .priceTwilight, .dark, TeesPalette.twilight),
            ("alert", .alert, .dark, TeesPalette.mastersRed)
        ]
        for (name, role, scheme, origin) in cases {
            let shipped = TeesColor.resolved(role, scheme)
            XCTAssertNotEqual(shipped, origin, "\(name) in \(scheme) was supposed to move")
            XCTAssertLessThan(
                hueDistance(shipped, origin), 8,
                """
                \(name) in \(scheme) moved \(String(format: "%.1f", hueDistance(shipped, origin)))° \
                off the stylesheet hue. Darken or lift along the hue; do not reach for a grey.
                """)
        }

        // Light deviations darken; dark deviations lift. Getting this backwards
        // would still clear AA against the opposite ground.
        XCTAssertLessThan(TeesColor.resolved(.muted, .light).relativeLuminance,
                          TeesPalette.muted.relativeLuminance,
                          "light muted must darken to reach AA on cream")
        XCTAssertLessThan(TeesColor.resolved(.priceTwilight, .light).relativeLuminance,
                          TeesPalette.twilight.relativeLuminance)
        XCTAssertGreaterThan(TeesColor.resolved(.priceTwilight, .dark).relativeLuminance,
                             TeesPalette.twilight.relativeLuminance,
                             "dark twilight must lift off a near-black ground")
        XCTAssertGreaterThan(TeesColor.resolved(.alert, .dark).relativeLuminance,
                             TeesPalette.mastersRed.relativeLuminance)
    }

    /// The rejected candidates, pinned. `#e03a52` is the lift the ticket
    /// itself suggested for the dark alert and it is 4.24:1 — a near-miss that
    /// only arithmetic catches. If any of these ever clears AA, the ground
    /// underneath it changed and the deviations need re-deriving.
    func testTheRejectedCandidatesStillFailAA() {
        let cream = TeesColor.resolved(.background, .light)
        let board = TeesColor.resolved(.background, .dark)
        let rejected: [(String, TeesRGBA, TeesRGBA)] = [
            ("--muted #76735a on cream", TeesPalette.muted, cream),
            ("--twilight #b6541c on cream", TeesPalette.twilight, cream),
            ("--twilight #b6541c on the board", TeesPalette.twilight, board),
            ("--masters-red #c8102e on the board", TeesPalette.mastersRed, board),
            ("the ticket's #e03a52 on the board", TeesRGBA(hex: "#e03a52")!, board)
        ]
        for (what, colour, ground) in rejected {
            XCTAssertLessThan(colour.contrastRatio(against: ground), aa,
                              "\(what) now passes AA — the deviations may no longer be needed")
        }
    }

    /// The exact ratios the gate report claims, recomputed here. Pins the
    /// shipped colours to the numbers that were reviewed.
    ///
    /// **Mutant this catches:** re-lifting the dark alert to a brighter
    /// #ff5566. Still AA, still red, still distinct from twilight — every
    /// assertion in the worker's suite passes, and a reviewed value has
    /// silently changed.
    func testMeasuredRatiosMatchTheReviewedNumbers() {
        let expected: [(TeesColorRole, TeesColorRole, TeesScheme, Double)] = [
            (.muted, .background, .light, 4.81),
            (.priceTwilight, .background, .light, 4.87),
            (.alert, .background, .light, 4.73),
            (.onInverse, .surfaceInverse, .light, 13.42),
            (.ink, .background, .dark, 14.99),
            (.muted, .background, .dark, 5.54),
            (.price, .background, .dark, 16.36),
            (.priceTwilight, .background, .dark, 6.85),
            (.alert, .background, .dark, 4.90),
            (.onInverse, .surfaceInverse, .dark, 15.91)
        ]
        for (fg, bg, scheme, claim) in expected {
            let measured = TeesColor.resolved(fg, scheme)
                .contrastRatio(against: TeesColor.resolved(bg, scheme))
            XCTAssertEqual(
                measured, claim, accuracy: 0.01,
                """
                \(fg.rawValue) on \(bg.rawValue) in \(scheme) measures \
                \(String(format: "%.2f", measured)):1; the reviewed value is \(claim):1.
                """)
        }
    }

    // MARK: - 4. Dark is Augusta at dusk, not a dark mode

    /// **Mutant this catches:** dark `ink` set to pure white. Luminance 1.0
    /// clears `> 0.6`, contrast on the board is 18.9:1, and it differs from
    /// light ink — the worker's suite is entirely green. The design says cream
    /// numerals on a scoreboard, and white is the single most common way a
    /// dark scheme loses its identity.
    func testDarkLightTonesAreCreamAndNotWhite() {
        for role in [TeesColorRole.ink, .onInverse, .onInverseSoft, .inkSoft, .muted, .price] {
            let colour = TeesColor.resolved(role, .dark)
            XCTAssertGreaterThan(colour.r, colour.g,
                                 "dark \(role.rawValue) is not warm — r must exceed g for a cream")
            XCTAssertGreaterThan(colour.g, colour.b,
                                 "dark \(role.rawValue) is not warm — g must exceed b for a cream")
            XCTAssertLessThan(colour.r - colour.b, 0.35,
                              "dark \(role.rawValue) has gone past cream into yellow")
        }
    }

    /// Elevation: a recessed band is darker than the page and a raised card is
    /// lighter, in *both* schemes. The dark scheme "walks down from
    /// --green-board", and the inverted panel is the floor.
    ///
    /// **Mutant this catches:** swapping dark `backgroundSoft` and `surface`.
    /// Both stay green-dominant, both still differ from their light values, so
    /// `testDarkGroundsAreGreenDominant` and
    /// `testEveryNonBrandRoleDiffersBetweenSchemes` both stay green — while
    /// every card on the page now reads as a hole punched in it.
    func testGroundsAreOrderedByElevationInBothSchemes() {
        for scheme in [TeesScheme.light, .dark] {
            let inverse = TeesColor.resolved(.surfaceInverse, scheme).relativeLuminance
            let soft = TeesColor.resolved(.backgroundSoft, scheme).relativeLuminance
            let page = TeesColor.resolved(.background, scheme).relativeLuminance
            let card = TeesColor.resolved(.surface, scheme).relativeLuminance

            XCTAssertLessThan(inverse, soft, "\(scheme): surfaceInverse is the floor")
            XCTAssertLessThan(soft, page, "\(scheme): backgroundSoft is recessed below the page")
            XCTAssertLessThan(page, card, "\(scheme): surface is a raised card above the page")
        }
    }

    /// And the four grounds stay tellable apart. A card whose fill equals the
    /// page is not a card.
    ///
    /// **Mutant this catches:** dark `surface` collapsed onto `background`
    /// (`greenBoard`). Nothing in the worker's suite compares two grounds to
    /// each other.
    ///
    /// The luminance floor is applied only to grounds that actually stack —
    /// a card or a band or the masthead, each drawn on the page, and a card
    /// drawn inside a band. `surfaceInverse` against `backgroundSoft` is
    /// deliberately not one of them: in dark they are 1.03:1 apart, which is
    /// fine while nothing puts an inverted panel directly on a recessed band
    /// and would be an invisible edge if something did.
    func testGroundsStayDistinguishableFromEachOther() {
        let grounds: [TeesColorRole] = [.surfaceInverse, .backgroundSoft, .background, .surface]
        let stacked: [(TeesColorRole, TeesColorRole)] = [
            (.surface, .background),        // a card on the page
            (.backgroundSoft, .background), // a recessed band in the page
            (.surfaceInverse, .background), // the masthead on the page
            (.surface, .backgroundSoft)     // a card inside a recessed band
        ]

        for scheme in [TeesScheme.light, .dark] {
            for (i, a) in grounds.enumerated() {
                for b in grounds[(i + 1)...] {
                    XCTAssertNotEqual(
                        TeesColor.resolved(a, scheme), TeesColor.resolved(b, scheme),
                        "\(scheme): \(a.rawValue) and \(b.rawValue) are the same colour")
                }
            }

            for (top, under) in stacked {
                let measured = TeesColor.resolved(top, scheme)
                    .contrastRatio(against: TeesColor.resolved(under, scheme))
                XCTAssertGreaterThan(
                    measured, 1.04,
                    """
                    \(scheme): \(top.rawValue) drawn on \(under.rawValue) is \
                    \(String(format: "%.3f", measured)):1 — the edge between them is invisible.
                    """)
            }
        }
    }

    // MARK: - 5. A hairline has to be a line

    /// **Mutant this catches:** dark `hairline` left as an ink-green
    /// `TeesPalette.greenDeep.opacity(0.16)`. It differs from its light value,
    /// it is green-dominant, it carries an alpha — the worker's suite is green
    /// — and on the near-black board it is 1.016:1, which is to say it is not
    /// there. This is the exact bug `TeesColor.dark(_:)`'s own comment claims
    /// the gold rules exist to avoid; nothing was asserting it.
    func testHairlinesAreVisibleAgainstEveryGroundTheySitOn() {
        for scheme in [TeesScheme.light, .dark] {
            for ground in [TeesColorRole.background, .surface] {
                let backdrop = TeesColor.resolved(ground, scheme)
                let thin = TeesColor.resolved(.hairline, scheme)
                let strong = TeesColor.resolved(.hairlineStrong, scheme)

                XCTAssertGreaterThan(
                    thin.contrastRatio(against: backdrop), 1.2,
                    "\(scheme): hairline is invisible on \(ground.rawValue)")
                XCTAssertGreaterThan(
                    strong.contrastRatio(against: backdrop), 1.9,
                    "\(scheme): hairlineStrong is not strong on \(ground.rawValue)")
                XCTAssertGreaterThan(
                    strong.contrastRatio(against: backdrop),
                    thin.contrastRatio(against: backdrop),
                    "\(scheme): hairlineStrong must out-read hairline on \(ground.rawValue)")
            }

            // A rule is translucent so it picks up whatever it is drawn over.
            XCTAssertLessThan(TeesColor.resolved(.hairline, scheme).a, 1)
            XCTAssertLessThan(TeesColor.resolved(.hairlineStrong, scheme).a, 1)
        }
    }

    // MARK: - 6. The whole text-on-ground matrix, with its exceptions named

    /// Every text role against every ground, in both schemes. Four pairs are
    /// below AA today; they are listed rather than hidden, and the test fails
    /// in both directions — a fifth pair dropping below AA fails, and one of
    /// these four being fixed fails too, so the list cannot rot.
    ///
    /// None of the four is currently drawn by any component in
    /// `DesignSystem/Components`, which is why D1 is not red: they are latent,
    /// not shipped. They are recorded here so the first screen that reaches
    /// for `backgroundSoft` finds out at the gate instead of in review.
    private let knownSubAA: Set<String> = [
        "light muted on backgroundSoft",          // 4.06:1
        "light priceTwilight on backgroundSoft",  // 4.12:1
        "light alert on backgroundSoft",          // 3.99:1
        "dark alert on surface"                   // 4.38:1
    ]

    func testTextOnGroundMatrixHasExactlyTheKnownShortfalls() {
        let text: [TeesColorRole] = [.ink, .inkSoft, .muted, .price, .priceTwilight, .alert, .accent]
        let grounds: [TeesColorRole] = [.background, .backgroundSoft, .surface]
        var found: Set<String> = []

        for scheme in [TeesScheme.light, .dark] {
            for foreground in text {
                for ground in grounds {
                    let measured = TeesColor.resolved(foreground, scheme)
                        .contrastRatio(against: TeesColor.resolved(ground, scheme))
                    let key = "\(scheme) \(foreground.rawValue) on \(ground.rawValue)"
                    if measured < aa { found.insert(key) }
                    XCTAssertTrue(
                        measured >= aa || knownSubAA.contains(key),
                        """
                        \(key) is \(String(format: "%.2f", measured)):1, a NEW shortfall against \
                        AA at \(aa):1. Move the colour, not the threshold.
                        """)
                }
            }
        }

        XCTAssertEqual(found, knownSubAA,
                       """
                       The known-shortfall list is out of date. Fixed: \
                       \(knownSubAA.subtracting(found).sorted()). New: \(found.subtracting(knownSubAA).sorted()).
                       """)
    }

    /// The inverted panel carries two text weights and both have to read on
    /// it. `onInverseSoft` — the tagline under the masthead — is asserted
    /// nowhere in the worker's suite.
    func testBothInverseTextWeightsReadOnTheInvertedPanel() {
        for scheme in [TeesScheme.light, .dark] {
            for role in [TeesColorRole.onInverse, .onInverseSoft] {
                let measured = TeesColor.resolved(role, scheme)
                    .contrastRatio(against: TeesColor.resolved(.surfaceInverse, scheme))
                XCTAssertGreaterThanOrEqual(
                    measured, aa,
                    "\(role.rawValue) on surfaceInverse in \(scheme) is \(String(format: "%.2f", measured)):1")
            }
            XCTAssertLessThan(
                TeesColor.resolved(.onInverseSoft, scheme)
                    .contrastRatio(against: TeesColor.resolved(.surfaceInverse, scheme)),
                TeesColor.resolved(.onInverse, scheme)
                    .contrastRatio(against: TeesColor.resolved(.surfaceInverse, scheme)),
                "\(scheme): the soft weight must be softer than the primary one")
        }
    }

    // MARK: - 7. The arithmetic's own failure paths

    /// `composited(over:)` over a *translucent* backdrop. Every existing test
    /// composites over an opaque ground, so the `backdrop.a` term and the
    /// `outAlpha > 0` guard are never executed — a source-over implementation
    /// that simply ignored `backdrop.a` would pass the whole suite above.
    func testCompositingOverATranslucentBackdrop() {
        let red = TeesRGBA(r: 1, g: 0, b: 0, a: 0.5)
        let blue = TeesRGBA(r: 0, g: 0, b: 1, a: 0.5)

        let over = red.composited(over: blue)
        XCTAssertEqual(over.a, 0.75, accuracy: 0.0001, "0.5 over 0.5 is 0.75, not 1.0")
        XCTAssertEqual(over.r, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(over.b, 1.0 / 3.0, accuracy: 0.0001)

        // Both invisible: the guard, not a divide by zero.
        let nothing = TeesRGBA(r: 1, g: 1, b: 1, a: 0)
            .composited(over: TeesRGBA(r: 0, g: 0, b: 0, a: 0))
        XCTAssertEqual(nothing.a, 0, accuracy: 0.0001)

        // An opaque foreground swallows the backdrop whole.
        XCTAssertEqual(TeesPalette.cream.composited(over: TeesPalette.greenBoard), TeesPalette.cream)

        // A fully transparent foreground leaves the backdrop alone.
        let ghost = TeesPalette.cream.opacity(0).composited(over: TeesPalette.greenBoard)
        XCTAssertEqual(ghost.r, TeesPalette.greenBoard.r, accuracy: 0.0001)
        XCTAssertEqual(ghost.g, TeesPalette.greenBoard.g, accuracy: 0.0001)
        XCTAssertEqual(ghost.b, TeesPalette.greenBoard.b, accuracy: 0.0001)
    }

    /// Digit-count boundaries either side of every accepted length, plus a
    /// non-hex letter in an otherwise well-formed string. The worker's test
    /// rejects "#12345" and rubbish; 4, 7 and 9 digits and "#gggggg" are the
    /// ones a length check written as `>= 3` would let through.
    func testHexInitialiserBoundaries() {
        for bad in ["#", "#1", "#12", "#1234", "#12345", "#1234567", "#123456789", "#gggggg", "#12345g"] {
            XCTAssertNil(TeesRGBA(hex: bad), "\(bad) is not a colour and must not parse")
        }
        for good in ["#abc", "abc", "#aabbcc", "AABBCC", "#aabbccdd", "  #aabbcc  "] {
            XCTAssertNotNil(TeesRGBA(hex: good), "\(good) is a colour and must parse")
        }
        XCTAssertEqual(TeesRGBA(hex: "#000000ff"), TeesRGBA(r: 0, g: 0, b: 0, a: 1))
        XCTAssertEqual(TeesRGBA(hex: "#00000000")?.a, 0)

        // A transparent colour writes its alpha; an opaque one does not.
        XCTAssertEqual(TeesRGBA(r: 0, g: 0, b: 0, a: 0).hexString, "#00000000")
        XCTAssertEqual(TeesRGBA(r: 0, g: 0, b: 0, a: 1).hexString, "#000000")
        XCTAssertEqual(TeesRGBA(hex: "#aabbccdd")?.hexString, "#aabbccdd")
    }

    /// `opacity(_:)` sets the alpha rather than multiplying it — the dark
    /// scheme is built out of chained calls on the same cream, so a
    /// multiplying implementation would darken every rule and caption by a
    /// factor nobody chose.
    func testOpacityReplacesTheAlphaAndComponentsAreClamped() {
        let half = TeesPalette.cream.opacity(0.5)
        XCTAssertEqual(half.opacity(0.5).a, 0.5, accuracy: 0.0001, "not 0.25")
        XCTAssertEqual(half.r, TeesPalette.cream.r, accuracy: 0.0001, "the hue must not move")

        let wild = TeesRGBA(r: 4, g: -2, b: 0.5, a: 9)
        XCTAssertEqual(wild.r, 1, accuracy: 0.0001)
        XCTAssertEqual(wild.g, 0, accuracy: 0.0001)
        XCTAssertEqual(wild.b, 0.5, accuracy: 0.0001)
        XCTAssertEqual(wild.a, 1, accuracy: 0.0001)
    }

    /// One non-trivial WCAG fixed point. White/black and self-contrast are
    /// satisfied by several wrong formulas — a mid grey is not. #767676 on
    /// white is the canonical 4.54:1 from the WCAG worked examples, and it
    /// only comes out right if the sRGB linearisation is actually applied.
    func testLuminanceUsesTheSRGBTransferFunction() {
        let grey = TeesRGBA(hex: "#767676")!
        XCTAssertEqual(grey.contrastRatio(against: TeesRGBA(r: 1, g: 1, b: 1)), 4.54, accuracy: 0.01)

        // Below the 0.04045 knee the curve is linear, above it is a power law.
        // A naive `pow` everywhere gets the dark end wrong.
        let dim = TeesRGBA(r: 0.03, g: 0.03, b: 0.03)
        XCTAssertEqual(dim.relativeLuminance, 0.03 / 12.92, accuracy: 0.000001)
        XCTAssertNotEqual(TeesRGBA(r: 0.5, g: 0.5, b: 0.5).relativeLuminance, 0.5, accuracy: 0.01)
    }

    // MARK: - Helpers

    private func hueDegrees(_ colour: TeesRGBA) -> Double {
        let high = max(colour.r, max(colour.g, colour.b))
        let low = min(colour.r, min(colour.g, colour.b))
        let delta = high - low
        guard delta > 0 else { return 0 }

        var hue: Double
        if high == colour.r {
            hue = 60 * ((colour.g - colour.b) / delta)
        } else if high == colour.g {
            hue = 60 * (((colour.b - colour.r) / delta) + 2)
        } else {
            hue = 60 * (((colour.r - colour.g) / delta) + 4)
        }
        while hue < 0 { hue += 360 }
        return hue.truncatingRemainder(dividingBy: 360)
    }

    private func hueDistance(_ first: TeesRGBA, _ second: TeesRGBA) -> Double {
        let raw = abs(hueDegrees(first) - hueDegrees(second))
        return min(raw, 360 - raw)
    }

    private func assertComponents(
        _ resolved: UIColor,
        match expected: TeesRGBA,
        what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a),
                      "\(what): could not read components", file: file, line: line)
        XCTAssertEqual(Double(r), expected.r, accuracy: 0.005, "\(what) red", file: file, line: line)
        XCTAssertEqual(Double(g), expected.g, accuracy: 0.005, "\(what) green", file: file, line: line)
        XCTAssertEqual(Double(b), expected.b, accuracy: 0.005, "\(what) blue", file: file, line: line)
        XCTAssertEqual(Double(a), expected.a, accuracy: 0.005, "\(what) alpha", file: file, line: line)
    }
}
