import SwiftUI

// Spacing, radius, stroke and elevation, ported from docs/style.css.
//
// The stylesheet works in rem; these are points. At the sizes that matter the
// two are the same number, because the web base is 16px and iOS spacing is
// conventionally an 8pt grid — 0.5rem is 8, 1rem is 16, 1.5rem is 24. Where a
// CSS value sat off the grid (0.7rem padding, 0.85rem gaps) it has been pulled
// onto the nearest step rather than carried across to two decimal places.

/// The spacing scale. Eight steps, and nothing between them — a component that
/// needs 14 wants `md` or `lg`, not a literal.
public enum TeesSpacing {
    /// 2 — hairline separation, `.slot-sub` margin-top.
    public static let xxs: CGFloat = 2
    /// 4 — icon-to-label.
    public static let xs: CGFloat = 4
    /// 8 — `.slot-list` gap, chip padding.
    public static let sm: CGFloat = 8
    /// 12 — inside a slot row.
    public static let md: CGFloat = 12
    /// 16 — 1rem. Screen gutters, card padding.
    public static let lg: CGFloat = 16
    /// 24 — 1.5rem. Between course blocks.
    public static let xl: CGFloat = 24
    /// 32 — 2rem. Section padding.
    public static let xxl: CGFloat = 32
    /// 48 — 3rem. Between day groups.
    public static let xxxl: CGFloat = 48
}

/// Corner radii. There are three, and picking the wrong one is the single most
/// likely way to make this app stop looking like the website.
public enum TeesRadius {
    /// 2 — THE DEFAULT. Every card, panel and surface on the site uses this:
    /// `.slot`, `.round-of-week`, `.submit-form`, `.lb-table-wrap`. It reads as
    /// a sheet of paper on a noticeboard, which is the whole Augusta idea.
    /// If you are reaching for a corner radius on a rectangle, it is this one.
    public static let sharp: CGFloat = 2
    /// 10 — text inputs only (`.form-field input`, `.form-field select`),
    /// where iOS convention beats the stylesheet and a 2pt field looks broken.
    public static let control: CGFloat = 10
    /// 999 — FULLY ROUND, AND FOR CHIPS AND BUTTONS ONLY: `.filter select`,
    /// `.lb-tab`, `button.primary`, `button.secondary`. Never on a card. A
    /// pill-cornered slot row is the mistake this comment exists to prevent.
    public static let pill: CGFloat = 999
}

/// Border and rule weights.
public enum TeesStroke {
    /// 1 — `--hairline` borders, the `.course-header` underline, `.rule`.
    public static let hairline: CGFloat = 1
    /// 3 — the green bar down the left edge of a `.slot`. It is what makes a
    /// row read as a scorecard line rather than a list item.
    public static let leadingRule: CGFloat = 3
    /// 3 — the gold underline beneath an active `.tab`.
    public static let underline: CGFloat = 3
}

/// Layout constants that are not spacing.
public enum TeesLayout {
    /// 44 — Apple's minimum tap target. Anything tappable clears this, at every
    /// Dynamic Type size, including the small ones where the label shrinks.
    public static let minTapTarget: CGFloat = 44
}

/// One elevation step.
///
/// CSS blur is roughly twice SwiftUI's shadow radius, so a `0 4px 14px` in the
/// stylesheet is `radius: 7, y: 4` here.
public struct TeesShadow: Sendable, Equatable {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    public init(color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }
}

public extension TeesShadow {
    /// The resting `.slot` shadow: `0 1px 2px rgba(0, 28, 18, 0.04)`. Almost
    /// nothing — a card sitting flat on the cream, not floating above it.
    static let card = TeesShadow(
        color: Color(.sRGB, red: 0, green: 28.0 / 255.0, blue: 18.0 / 255.0, opacity: 0.04),
        radius: 1, x: 0, y: 1
    )

    /// `.slot:hover` / `:focus`, and the pressed state on touch:
    /// `0 4px 14px rgba(0, 28, 18, 0.12)`. Paired with a 1pt lift.
    static let lifted = TeesShadow(
        color: Color(.sRGB, red: 0, green: 28.0 / 255.0, blue: 18.0 / 255.0, opacity: 0.12),
        radius: 7, x: 0, y: 4
    )

    /// The heavy one under `.round-of-week`:
    /// `0 14px 32px rgba(0, 60, 42, 0.28)`. A hung scoreboard, not a card.
    /// Used once per screen at most.
    static let board = TeesShadow(
        color: Color(.sRGB, red: 0, green: 60.0 / 255.0, blue: 42.0 / 255.0, opacity: 0.28),
        radius: 16, x: 0, y: 14
    )
}

public extension View {
    /// Apply one of the three elevation steps.
    func teesShadow(_ shadow: TeesShadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}
