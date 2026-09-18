import SwiftUI
import UIKit
import XCTest
@testable import TeesDesign

/// The type layer. The assertions that matter here are the Dynamic Type ones:
/// a token built from a literal point size passes every eyeball check and then
/// fails the moment somebody turns the text size up, which track C has to
/// survive and a screenshot will not catch.
final class TeesFontTests: XCTestCase {

    /// Every content size category iOS offers, smallest to largest.
    private static let categories: [UIContentSizeCategory] = [
        .extraSmall,
        .small,
        .medium,
        .large,                                  // the default
        .extraLarge,
        .extraExtraLarge,
        .extraExtraExtraLarge,
        .accessibilityMedium,
        .accessibilityLarge,
        .accessibilityExtraLarge,
        .accessibilityExtraExtraLarge,
        .accessibilityExtraExtraExtraLarge,
    ]

    /// Index of `.large` in `categories` — where the default size sits.
    private static let defaultIndex = 3

    /// The public token next to the recipe it is supposed to have been built
    /// from. Pairing them is what stops the scale table and the tokens drifting
    /// apart: a token quietly re-spelled inline would still look fine but would
    /// no longer match its row.
    private static let tokens: [(name: String, font: Font, recipe: TeesTypeRecipe)] = [
        ("title", TeesFont.title, TeesTypeScale.title),
        ("heading", TeesFont.heading, TeesTypeScale.heading),
        ("courseName", TeesFont.courseName, TeesTypeScale.courseName),
        ("slotTime", TeesFont.slotTime, TeesTypeScale.slotTime),
        ("price", TeesFont.price, TeesTypeScale.price),
        ("quote", TeesFont.quote, TeesTypeScale.quote),
        ("body", TeesFont.body, TeesTypeScale.body),
        ("bodyStrong", TeesFont.bodyStrong, TeesTypeScale.bodyStrong),
        ("control", TeesFont.control, TeesTypeScale.control),
        ("caption", TeesFont.caption, TeesTypeScale.caption),
    ]

    private func sizes(_ recipe: TeesTypeRecipe) -> [CGFloat] {
        Self.categories.map { recipe.resolvedPointSize(for: $0) }
    }

    // MARK: - The scale is wired to the tokens

    func testEveryTokenIsCovered() {
        XCTAssertEqual(
            Self.tokens.count, TeesTypeScale.all.count,
            "TeesTypeScale.all and the token table have drifted apart"
        )
        XCTAssertEqual(Self.tokens.map(\.name), TeesTypeScale.all.map(\.name))
    }

    func testEveryTokenIsBuiltFromItsRowOfTheScale() {
        for token in Self.tokens {
            XCTAssertEqual(
                token.font, token.recipe.font,
                "TeesFont.\(token.name) is not the font its scale row describes"
            )
        }
    }

    // MARK: - Dynamic Type

    /// The proof. A hard-coded `Font.system(size:)` resolves to one number at
    /// every content size category, so it collapses all three of these.
    func testEveryTokenScalesWithDynamicType() {
        for (name, _, recipe) in Self.tokens {
            let resolved = sizes(recipe)

            XCTAssertEqual(
                resolved.count, Self.categories.count,
                "\(name): missing measurements"
            )

            // Never shrinks as the user asks for bigger text.
            for index in 1 ..< resolved.count {
                XCTAssertGreaterThanOrEqual(
                    resolved[index], resolved[index - 1],
                    "\(name) shrank from \(Self.categories[index - 1]) to \(Self.categories[index])"
                )
            }

            // And actually grows across the range, by a lot.
            XCTAssertGreaterThan(
                resolved[resolved.count - 1], resolved[0],
                "\(name) is the same size at the largest accessibility setting as at the smallest — it is not scaling"
            )
            XCTAssertGreaterThanOrEqual(
                Set(resolved).count, 8,
                "\(name) only takes \(Set(resolved).count) distinct sizes across 12 categories — that is a frozen size, not a scaled one"
            )
        }
    }

    /// Strictly increasing from the default size upwards, for every token.
    /// This is the half of the range track C has to render at.
    func testEveryTokenStrictlyIncreasesFromTheDefaultSizeUp() {
        for (name, _, recipe) in Self.tokens {
            let resolved = sizes(recipe)
            for index in (Self.defaultIndex + 1) ..< resolved.count {
                XCTAssertGreaterThan(
                    resolved[index], resolved[index - 1],
                    "\(name) did not grow from \(Self.categories[index - 1]) to \(Self.categories[index])"
                )
            }
        }
    }

    /// Strictly increasing across the WHOLE range — every token except
    /// `caption`.
    ///
    /// The exception is Apple's table, not ours. Measured on this SDK,
    /// `.caption1` resolves to 11, 11, 11, 12, 14, 16, 18, 22, 26, 32, 37, 43:
    /// flat across the three categories below the default, as are `.caption2`
    /// and `.footnote`. The smallest system style that is strictly increasing
    /// everywhere is `.subheadline` at 15pt, which is 25% too big to be the
    /// port of a 0.68rem `.slot-sub` and would read as a subheading sitting
    /// next to a 20pt slot time. So `caption` keeps the correct size and is
    /// covered by the two tests above instead; the flat region is below the
    /// default, which is the end that does not matter.
    func testEveryTokenExceptCaptionStrictlyIncreasesAcrossTheWholeRange() {
        for (name, _, recipe) in Self.tokens where name != "caption" {
            let resolved = sizes(recipe)
            for index in 1 ..< resolved.count {
                XCTAssertGreaterThan(
                    resolved[index], resolved[index - 1],
                    "\(name) did not grow from \(Self.categories[index - 1]) to \(Self.categories[index])"
                )
            }
        }
    }

    /// The exception above, pinned rather than asserted in prose.
    ///
    /// `caption` is flat across the three categories BELOW the default because
    /// that is what Apple's table does with `.caption1`, not because the token
    /// is frozen. If a future SDK makes it move, this fails and the exemption
    /// in `testEveryTokenExceptCaptionStrictlyIncreasesAcrossTheWholeRange`
    /// can be deleted — which is the only reason it is written down here.
    func testCaptionIsFlatBelowTheDefaultSizeBecauseApplesTableIs() {
        let resolved = sizes(TeesTypeScale.caption)

        XCTAssertEqual(resolved[0], resolved[1], "extraSmall and small disagree — Apple's .caption1 table moved")
        XCTAssertEqual(resolved[1], resolved[2], "small and medium disagree — Apple's .caption1 table moved")
        XCTAssertGreaterThan(
            resolved[Self.defaultIndex], resolved[Self.defaultIndex - 1],
            "caption does not grow at the default size, which is where it has to"
        )
        XCTAssertEqual(
            UIFont.preferredFont(
                forTextStyle: .caption1,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
            ).pointSize,
            resolved[Self.defaultIndex],
            "caption is no longer the .caption1 style it claims to be"
        )
    }

    // MARK: - The tokens are real tokens

    /// Catches the laziest possible port: ten names all pointing at the body
    /// font. `Font.system(.body)` compares equal to `Font.body`, so a token
    /// that forgot to state its design and weight would be caught here too.
    func testNoTokenIsJustTheSystemBodyFont() {
        for (name, font, _) in Self.tokens {
            XCTAssertNotEqual(
                font, Font.body,
                "TeesFont.\(name) is Font.body — that token was never ported"
            )
        }
    }

    /// The hierarchy the stylesheet establishes, at the default text size.
    func testTheScaleDescendsInTheOrderTheStylesheetSets() {
        let large = UIContentSizeCategory.large
        let title = TeesTypeScale.title.resolvedPointSize(for: large)
        let heading = TeesTypeScale.heading.resolvedPointSize(for: large)
        let courseName = TeesTypeScale.courseName.resolvedPointSize(for: large)
        let slotTime = TeesTypeScale.slotTime.resolvedPointSize(for: large)
        let price = TeesTypeScale.price.resolvedPointSize(for: large)
        let body = TeesTypeScale.body.resolvedPointSize(for: large)
        let control = TeesTypeScale.control.resolvedPointSize(for: large)
        let caption = TeesTypeScale.caption.resolvedPointSize(for: large)

        XCTAssertGreaterThan(title, heading, "h1 must outrank a day heading")
        XCTAssertGreaterThan(heading, courseName, "a day heading must outrank a course name")
        XCTAssertGreaterThanOrEqual(courseName, slotTime, "course name and slot time sit on the same step")
        XCTAssertGreaterThan(slotTime, price, "a slot time reads larger than its price")
        XCTAssertGreaterThanOrEqual(price, body)
        XCTAssertGreaterThan(body, control, "a control label is quieter than body copy")
        XCTAssertGreaterThan(control, caption, "a caption is the smallest thing on screen")
    }

    /// Times and prices sit in columns, so their figures must not change width
    /// as the digits change.
    func testTimesAndPricesUseTabularFigures() {
        XCTAssertTrue(TeesTypeScale.slotTime.monospacedDigit, "slot times would jitter while scrolling")
        XCTAssertTrue(TeesTypeScale.price.monospacedDigit, "prices would jitter while scrolling")
        XCTAssertNotEqual(
            TeesFont.slotTime, Font.system(.title3, design: .serif, weight: .bold),
            "slotTime lost its .monospacedDigit()"
        )
    }

    /// Playfair Display stands in as the serif design; Inter as the default.
    /// If the substitution is ever undone by accident, the display roles stop
    /// being serif and this catches it.
    func testDisplayRolesAreSerifAndTextRolesAreNot() {
        for name in ["title", "heading", "courseName", "slotTime", "price", "quote"] {
            let recipe = TeesTypeScale.all.first { $0.name == name }?.recipe
            XCTAssertEqual(recipe?.design, .serif, "\(name) should stand in for Playfair Display")
        }
        for name in ["body", "bodyStrong", "control", "caption"] {
            let recipe = TeesTypeScale.all.first { $0.name == name }?.recipe
            XCTAssertEqual(recipe?.design, .default, "\(name) should stand in for Inter")
        }
    }

    // MARK: - The two tracked-caps treatments

    func testEyebrowChangesTheView() {
        let base = Text("round of the week")
        let styled = base.teesEyebrow()

        XCTAssertNotEqual(
            "\(type(of: styled))", "\(type(of: base))",
            "teesEyebrow() returned the view unchanged"
        )
        XCTAssertTrue(
            "\(type(of: styled))".contains("ModifiedContent"),
            "teesEyebrow() did not apply a modifier, got \(type(of: styled))"
        )
    }

    func testMetaChangesTheView() {
        let base = Text("northern beaches")
        let styled = base.teesMeta()

        XCTAssertNotEqual(
            "\(type(of: styled))", "\(type(of: base))",
            "teesMeta() returned the view unchanged"
        )
        XCTAssertTrue(
            "\(type(of: styled))".contains("ModifiedContent"),
            "teesMeta() did not apply a modifier, got \(type(of: styled))"
        )
    }

    /// Tracking is stated in em and multiplied by the resolved point size, so
    /// the letter spacing that looks right at 12pt still looks right at 43pt.
    /// A fixed 2pt would be the same gap at both, which is the bug.
    func testTrackingIsAFractionOfTheResolvedSizeNotAFixedNumberOfPoints() {
        let small = TeesTypeScale.caption.resolvedPointSize(for: .extraSmall)
        let huge = TeesTypeScale.caption.resolvedPointSize(for: .accessibilityExtraExtraExtraLarge)

        XCTAssertGreaterThan(huge, small)

        for em in [TeesTypeScale.eyebrowTracking, TeesTypeScale.metaTracking] {
            XCTAssertGreaterThan(
                huge * em, small * em,
                "tracking does not move with the text size"
            )
            // Roughly a fifth of a character width — tracked out, not spaced apart.
            XCTAssertGreaterThan(em, 0.1)
            XCTAssertLessThan(em, 0.3)
        }

        XCTAssertGreaterThan(
            TeesTypeScale.eyebrowTracking, TeesTypeScale.metaTracking,
            "an eyebrow tracks wider than course meta — 0.18em against 0.16em"
        )
    }

    /// Every `DynamicTypeSize` maps to a distinct category, so nothing silently
    /// falls through to `.large` and freezes the tracking.
    func testEveryDynamicTypeSizeMapsToItsOwnContentSizeCategory() {
        let mapped = DynamicTypeSize.allCases.map(TeesTypeScale.contentSizeCategory(for:))
        XCTAssertEqual(
            Set(mapped).count, DynamicTypeSize.allCases.count,
            "two DynamicTypeSize cases collapsed onto one UIContentSizeCategory"
        )
        XCTAssertEqual(TeesTypeScale.contentSizeCategory(for: .large), .large)
        XCTAssertEqual(TeesTypeScale.contentSizeCategory(for: .accessibility5), .accessibilityExtraExtraExtraLarge)
    }

    // MARK: - The measurement apparatus itself
    //
    // Everything above measures `recipe.resolvedPointSize`, which resolves
    // `uiStyle`. What actually renders is `style`. Nothing else in this file
    // checks the two spellings name the same text style, so a recipe that
    // rendered `.title3` while measuring `.caption1` would satisfy every
    // Dynamic Type assertion above while being measured on the wrong thing.

    /// UIKit's spelling of each SwiftUI text style, written out by hand so the
    /// test states the mapping rather than asking the code under test for it.
    private static let uiSpelling: [Font.TextStyle: UIFont.TextStyle] = [
        .largeTitle: .largeTitle,
        .title: .title1,
        .title2: .title2,
        .title3: .title3,
        .headline: .headline,
        .subheadline: .subheadline,
        .body: .body,
        .callout: .callout,
        .footnote: .footnote,
        .caption: .caption1,
        .caption2: .caption2,
    ]

    func testEveryRecipeMeasuresTheStyleItActuallyRenders() {
        for (name, recipe) in TeesTypeScale.all {
            guard let want = Self.uiSpelling[recipe.style] else {
                XCTFail("\(name): this test has no UIKit spelling for \(recipe.style)")
                continue
            }
            XCTAssertEqual(
                recipe.uiStyle, want,
                "\(name) renders \(recipe.style) but every Dynamic Type assertion measures \(recipe.uiStyle) — the proof is looking at the wrong token"
            )
        }
    }

    /// The scale pinned to Apple's own numbers at the default text size. A
    /// token quietly moved one step up or down the scale still scales, still
    /// descends in order, and still fails here.
    func testTheScaleLandsOnApplesDefaultSizesAtTheDefaultTextSize() {
        let expected: [String: CGFloat] = [
            "title": 34,       // .largeTitle
            "heading": 28,     // .title1
            "courseName": 20,  // .title3
            "slotTime": 20,    // .title3
            "price": 17,       // .headline
            "quote": 17,       // .body
            "body": 17,        // .body
            "bodyStrong": 17,  // .body
            "control": 15,     // .subheadline
            "caption": 12,     // .caption1
        ]
        for (name, recipe) in TeesTypeScale.all {
            guard let want = expected[name] else {
                XCTFail("\(name) is a token this test does not know a size for")
                continue
            }
            XCTAssertEqual(
                recipe.resolvedPointSize(for: .large), want,
                "\(name) resolves to \(recipe.resolvedPointSize(for: .large))pt at the default text size, not \(want)pt"
            )
        }
    }

    /// `TeesTypeScale.all` is what `testDisplayRolesAreSerifAndTextRolesAreNot`
    /// and the sweeps read from, so a row that pairs a name with the wrong
    /// recipe silently redirects those assertions onto another token.
    func testTheScaleTableListsEachNameAgainstItsOwnRecipe() {
        let byName = Dictionary(uniqueKeysWithValues: Self.tokens.map { ($0.name, $0.recipe) })
        for (name, recipe) in TeesTypeScale.all {
            XCTAssertEqual(
                recipe, byName[name],
                "TeesTypeScale.all lists \(name) against a different token's recipe"
            )
        }
        XCTAssertEqual(
            Set(TeesTypeScale.all.map { "\($0.recipe)" }).count, TeesTypeScale.all.count,
            "two roles share one recipe — one of them was never really ported"
        )
    }

    /// `.tagline`, `.empty-sub` and `.section-sub` are the only italics in
    /// docs/style.css, and `.italic()` is the easiest thing in the recipe to
    /// drop on the way into the `Font`.
    func testQuoteIsTheOnlyItalicRoleAndTheItalicSurvivesIntoTheFont() {
        XCTAssertTrue(TeesTypeScale.quote.italic, "the tagline is serif italic in docs/style.css")
        for (name, recipe) in TeesTypeScale.all where name != "quote" {
            XCTAssertFalse(recipe.italic, "\(name) is not an italic role")
        }
        XCTAssertNotEqual(
            TeesFont.quote,
            Font.system(.body, design: .serif, weight: .regular),
            "TeesFont.quote lost its .italic() between the recipe and the token"
        )
    }

    /// Distinctness alone does not prove the map is in order: a mapping that
    /// sent `.xSmall` to an accessibility category would still be one-to-one
    /// and would compute tracking from a wildly wrong size. Measured through
    /// `.body`, which is strictly increasing at every step.
    func testDynamicTypeSizeMappingPreservesOrder() {
        let mapped = DynamicTypeSize.allCases.map(TeesTypeScale.contentSizeCategory(for:))
        let points = mapped.map { TeesTypeScale.body.resolvedPointSize(for: $0) }
        for index in 1 ..< points.count {
            XCTAssertGreaterThan(
                points[index], points[index - 1],
                "\(DynamicTypeSize.allCases[index]) maps to \(mapped[index]), which is not larger than \(DynamicTypeSize.allCases[index - 1]) -> \(mapped[index - 1])"
            )
        }
    }

    // MARK: - The tracked-caps treatments, measured rather than inspected
    //
    // `teesEyebrow()` and `teesMeta()` both return `ModifiedContent` whatever
    // they do inside, so asserting on the view type proves only that a
    // modifier was applied. These lay the text out and measure it.

    private static let sample = "NORTHERN BEACHES 32 MIN PAR 70"

    @MainActor
    private func laidOutWidth(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
            .width
    }

    /// The treatment written out by hand: caption, uppercase, this much
    /// tracking. The test states the recipe; the implementation has to match.
    @MainActor
    private func handRolled(tracking: CGFloat, at size: DynamicTypeSize) -> CGFloat {
        laidOutWidth(
            Text(Self.sample)
                .font(TeesFont.caption)
                .textCase(.uppercase)
                .tracking(tracking)
                .environment(\.dynamicTypeSize, size)
        )
    }

    private func captionPoints(at size: DynamicTypeSize) -> CGFloat {
        TeesTypeScale.caption.resolvedPointSize(for: TeesTypeScale.contentSizeCategory(for: size))
    }

    /// The headline claim of this layer: tracking is `em × the resolved point
    /// size`, not a fixed number of points. A hard-coded 2pt looks correct at
    /// the default size and is a third of the right gap at accessibility 5.
    @MainActor
    func testEyebrowTracksByEmOfTheResolvedSizeAndNotAFixedTwoPoints() {
        for size in [DynamicTypeSize.large, .accessibility5] {
            let points = captionPoints(at: size)
            let em = handRolled(tracking: points * TeesTypeScale.eyebrowTracking, at: size)
            let fixed = handRolled(tracking: 2, at: size)

            // The assertion below can only mean something if the two models
            // are distinguishable at this size to begin with.
            XCTAssertNotEqual(
                em, fixed, accuracy: 0.5,
                "at \(size) a 0.18em and a fixed 2pt lay out the same; this test cannot tell them apart"
            )

            let actual = laidOutWidth(
                Text(Self.sample).teesEyebrow().environment(\.dynamicTypeSize, size)
            )
            XCTAssertEqual(
                actual, em, accuracy: 0.5,
                "teesEyebrow() at \(size) laid out \(actual)pt wide; 0.18em of the resolved \(points)pt is \(em)pt and a frozen 2pt is \(fixed)pt"
            )
        }
    }

    /// `teesMeta()` is 0.16em, not the eyebrow's 0.18em. One modifier backs
    /// both treatments, so passing the wrong constant is a one-word slip that
    /// nothing else in this file would notice.
    @MainActor
    func testMetaTracksTighterThanAnEyebrow() {
        for size in [DynamicTypeSize.large, .accessibility5] {
            let points = captionPoints(at: size)
            let metaModel = handRolled(tracking: points * TeesTypeScale.metaTracking, at: size)
            let eyebrowModel = handRolled(tracking: points * TeesTypeScale.eyebrowTracking, at: size)

            XCTAssertNotEqual(
                metaModel, eyebrowModel, accuracy: 0.5,
                "at \(size) 0.16em and 0.18em lay out the same; this test cannot tell them apart"
            )

            let actual = laidOutWidth(
                Text(Self.sample).teesMeta().environment(\.dynamicTypeSize, size)
            )
            XCTAssertEqual(
                actual, metaModel, accuracy: 0.5,
                "teesMeta() at \(size) laid out \(actual)pt wide; 0.16em is \(metaModel)pt and the eyebrow's 0.18em is \(eyebrowModel)pt"
            )
        }
    }

    /// Both treatments are uppercase-only roles. Dropping
    /// `.textCase(.uppercase)` leaves the view type unchanged and the screen
    /// wrong, which is exactly the failure a type assertion cannot see.
    @MainActor
    func testBothTreatmentsUppercaseTheirText() {
        let lower = "northern beaches"
        let upper = "NORTHERN BEACHES"

        XCTAssertNotEqual(
            laidOutWidth(Text(lower).font(TeesFont.caption)),
            laidOutWidth(Text(upper).font(TeesFont.caption)),
            accuracy: 0.5,
            "the sample strings measure the same untreated, so the assertions below would pass for the wrong reason"
        )

        XCTAssertEqual(
            laidOutWidth(Text(lower).teesEyebrow()),
            laidOutWidth(Text(upper).teesEyebrow()),
            accuracy: 0.5,
            "teesEyebrow() is not applying .textCase(.uppercase)"
        )
        XCTAssertEqual(
            laidOutWidth(Text(lower).teesMeta()),
            laidOutWidth(Text(upper).teesMeta()),
            accuracy: 0.5,
            "teesMeta() is not applying .textCase(.uppercase)"
        )
    }
}
