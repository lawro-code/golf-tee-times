import SwiftUI
import UIKit
import XCTest
import TeesDesign
@testable import TeesViews

/// The registration warning is the one line on a search result that tells a
/// golfer a club needs a free account before it will take a booking — the
/// whole point of `SlotFormatting.registrationNote`. `SlotRow.registrationBadge`
/// draws it with `searchWarningText()`, and that is the modifier's only
/// caller, so pinning `SearchStyle.warningTextColor`'s contrast pins exactly
/// what the row draws.
///
/// There is no ViewInspector or snapshot library in this repo (see
/// `TeesFilterChipTests`'s doc comment), so this resolves the real dynamic
/// `Color` through `UIColor`'s trait-collection API — the same technique
/// `TeesColorTests` uses for the design system's own tokens — and reuses
/// `TeesRGBA`'s WCAG 2.1 arithmetic rather than re-deriving it by hand.
final class SearchWarningContrastTests: XCTestCase {

    /// WCAG AA for footnote-sized text. `searchWarningText()` is `.footnote`.
    private let aa = 4.5

    /// `SlotRow` never references `TeesColor` and sets no explicit background
    /// on the badge, so the warning is drawn straight on whichever ground the
    /// `.plain` list happens to show: plain `UIColor.systemBackground` (no
    /// background modifier is ever added between the list and the row) or the
    /// app's own cream, if that were applied instead. The fix must not depend
    /// on which one wins, so both are checked.
    private func plausibleLightBackgrounds() -> [(name: String, color: TeesRGBA)] {
        [
            ("UIColor.systemBackground", Self.resolve(Color(UIColor.systemBackground), .light)),
            ("TeesColor.background (cream)", TeesColor.resolved(.background, .light))
        ]
    }

    func testRegistrationWarningTextClearsAAOnPlausibleLightBackgrounds() {
        let warning = Self.resolve(SearchStyle.warningTextColor, .light)

        for (name, background) in plausibleLightBackgrounds() {
            let measured = warning.contrastRatio(against: background)
            XCTAssertGreaterThanOrEqual(
                measured, aa,
                """
                SearchStyle.warningTextColor on \(name) in light mode is \
                \(String(format: "%.2f", measured)):1, short of AA at \(aa):1. A golfer \
                glancing at a search result in bright light cannot read the club's \
                registration warning.
                """)
        }
    }

    /// Dark mode was never broken (system orange's dark variant is ~8.9:1 on
    /// the near-black ground) — this pins that the fix does not regress it.
    func testRegistrationWarningTextClearsAAOnPlausibleDarkBackgrounds() {
        let warning = Self.resolve(SearchStyle.warningTextColor, .dark)
        let backgrounds: [(name: String, color: TeesRGBA)] = [
            ("UIColor.systemBackground", Self.resolve(Color(UIColor.systemBackground), .dark)),
            ("TeesColor.background (dark)", TeesColor.resolved(.background, .dark))
        ]

        for (name, background) in backgrounds {
            let measured = warning.contrastRatio(against: background)
            XCTAssertGreaterThanOrEqual(
                measured, aa,
                "SearchStyle.warningTextColor on \(name) in dark mode is " +
                "\(String(format: "%.2f", measured)):1, short of AA at \(aa):1.")
        }
    }

    // MARK: - Helpers

    /// Resolves a dynamic SwiftUI `Color` to its literal components for
    /// `scheme`, going through `UIColor` exactly as `TeesColorTests` does for
    /// `TeesColor`'s own statics — `Color` itself is opaque and cannot be read
    /// back out of.
    private static func resolve(_ color: Color, _ scheme: TeesScheme) -> TeesRGBA {
        let trait = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: trait)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return TeesRGBA(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }
}
