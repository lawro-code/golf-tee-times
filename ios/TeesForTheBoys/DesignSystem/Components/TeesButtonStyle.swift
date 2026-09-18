import SwiftUI

/// `button.primary` and `button.secondary`, ported.
///
/// **The dark scheme is a real branch, not a tidy shared path.** The
/// stylesheet's primary is `--green-deep` on `--bg`, which in the dark scheme
/// would be a #002616 button sitting on a #001a0e board: a 1.5:1 difference
/// that vanishes at arm's length in daylight. So in dark the primary inverts
/// to a gold ground with the same page-coloured label, which is now the
/// near-black green — the `.lb-tab.active` move, applied to the button. Both
/// pairings are measured in `TeesButtonStyleTests`; if either ever fails it is
/// a token problem for the D lead, not something to patch with a literal here.
///
/// The label colour does NOT branch. `TeesColor.background` is cream in light
/// and near-black green in dark, so `color: var(--bg)` ports across as one
/// token — which is the whole argument for the semantic layer.
public struct TeesButtonStyle: ButtonStyle {

    public enum Emphasis: Sendable {
        /// `button.primary` — filled. One per screen; it is the thing to do.
        case primary
        /// `button.secondary` — transparent, hairline bordered.
        case secondary
    }

    private let emphasis: Emphasis

    public init(_ emphasis: Emphasis) {
        self.emphasis = emphasis
    }

    public func makeBody(configuration: Configuration) -> some View {
        Label(emphasis: emphasis, configuration: configuration)
    }

    // MARK: - Body
    //
    // A nested View rather than modifiers applied straight to
    // `configuration.label`, because a `ButtonStyle` is not a View: an
    // `@Environment` property wrapper declared on the style itself is never
    // updated by SwiftUI and reads its default forever. The scheme branch, the
    // enabled state and Reduce Motion all have to be read from inside a real
    // view, so here is one.
    private struct Label: View {

        let emphasis: Emphasis
        let configuration: ButtonStyleConfiguration

        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            configuration.label
                .font(TeesFont.control)
                .textCase(.uppercase)
                .tracking(tracking)
                .foregroundStyle(labelColor)
                .padding(.horizontal, TeesSpacing.xl)
                .padding(.vertical, TeesSpacing.md)
                // Grows with the label at accessibility sizes; never shrinks
                // below the tap target at the small ones.
                .frame(minHeight: TeesLayout.minTapTarget)
                .background(shape.fill(groundColor))
                .overlay(shape.strokeBorder(borderColor, lineWidth: TeesStroke.hairline))
                .contentShape(shape)
                .teesShadow(shadow)
                // `button.primary:disabled { opacity: 0.7 }`.
                .opacity(isEnabled ? 1 : 0.7)
                .scaleEffect(pressScale)
                .animation(pressAnimation, value: configuration.isPressed)
        }

        // MARK: Shape

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: TeesRadius.pill, style: .continuous)
        }

        // MARK: Colour

        private var scheme: TeesScheme {
            colorScheme == .dark ? .dark : .light
        }

        private var groundColor: Color {
            switch emphasis {
            case .primary:
                // The branch. `greenDeep` and `gold` are brand marks and hold
                // their value in both schemes, so the choice — not the colour
                // — is what changes here.
                return scheme == .dark ? TeesColor.gold : TeesColor.greenDeep
            case .secondary:
                // `background: transparent`. Deliberately not
                // `TeesColor.background`: a secondary button has to sit on a
                // surface card as readily as on the page.
                return .clear
            }
        }

        private var labelColor: Color {
            switch emphasis {
            case .primary: return TeesColor.background
            case .secondary: return TeesColor.inkSoft
            }
        }

        private var borderColor: Color {
            switch emphasis {
            case .primary: return groundColor
            case .secondary: return TeesColor.hairlineStrong
            }
        }

        // MARK: Depth

        /// `box-shadow: 0 2px 6px` at rest lifting to `0 4px 12px` on the
        /// stylesheet's hover, which on a phone is the pressed state.
        /// `button.secondary { box-shadow: none }`.
        private var shadow: TeesShadow {
            guard emphasis == .primary else { return Self.flat }
            return configuration.isPressed ? TeesShadow.lifted : TeesShadow.card
        }

        /// The absence of an elevation, as a value, so the body can pick a
        /// shadow unconditionally. Private rather than a `TeesShadow.none` on
        /// the shared token type: the D track has several workers in this
        /// folder at once and an extension on a Stage-D2 type is exactly the
        /// kind of thing two of them would add twice.
        private static let flat = TeesShadow(color: .clear, radius: 0, x: 0, y: 0)

        // MARK: Motion

        /// Reduce Motion turns the press off entirely rather than shortening
        /// it. The pressed state is still legible — the shadow lifts, and the
        /// shadow is not motion.
        private var pressScale: CGFloat {
            configuration.isPressed && !reduceMotion ? 0.97 : 1
        }

        private var pressAnimation: Animation? {
            reduceMotion ? nil : .easeOut(duration: 0.15)
        }

        // MARK: Type

        /// Tracking as a fraction of the size the label is actually about to
        /// render at, so the caps stay tracked at accessibility sizes instead
        /// of jamming together — the same rule `teesEyebrow()` follows.
        ///
        /// `TeesTypeScale.metaTracking` (0.16em) is the nearest token to the
        /// stylesheet's 0.14em on `button.primary`. A token, not a literal:
        /// if the D lead wants the exact value it belongs in the type scale.
        private var tracking: CGFloat {
            let category = TeesTypeScale.contentSizeCategory(for: dynamicTypeSize)
            return TeesTypeScale.control.resolvedPointSize(for: category) * TeesTypeScale.metaTracking
        }
    }
}

// MARK: - Resolved colour, for tests and for callers that need the value

public extension TeesButtonStyle {

    /// The role the ground resolves to in `scheme`.
    ///
    /// Secondary reports `.background` because it paints nothing: what a
    /// golfer sees behind the label is the page. That makes the contrast
    /// question answerable for both emphases with one function.
    static func groundRole(_ emphasis: Emphasis, in scheme: TeesScheme) -> TeesColorRole {
        switch emphasis {
        case .primary: return scheme == .dark ? .gold : .greenDeep
        case .secondary: return .background
        }
    }

    /// The role the label draws in. Does not branch on scheme — see the note
    /// at the top of the file.
    static func labelRole(_ emphasis: Emphasis) -> TeesColorRole {
        switch emphasis {
        case .primary: return .background
        case .secondary: return .inkSoft
        }
    }

    /// The ground as literal components, for contrast arithmetic.
    static func resolvedGround(_ emphasis: Emphasis, in scheme: TeesScheme) -> TeesRGBA {
        TeesColor.resolved(groundRole(emphasis, in: scheme), scheme)
    }

    /// The label as literal components, for contrast arithmetic.
    static func resolvedLabel(_ emphasis: Emphasis, in scheme: TeesScheme) -> TeesRGBA {
        TeesColor.resolved(labelRole(emphasis), scheme)
    }
}

// MARK: - Call sites

public extension ButtonStyle where Self == TeesButtonStyle {
    /// `.buttonStyle(.teesPrimary)`
    static var teesPrimary: TeesButtonStyle { TeesButtonStyle(.primary) }
    /// `.buttonStyle(.teesSecondary)`
    static var teesSecondary: TeesButtonStyle { TeesButtonStyle(.secondary) }
}

// MARK: - Previews

#Preview("Buttons") {
    VStack(spacing: TeesSpacing.lg) {
        Button("Alert me when one opens") {}
            .buttonStyle(.teesPrimary)
        Button("Alert me when one opens") {}
            .buttonStyle(.teesPrimary)
            .disabled(true)
        Button("Clear filters") {}
            .buttonStyle(.teesSecondary)
    }
    .padding(TeesSpacing.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TeesColor.background)
}
