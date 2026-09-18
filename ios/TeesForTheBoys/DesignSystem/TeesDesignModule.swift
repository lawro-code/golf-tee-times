import Foundation

/// Track D — the design system.
///
/// Tokens and shared components ported from `docs/style.css`, which is the
/// design source of truth. No screens live here; track C owns those.
///
/// ## What this module exports
///
/// | Layer | Type | Covers |
/// |---|---|---|
/// | Colour | `TeesColor` | the Augusta palette, light and dark |
/// | Type | `TeesFont` | ten roles, all Dynamic Type backed |
/// | Type | `View.teesEyebrow()`, `View.teesMeta()` | the two tracked-caps treatments |
/// | Space | `TeesSpacing` | the eight-step scale, 2 through 48 |
/// | Shape | `TeesRadius`, `TeesStroke` | 2 / 10 / 999, and rule weights |
/// | Layout | `TeesLayout` | the 44pt minimum tap target |
/// | Depth | `TeesShadow`, `View.teesShadow(_:)` | `card`, `lifted`, `board` |
///
/// ## The font substitution
///
/// The website sets Playfair Display for display type and Inter for body.
/// **Neither is bundled.** `ios/project.yml` gives this target no resources
/// build phase, so there is nowhere to put a .ttf, and fetching a face at
/// runtime to draw a label is not a trade worth making.
///
/// What is ported is the type system, not the type files:
///
/// - Playfair Display → `Font.Design.serif` (New York — a transitional serif
///   with the same editorial voice)
/// - Inter → `Font.Design.default` (SF Pro — the same UI-grotesque lineage)
///
/// The reasoning in full is at the top of `Tokens/TeesFont.swift`. Swapping in
/// real faces later is a one-file change; the roles do not move.
public enum TeesDesignModule {
    /// Bumped off Stage 0's `"0"` when the token layer landed.
    public static let version = "1.0.0"
}
