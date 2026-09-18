import SwiftUI
import XCTest
@testable import TeesDesign

/// An empty state is the screen a golfer sees when the app has nothing for
/// them, which makes it the screen most likely to ship untested. Two things
/// have to hold: the optional action slot must not cost anything when it is
/// not used, and the sentence VoiceOver reads has to be a sentence.
final class TeesEmptyStateTests: XCTestCase {

    // MARK: - The two initialisers

    /// The no-action case is `TeesEmptyState<EmptyView>` — a different type
    /// from an empty state that hosts a button, resolved at compile time. That
    /// is what lets a caller write `TeesEmptyState(headline:)` and lay out no
    /// action at all, rather than an invisible empty row.
    ///
    /// Track C's "alert me when one opens" is the reason the slot exists: when
    /// a search returns nothing, offering to watch for a cancellation IS the
    /// primary action. This test is only that the container can host it.
    func testTheNoActionInitialiserIsADistinctTypeFromTheActionBearingOne() {
        let plain = TeesEmptyState(headline: "No tee times match")
        let acting = TeesEmptyState(
            headline: "No tee times match",
            message: "Cancellations come through all week."
        ) {
            Button("Alert me") {}
        }

        let plainType = "\(type(of: plain))"
        let actingType = "\(type(of: acting))"

        XCTAssertNotEqual(plainType, actingType)
        XCTAssertTrue(
            plainType.contains("EmptyView"),
            "the no-action empty state should specialise on EmptyView, got \(plainType)"
        )
        XCTAssertFalse(actingType.contains("EmptyView"))
    }

    func testTheNoActionInitialiserDefaultsItsMessage() {
        let plain = TeesEmptyState(headline: "No tee times match")
        XCTAssertTrue("\(type(of: plain.body))".contains("ModifiedContent"))
    }

    // MARK: - The spoken sentence

    /// One element, one sentence. Swiping through a decorative flag, a
    /// headline and a subline to hear one thought is three stops for no gain.
    func testTheAccessibilityLabelCombinesHeadlineAndMessage() {
        let label = TeesEmptyStateText.accessibilityLabel(
            headline: "No tee times match",
            message: "Widen the time, or drop the price filter.")

        XCTAssertTrue(label.contains("No tee times match"), label)
        XCTAssertTrue(label.contains("Widen the time, or drop the price filter."), label)
        XCTAssertEqual(label, "No tee times match. Widen the time, or drop the price filter.")
    }

    /// The flag is decoration. If it ever reaches VoiceOver, the empty state
    /// starts announcing itself as "flag" before it says anything useful.
    func testTheGlyphIsNotPartOfTheSpokenLabel() {
        let label = TeesEmptyStateText.accessibilityLabel(
            headline: "No tee times match",
            message: "Widen the time.")

        for word in ["flag", "Flag", "glyph", "image", "pennant"] {
            XCTAssertFalse(label.contains(word), "the decorative glyph leaked into the label: \(label)")
        }
    }

    /// The case this function exists for. Joining unconditionally is how an
    /// empty state ends up announcing "No tee times match. " with a full stop
    /// and a space hanging off the end of it.
    func testANilMessageLeavesNoTrailingSeparatorOrWhitespace() {
        let label = TeesEmptyStateText.accessibilityLabel(headline: "No tee times match", message: nil)

        XCTAssertEqual(label, "No tee times match")
        XCTAssertFalse(label.hasSuffix("."), "a trailing separator: \(label.debugDescription)")
        XCTAssertFalse(label.hasSuffix(" "), "trailing whitespace: \(label.debugDescription)")
        XCTAssertEqual(
            label, label.trimmingCharacters(in: .whitespacesAndNewlines),
            "stray whitespace: \(label.debugDescription)"
        )
    }

    func testABlankMessageIsTreatedAsNoMessage() {
        XCTAssertEqual(
            TeesEmptyStateText.accessibilityLabel(headline: "No tee times match", message: "   "),
            "No tee times match")
        XCTAssertEqual(
            TeesEmptyStateText.accessibilityLabel(headline: "No tee times match", message: ""),
            "No tee times match")
    }

    func testTheHeadlineAndMessageAreTrimmedBeforeJoining() {
        XCTAssertEqual(
            TeesEmptyStateText.accessibilityLabel(headline: "  No tee times match  ", message: " Widen the time. "),
            "No tee times match. Widen the time.")
    }

    // MARK: - The flag

    /// A `Shape` asked to draw into nothing must return an empty path rather
    /// than divide by a zero scale — an empty state briefly laid out at zero
    /// height is ordinary during a transition.
    func testTheFlagGlyphIsEmptyInAZeroSizedRectAndDrawnInARealOne() {
        XCTAssertTrue(TeesEmptyStateFlag().path(in: .zero).isEmpty)

        let box = CGRect(x: 0, y: 0, width: TeesEmptyStateFlag.side, height: TeesEmptyStateFlag.side)
        let path = TeesEmptyStateFlag().path(in: box)
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(
            box.insetBy(dx: -1, dy: -1).contains(path.boundingRect),
            "the glyph draws outside its 56pt box: \(path.boundingRect)"
        )
    }

    /// The symbol is a 24x24 viewBox scaled uniformly and centred, so a wide
    /// frame must not stretch the pennant into a banner.
    func testTheFlagGlyphScalesUniformlyInANonSquareFrame() {
        let wide = CGRect(x: 0, y: 0, width: 200, height: 56)
        let bounds = TeesEmptyStateFlag().path(in: wide).boundingRect

        XCTAssertLessThanOrEqual(bounds.width, 56, "the glyph stretched to fill a wide frame")
        XCTAssertGreaterThan(bounds.minX, 0, "the glyph was not centred horizontally")
    }

    // MARK: - The container keeps what it was handed

    /// Two strings of the same type, one initialiser forwarding to another.
    /// Transpose them and the empty state announces its subline as its
    /// headline in the serif body face and its headline as the italic
    /// subline — and every type-level test above still passes, because the
    /// types are identical either way.
    func testTheConvenienceInitialiserForwardsItsArgumentsInTheRightOrder() {
        let mirror = Mirror(reflecting: TeesEmptyState(
            headline: "No tee times match",
            message: "Widen the time, or drop the price filter."))

        XCTAssertEqual(
            mirror.descendant("headline") as? String, "No tee times match",
            "the headline is not the string it was given — headline and message are transposed")
        XCTAssertEqual(
            mirror.descendant("message") as? String, "Widen the time, or drop the price filter.",
            "the message is not the string it was given — headline and message are transposed")
    }

    func testTheNoActionInitialiserDefaultsTheMessageToNothing() {
        let mirror = Mirror(reflecting: TeesEmptyState(headline: "No tee times match"))

        XCTAssertEqual(mirror.descendant("headline") as? String, "No tee times match")
        XCTAssertNil(
            mirror.descendant("message") as? String,
            "an empty state built without a message carries one anyway")
    }

    func testTheActionBearingInitialiserKeepsItsHeadlineAndMessage() {
        let mirror = Mirror(reflecting: TeesEmptyState(
            headline: "Nothing before 9am at The Coast",
            message: "Cancellations come through all week."
        ) {
            Button("Alert me when one opens") {}
        })

        XCTAssertEqual(mirror.descendant("headline") as? String, "Nothing before 9am at The Coast")
        XCTAssertEqual(mirror.descendant("message") as? String, "Cancellations come through all week.")
    }

    // MARK: - The spoken sentence, from the other end

    /// The mirror of the nil-message case. A headline that arrived blank must
    /// not leave ". " hanging off the FRONT of the sentence — an implementation
    /// that only guards the message half is the likeliest way to get one.
    func testABlankHeadlineLeavesNoLeadingSeparator() {
        let label = TeesEmptyStateText.accessibilityLabel(headline: "   ", message: "Widen the time.")

        XCTAssertEqual(label, "Widen the time.")
        XCTAssertFalse(label.hasPrefix("."), "a leading separator: \(label.debugDescription)")
        XCTAssertFalse(label.hasPrefix(" "), "leading whitespace: \(label.debugDescription)")
    }

    /// An empty state with nothing at all to say announces nothing, rather
    /// than announcing a full stop.
    func testAnEmptyStateWithNothingToSayAnnouncesNothing() {
        XCTAssertEqual(TeesEmptyStateText.accessibilityLabel(headline: "", message: nil), "")
        XCTAssertEqual(TeesEmptyStateText.accessibilityLabel(headline: " ", message: "  "), "")
    }

    /// Copy arrives from a caller, and caller copy arrives with newlines in
    /// it. Trimming whitespace but not newlines leaves VoiceOver a line break
    /// to read as a pause at the end of the sentence.
    func testANewlineAroundTheCopyIsTrimmedRatherThanSpoken() {
        XCTAssertEqual(
            TeesEmptyStateText.accessibilityLabel(
                headline: "\nNo tee times match", message: "Widen the time.\n"),
            "No tee times match. Widen the time.")
    }

    // MARK: - The flag is the symbol it was transcribed from

    /// `#i-flag` in `docs/index.html` is a 24x24 symbol: a pole `M5 21 V3` at
    /// `stroke-width="1.6"` with round caps, a pennant `M5 4 L19 7.5 L5 11 Z`,
    /// and a ball at `cx=5 cy=21 r=1.4`. Together those put the mark's extents
    /// at x 3.6...19 and y 2.2...22.4 in viewBox units — the ball's left edge,
    /// the pennant's tip, the cap's overshoot above the pole, and the ball's
    /// bottom.
    ///
    /// Every one of those numbers is a way the transcription can be wrong
    /// while still drawing something flag-shaped inside its box, which is all
    /// the existing bounds test checks. A pennant that stops short, a pole
    /// drawn as a bare line with no cap overshoot, a ball at the wrong radius:
    /// each moves exactly one edge, and each is caught here.
    func testTheFlagGlyphMatchesTheSymbolItWasTranscribedFrom() {
        // `.empty-flag { width: 56px; height: 56px }`.
        XCTAssertEqual(TeesEmptyStateFlag.side, 56)

        let side = TeesEmptyStateFlag.side
        let scale = side / 24
        let bounds = TeesEmptyStateFlag().path(in: CGRect(x: 0, y: 0, width: side, height: side)).boundingRect
        let tolerance: CGFloat = 0.75

        XCTAssertEqual(
            bounds.minX, 3.6 * scale, accuracy: tolerance,
            "the ball is not drawn at cx=5 r=1.4: \(bounds)")
        XCTAssertEqual(
            bounds.maxX, 19 * scale, accuracy: tolerance,
            "the pennant does not reach the tip at x=19: \(bounds)")
        XCTAssertEqual(
            bounds.minY, 2.2 * scale, accuracy: tolerance,
            "the pole's round cap does not overshoot the top of M5 21 V3: \(bounds)")
        XCTAssertEqual(
            bounds.maxY, 22.4 * scale, accuracy: tolerance,
            "the ball is not drawn at cy=21 r=1.4: \(bounds)")
    }

    /// The horizontal case is covered above; this is the other axis. Centring
    /// one axis and forgetting the other is a single missing term, and a flag
    /// pinned to the top of a tall empty state looks like a layout bug rather
    /// than a mark.
    func testTheFlagGlyphIsCentredVerticallyInATallFrame() {
        let tall = CGRect(x: 0, y: 0, width: 56, height: 200)
        let bounds = TeesEmptyStateFlag().path(in: tall).boundingRect
        let scale = TeesEmptyStateFlag.side / 24

        XCTAssertLessThanOrEqual(bounds.height, 56, "the glyph stretched to fill a tall frame")
        XCTAssertEqual(
            bounds.minY, (tall.height - TeesEmptyStateFlag.side) / 2 + 2.2 * scale, accuracy: 0.75,
            "the glyph was not centred vertically: \(bounds)")
    }

    /// A column that has collapsed to no width mid-transition. Scaling off the
    /// taller axis instead of the smaller one paints a flag across the screen
    /// on the frame before the layout settles; the zero-by-zero case the
    /// existing test covers would not catch it.
    func testTheFlagGlyphDrawsNothingWhenEitherAxisIsZero() {
        XCTAssertTrue(
            TeesEmptyStateFlag().path(in: CGRect(x: 0, y: 0, width: 0, height: 56)).isEmpty,
            "the glyph drew itself into a frame with no width")
        XCTAssertTrue(
            TeesEmptyStateFlag().path(in: CGRect(x: 0, y: 0, width: 56, height: 0)).isEmpty,
            "the glyph drew itself into a frame with no height")
    }
}
