import SwiftUI
import UIKit

// MARK: - Font substitution. Read this before "fixing" the missing font files.
//
// docs/style.css — the design source of truth — declares two families:
//
//     --serif: "Playfair Display", "Iowan Old Style", Georgia, ..., serif;
//     --sans:  "Inter", -apple-system, BlinkMacSystemFont, ..., sans-serif;
//
// NEITHER IS BUNDLED, AND THAT IS A DECISION RATHER THAN AN OVERSIGHT.
// `ios/project.yml` is frozen for Stage 1 and gives TeesDesign no resources
// build phase, so this target has nowhere to put a .ttf; and pulling a face
// over the network at launch to draw a label is not a trade worth making for
// an app whose whole point is being fast about tee times.
//
// So what is ported here is the TYPE SYSTEM — the roles, the scale, the
// weights, the tabular figures, the tracking — not the font files:
//
//     Playfair Display -> Font.Design.serif
//         Resolves to New York on iOS: a transitional serif with the same
//         high-contrast, editorial voice the Augusta look is built on.
//     Inter            -> Font.Design.default
//         Resolves to SF Pro. Inter was drawn as a UI grotesque in the same
//         lineage, so the substitution is close to a no-op at text sizes.
//
// If a later version adds a resources phase, swapping these for
// `Font.custom(_:size:relativeTo:)` is a one-file change. The roles below,
// which every component codes against, do not move.
//
// MARK: - Dynamic Type
//
// Every token is built from a system TEXT STYLE, never a literal point size.
// `Font.system(size:)` does not scale, so a literal would freeze the app at
// one body size and fail immediately at accessibility sizes — which track C
// has to survive. `TeesTypeScale` below is the single table the tokens are
// generated from, and the tests drive it through `UIFont.preferredFont` at
// every content size category to prove the sizes actually move.

// MARK: - The scale

/// One row of the type scale: the recipe a public `TeesFont` token is built
/// from. Internal on purpose — components use the `Font` tokens; the recipe
/// exists so the Dynamic Type proof has something to measure.
struct TeesTypeRecipe: Equatable, Sendable {
    /// The SwiftUI text style the token is built on.
    let style: Font.TextStyle
    /// The UIKit spelling of the same style, for resolving a point size.
    let uiStyle: UIFont.TextStyle
    let design: Font.Design
    let weight: Font.Weight
    let italic: Bool
    /// Times and prices must not jitter as a list scrolls.
    let monospacedDigit: Bool

    var font: Font {
        var font = Font.system(style, design: design, weight: weight)
        if italic { font = font.italic() }
        if monospacedDigit { font = font.monospacedDigit() }
        return font
    }

    /// The point size this token actually renders at for a given content size
    /// category. This is the same metric SwiftUI resolves internally, so it is
    /// a real measurement of the token rather than a restatement of it.
    func resolvedPointSize(for category: UIContentSizeCategory) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        return UIFont.preferredFont(forTextStyle: uiStyle, compatibleWith: traits).pointSize
    }
}

/// The table every `TeesFont` token is generated from.
///
/// Sizes are the stylesheet's rem values re-expressed as the nearest iOS text
/// style — web body is 16px and iOS body is 17pt, so a 1.18rem `.course-name`
/// lands on `.title3` (20pt) and the ratios through the scale are preserved.
enum TeesTypeScale {

    // Display — the serif half. Playfair Display's roles.

    /// `h1` / `.section-title`: serif 700.
    static let title = TeesTypeRecipe(
        style: .largeTitle, uiStyle: .largeTitle,
        design: .serif, weight: .bold, italic: false, monospacedDigit: false
    )

    /// `.day-heading`: serif 500, 1.55rem.
    static let heading = TeesTypeRecipe(
        style: .title, uiStyle: .title1,
        design: .serif, weight: .medium, italic: false, monospacedDigit: false
    )

    /// `.course-name`: serif 700, 1.18rem.
    static let courseName = TeesTypeRecipe(
        style: .title3, uiStyle: .title3,
        design: .serif, weight: .bold, italic: false, monospacedDigit: false
    )

    /// `.slot-time`: serif 700, 1.15rem, tabular figures.
    static let slotTime = TeesTypeRecipe(
        style: .title3, uiStyle: .title3,
        design: .serif, weight: .bold, italic: false, monospacedDigit: true
    )

    /// `.slot-price`: serif 700, 1.05rem, tabular figures.
    static let price = TeesTypeRecipe(
        style: .headline, uiStyle: .headline,
        design: .serif, weight: .bold, italic: false, monospacedDigit: true
    )

    /// `.tagline` / `.empty-sub` / `.section-sub`: serif italic 400.
    static let quote = TeesTypeRecipe(
        style: .body, uiStyle: .body,
        design: .serif, weight: .regular, italic: true, monospacedDigit: false
    )

    // Text — the sans half. Inter's roles.

    /// Body copy: sans 400.
    static let body = TeesTypeRecipe(
        style: .body, uiStyle: .body,
        design: .default, weight: .regular, italic: false, monospacedDigit: false
    )

    /// Emphasised body: sans 600, as `.course-map-link` and `button.primary`.
    static let bodyStrong = TeesTypeRecipe(
        style: .body, uiStyle: .body,
        design: .default, weight: .semibold, italic: false, monospacedDigit: false
    )

    /// `.filter select` / `.lb-tab`: sans 500, ~0.88rem.
    static let control = TeesTypeRecipe(
        style: .subheadline, uiStyle: .subheadline,
        design: .default, weight: .medium, italic: false, monospacedDigit: false
    )

    /// `.slot-sub` / `.course-meta` / `.filter label`: sans 500, ~0.68rem.
    /// Small on purpose — it is only ever used uppercase and tracked out.
    static let caption = TeesTypeRecipe(
        style: .caption, uiStyle: .caption1,
        design: .default, weight: .medium, italic: false, monospacedDigit: false
    )

    /// Every token, for the tests that sweep the whole scale.
    static let all: [(name: String, recipe: TeesTypeRecipe)] = [
        ("title", title), ("heading", heading), ("courseName", courseName),
        ("slotTime", slotTime), ("price", price), ("quote", quote),
        ("body", body), ("bodyStrong", bodyStrong), ("control", control),
        ("caption", caption),
    ]

    /// `.eyebrow` and `.filter label` track out to 0.18em.
    static let eyebrowTracking: CGFloat = 0.18
    /// `.course-meta` and `.row-date` track out to 0.16em.
    static let metaTracking: CGFloat = 0.16

    /// SwiftUI's `DynamicTypeSize` in UIKit's spelling, so tracking can be
    /// computed against the size the text is actually about to render at.
    static func contentSizeCategory(for size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

// MARK: - The tokens

/// The type scale, one static per role in `docs/style.css`.
///
/// Every token scales with Dynamic Type. None of them is a literal point size.
public enum TeesFont {
    /// The `h1` / `.section-title` role. Serif 700.
    public static let title: Font = TeesTypeScale.title.font
    /// The `.day-heading` role. Serif 500.
    public static let heading: Font = TeesTypeScale.heading.font
    /// The `.course-name` role. Serif 700, ~1.18rem.
    public static let courseName: Font = TeesTypeScale.courseName.font
    /// The `.slot-time` role. Serif 700 with tabular figures, so a column of
    /// times does not jitter as the list scrolls.
    public static let slotTime: Font = TeesTypeScale.slotTime.font
    /// The `.slot-price` role. Serif 700 with tabular figures.
    public static let price: Font = TeesTypeScale.price.font
    /// The `.tagline` / `.empty-sub` role. Serif italic 400.
    public static let quote: Font = TeesTypeScale.quote.font
    /// Body copy. Sans 400.
    public static let body: Font = TeesTypeScale.body.font
    /// Emphasised body copy. Sans 600.
    public static let bodyStrong: Font = TeesTypeScale.bodyStrong.font
    /// The `.filter select` / `.lb-tab` role. Sans 500.
    public static let control: Font = TeesTypeScale.control.font
    /// The `.slot-sub` role. Sans 500, small. Intended for uppercase, tracked
    /// text — see `teesEyebrow()` and `teesMeta()`.
    public static let caption: Font = TeesTypeScale.caption.font
}

// MARK: - The two tracked-caps treatments

/// Uppercase, tracked-out, muted small text.
///
/// Tracking is a fraction of the RESOLVED point size rather than a fixed
/// number of points. A hard-coded 2pt looks right at the default body size and
/// falls apart at both ends of Dynamic Type — cramped at accessibility sizes,
/// gappy at the small ones.
private struct TeesTrackedCaps: ViewModifier {
    let emTracking: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let category = TeesTypeScale.contentSizeCategory(for: dynamicTypeSize)
        let points = TeesTypeScale.caption.resolvedPointSize(for: category)
        return content
            .font(TeesFont.caption)
            .textCase(.uppercase)
            .tracking(points * emTracking)
            .foregroundStyle(TeesColor.muted)
    }
}

public extension View {
    /// The `.eyebrow` / `.filter label` treatment: uppercase, tracked to
    /// 0.18em, caption weight, muted.
    ///
    /// Lives here rather than in a component file because the slot row, the
    /// course header, the filter bar and the empty state all need it and none
    /// of them should own it.
    func teesEyebrow() -> some View {
        modifier(TeesTrackedCaps(emTracking: TeesTypeScale.eyebrowTracking))
    }

    /// The `.course-meta` treatment: uppercase, tracked to 0.16em, caption
    /// weight, muted. Slightly tighter than an eyebrow because it carries
    /// longer strings — "NORTHERN BEACHES · 32 MIN · PAR 70".
    func teesMeta() -> some View {
        modifier(TeesTrackedCaps(emTracking: TeesTypeScale.metaTracking))
    }
}
