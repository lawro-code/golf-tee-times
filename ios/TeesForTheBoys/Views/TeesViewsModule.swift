import Foundation

/// Track C — screens.
///
/// Search, sign-in, onboarding, alert-from-search, did-you-book, upcoming
/// rounds. Everything here is driven by `ContractLoader.fixture`: the module
/// does not link `TeesData` and has no network of any kind. Stage 2 wires the
/// real store in behind the same shapes.
///
/// ## The spine (ticket C1)
///
/// | Type | What it is for |
/// |---|---|
/// | `SearchFilters` | What the golfer asked for. Pure value, `Codable`, no clock. |
/// | `SlotQuery` | Filtering, ordering, day-grouping. Pure functions. |
/// | `SlotFormatting` | Every string a row shows, and the accessibility sentence. |
/// | `FreshnessSummary` | Reached-but-empty vs. could-not-reach, and the banner copy. |
/// | `SearchStore` | The `@MainActor` object the screens observe. |
/// | `ViewsPreferences` | The track's only persistence seam. |
/// | `ViewsLoadingState` and friends | The four generic state views. |
///
/// ## Why so little of this is a `View`
///
/// `ios/project.yml` is frozen for Stage 1, so the track has no ViewInspector
/// and no snapshot library — a SwiftUI `body` is effectively untestable here.
/// Every decision worth asserting on therefore lives in a pure type or in the
/// store, and the views are left thin enough that reading them is enough.
public enum TeesViewsModule {
    /// Bumped off Stage 0's `"0"` when the search spine landed.
    public static let version = "1.0.0"
}
