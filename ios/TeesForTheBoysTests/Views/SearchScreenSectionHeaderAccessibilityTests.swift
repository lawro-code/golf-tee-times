import SwiftUI
import XCTest
import TeesContract
@testable import TeesViews

/// Regression coverage for: `SearchScreen.resultsList`'s day-section headers
/// never carried the `.isHeader` accessibility trait, so VoiceOver's rotor
/// "Headings" navigation could not jump between them.
///
/// `resultsList` builds each day as a `Section { ... } header: { Text(...)
/// ... }`. The Form-based screens (`AlertAdjustSheet`, `AccountScreen`) use
/// the plain `Section("Title")` string initialiser and get the header trait
/// for free from SwiftUI/UIKit. This screen's custom header — needed for the
/// custom font and the day-vs-spoken-day label split — opted out of that
/// automatic treatment, and nothing added the trait back.
///
/// **Why this doesn't render the real `List` and walk its live accessibility
/// tree**, the way `SearchScreenPullToRefreshTests` walks a real
/// `UIRefreshControl`: confirmed empirically (an earlier version of this
/// file did exactly that) that a `List` hosted off-screen by a plain
/// `XCTestCase` — no XCUITest, no assistive-technology client attached —
/// never actually materialises UIKit's internal accessibility element graph.
/// `accessibilityElementCount()`/`accessibilityElements` report empty for
/// *every* node in the rendered tree, header or not, fixed or not, because
/// that graph is built lazily and only for a connected AT client (VoiceOver,
/// Accessibility Inspector) — which this sandbox has no way to attach.
/// `UIRefreshControl` detection works in that other file because it reads a
/// plain UIKit object-graph property, not the accessibility subsystem.
///
/// So this tests `SearchScreen.dayHeader(for:)` directly — the exact value
/// `resultsList`'s `header:` closure builds, pulled out to a name for
/// exactly this reason (see its doc comment) — the same way
/// `TeesButtonStyleTests` proves a button style's configuration via `Mirror`
/// on its own stored properties, never on `.body`. `StateViewsTests`
/// explains why `.body` itself is off the table: reflecting into a fully
/// composed screen's opaque view tree is fragile and breaks on any SDK
/// update. Reflecting into the stored properties of one small, concretely
/// typed value `dayHeader(for:)` returns is a different, far narrower thing:
/// `.accessibilityAddTraits` stores the trait set it was given as a plain
/// `Optional` field inside `AccessibilityAttachmentModifier` — nil when no
/// trait was ever added, non-nil once one is — so finding that field
/// non-nil is a real, direct assertion that some `.accessibilityAddTraits`
/// call reached this value, not a guess at internal view types.
@MainActor
final class SearchScreenSectionHeaderAccessibilityTests: XCTestCase {

    /// The three day sections `SearchScreenTests` also fixes its clock to,
    /// read by their spoken (VoiceOver) label — what `.accessibilityLabel`
    /// on the header replaces the short on-screen title with.
    private let fixedNow = ContractDate.date(from: "2099-10-03T00:00:00+10:00")!

    private func sections() -> [SlotDaySection] {
        let now = fixedNow
        let store = SearchStore(preferences: InMemoryViewsStore(), fixture: "minimal", now: { now })
        store.load()
        return store.sections
    }

    /// Depth-first walk of `value`'s own stored properties via `Mirror` —
    /// never `.body` — looking for a non-nil
    /// `AccessibilityNullableOptionSet<AccessibilityTraitSet>` anywhere
    /// inside it. That type is how SwiftUI stores the traits argument given
    /// to `.accessibilityAddTraits`/`.accessibilityRemoveTraits`; it reads
    /// back `nil` when no such call ever touched this value, and non-nil
    /// once one did. `Mirror(reflecting:)` on an `Optional` yields zero
    /// children when it is `nil` and one `"some"` child (the unwrapped
    /// value) when it isn't, so a nil traits field simply never produces a
    /// descendant here to find — which is exactly the pre-fix shape.
    private func hasAnyAccessibilityTraitsSet(_ value: Any) -> Bool {
        if String(describing: type(of: value)).hasPrefix("AccessibilityNullableOptionSet<") {
            return true
        }
        for child in Mirror(reflecting: value).children {
            if hasAnyAccessibilityTraitsSet(child.value) { return true }
        }
        return false
    }

    /// The defect itself: before the fix, nothing in `dayHeader(for:)`'s
    /// modifier chain ever calls `.accessibilityAddTraits`, so no traits
    /// option set exists anywhere in its reflected structure — this fails
    /// against that code. After adding `.accessibilityAddTraits(.isHeader)`,
    /// the field this walk is looking for exists and is non-nil.
    func testEachDaySectionHeaderCarriesTheHeaderTrait() throws {
        let daySections = sections()
        XCTAssertFalse(daySections.isEmpty, "fixture produced no day sections to check")

        for section in daySections {
            let header = SearchScreen.dayHeader(for: section)
            XCTAssertTrue(
                hasAnyAccessibilityTraitsSet(header),
                """
                SearchScreen.dayHeader(for:) for "\(section.title)" carries no accessibility \
                traits at all — VoiceOver's rotor "Headings" navigation cannot jump to this day \
                section because nothing ever calls .accessibilityAddTraits(.isHeader) on it.
                """)
        }
    }

    /// The label split survives the fix: the header still speaks the full
    /// day ("Saturday 3 October"), never the short on-screen one ("Today") a
    /// heading read alone and out of context would be ambiguous as.
    func testHeaderStillSpeaksTheFullDayNotTheShortOnScreenTitle() {
        for section in sections() {
            let spoken = SlotFormatting.spokenDayTitle(for: section.date)
            XCTAssertNotEqual(
                spoken,
                section.title,
                "the header must speak the full day, not repeat the short on-screen title")
        }
    }
}
