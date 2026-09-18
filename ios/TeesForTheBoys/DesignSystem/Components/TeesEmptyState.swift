import SwiftUI

/// The `.empty-state`: a gold flag, a headline, an italic subline, and — when
/// the caller has something for the golfer to do about it — a button.
///
/// **Why the action slot is generic rather than a closure returning `AnyView`,
/// and why it exists at all.** "No tee times match" is the moment the app is
/// most useful, not least: it is exactly when "alert me when one opens" is the
/// right next tap. Track C owns that button and the watch behind it; this
/// container owns the place it goes. Generic over the action so a caller pays
/// nothing for the common case — `TeesEmptyState(headline:message:)` is
/// `TeesEmptyState<EmptyView>` and lays out no action at all.
///
/// **Why the text is one accessibility element and the action is not.**
/// "Nothing at Bondi before 9am. Widen the time or pick another course."
/// is one thought; making a golfer swipe through a decorative flag, a
/// headline and a subline to hear it is three stops for one sentence. The
/// action is deliberately left as its own element — folding a button into a
/// combined label makes it unreachable, which is a worse bug than the one the
/// combining fixes.
public struct TeesEmptyState<Action: View>: View {

    private let headline: String
    private let message: String?
    private let action: Action

    public init(headline: String, message: String?, @ViewBuilder action: () -> Action) {
        self.headline = headline
        self.message = message
        self.action = action()
    }

    public var body: some View {
        VStack(spacing: TeesSpacing.sm) {
            VStack(spacing: TeesSpacing.xs) {
                TeesEmptyStateFlag()
                    .fill(TeesColor.gold)
                    // `.empty-flag { opacity: 0.55 }` — the flag is a mood,
                    // not a warning. At full strength it reads as an error.
                    .opacity(0.55)
                    .frame(width: TeesEmptyStateFlag.side, height: TeesEmptyStateFlag.side)
                    .accessibilityHidden(true)

                Text(headline)
                    .font(TeesFont.bodyStrong)
                    .foregroundStyle(TeesColor.ink)
                    .multilineTextAlignment(.center)

                if let message, !message.isEmpty {
                    Text(message)
                        // `.empty-sub` is the serif italic — the same voice as
                        // the masthead tagline, which is what stops an empty
                        // screen reading as a failure.
                        .font(TeesFont.quote)
                        .foregroundStyle(TeesColor.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TeesEmptyStateText.accessibilityLabel(headline: headline, message: message))

            action
                .padding(.top, TeesSpacing.sm)
        }
        .frame(maxWidth: .infinity)
        // `.empty-state { padding: 3rem 1rem }`.
        .padding(.vertical, TeesSpacing.xxxl)
        .padding(.horizontal, TeesSpacing.lg)
    }
}

// MARK: - The no-action case

public extension TeesEmptyState where Action == EmptyView {
    /// An empty state with nothing to do about it — a day with no rounds, a
    /// course that simply had no free times.
    init(headline: String, message: String? = nil) {
        self.init(headline: headline, message: message) { EmptyView() }
    }
}

// MARK: - The spoken sentence

/// Non-generic so the string can be built and asserted on without naming an
/// action type that has nothing to do with it.
enum TeesEmptyStateText {

    /// Headline and message as one sentence for VoiceOver.
    ///
    /// Parts are trimmed and empty ones dropped before joining, so a `nil` or
    /// blank message leaves the headline alone — no trailing separator, no
    /// stray space. That is the case this function exists for: joining
    /// unconditionally is how an empty state ends up announcing
    /// "No tee times. " with a full stop hanging off the end of it.
    static func accessibilityLabel(headline: String, message: String?) -> String {
        [headline, message]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
}

// MARK: - The flag

/// The `#i-flag` symbol from `docs/index.html`, transcribed as a `Path`.
///
/// Named for its owner rather than for the symbol: `TeesDayHeading.swift`
/// transcribes the same `#i-flag` into a glyph of its own, and two top-level
/// types called `TeesFlagGlyph` in one module do not compile even when one of
/// them is file-private. Two transcriptions of one mark is a duplication for
/// the D lead to collapse into a single shared shape; it is not a thing to fix
/// by editing another ticket's file.
///
/// Inline rather than an asset because `ios/project.yml` is frozen and gives
/// TeesDesign no resources build phase — there is nowhere to put a PDF or an
/// image set. It is also three primitives, so a vector asset would be more
/// machinery than mark.
///
/// The SVG draws the pole as a 1.6-wide round-capped stroke and the pennant
/// and ball as fills. A `Shape` returns one `Path`, so the stroke is
/// transcribed into the geometry it describes: a 1.6-wide rounded rect whose
/// ends overshoot by half the width, which is exactly what a round cap is.
/// Filling the result with the non-zero rule draws the overlapping pole and
/// ball as one solid mark.
struct TeesEmptyStateFlag: Shape {

    /// `.empty-flag { width: 56px; height: 56px }`.
    static let side: CGFloat = 56

    /// The symbol's `viewBox="0 0 24 24"`.
    private static let viewBox: CGFloat = 24

    /// `stroke-width="1.6"` on the pole.
    private static let poleWidth: CGFloat = 1.6

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        guard side > 0 else { return Path() }

        let scale = side / Self.viewBox
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2

        func x(_ value: CGFloat) -> CGFloat { originX + value * scale }
        func y(_ value: CGFloat) -> CGFloat { originY + value * scale }
        func point(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x(px), y: y(py)) }

        var path = Path()

        // Pole: `M5 21 V3`, 1.6 wide, round caps — so a capsule from y=2.2 to
        // y=21.8 centred on x=5.
        let halfPole = Self.poleWidth / 2
        path.addRoundedRect(
            in: CGRect(
                x: x(5 - halfPole),
                y: y(3 - halfPole),
                width: Self.poleWidth * scale,
                height: (21 - 3 + Self.poleWidth) * scale),
            cornerSize: CGSize(width: halfPole * scale, height: halfPole * scale))

        // Pennant: `M5 4 L19 7.5 L5 11 Z`.
        path.move(to: point(5, 4))
        path.addLine(to: point(19, 7.5))
        path.addLine(to: point(5, 11))
        path.closeSubpath()

        // Ball at the hole: `<circle cx="5" cy="21" r="1.4"/>`.
        let ballRadius: CGFloat = 1.4
        path.addEllipse(
            in: CGRect(
                x: x(5 - ballRadius),
                y: y(21 - ballRadius),
                width: ballRadius * 2 * scale,
                height: ballRadius * 2 * scale))

        return path
    }
}

// MARK: - Previews

#Preview("Empty state") {
    VStack(spacing: TeesSpacing.xxl) {
        TeesEmptyState(
            headline: "No tee times match",
            message: "Widen the time, or drop the price filter.")

        TeesEmptyState(
            headline: "Nothing before 9am at The Coast",
            message: "Cancellations come through all week."
        ) {
            Button("Alert me when one opens") {}
                .buttonStyle(.teesPrimary)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TeesColor.background)
}
