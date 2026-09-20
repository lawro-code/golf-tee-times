import TeesViews
import XCTest
@testable import TeesForTheBoys

/// Regression coverage for the cold-launch race between `AppSession.start()`
/// and `SearchScreen.onAppear`.
///
/// `TeesForTheBoysApp.body` mounts `TeesRootView` (and, inside it,
/// `SearchScreen`) and only *schedules* the real data pipeline —
/// `.task { await session.start() }` enqueues `start()`'s body, it does not
/// run any part of it inline. `SearchScreen.onAppear` fires synchronously in
/// that same view-attachment pass and, whenever `store.state == .idle` (the
/// store's own initial value), calls `store.load()` — which decodes the
/// bundled `golden.json` fixture (15 courses, 1755 slots) unconditionally.
/// `start()` has real async work — `makeTeeTimeStore()`,
/// `SupabaseClientProvider.client()`, `await auth.restoreSession()` — before
/// its own first write to `searchStore.state`, so on a real device this gap
/// was wide enough for `onAppear` to win the race every time: a fully
/// populated, fabricated tee-time list flashed on screen in place of the
/// loading state, then vanished a frame later.
///
/// Hosted by the app (`TEST_HOST` in `ios/project.yml`) on purpose:
/// `AppSession` is the one place `TeesData` and `TeesViews` are both visible,
/// same as `PushRouteTabTests`.
@MainActor
final class AppSessionColdLaunchTests: XCTestCase {

    /// Mirrors the exact shape `TeesForTheBoysApp.swift` and
    /// `SearchScreen.swift` run — an unawaited `Task` around `start()`, then a
    /// synchronous `state == .idle` check straight after — without needing a
    /// live Supabase client or a rendered view: a `Task` never runs its body
    /// inline, so by the line after it is created, nothing inside `start()`
    /// has executed, no matter what `makeTeeTimeStore` eventually does or
    /// throws.
    func testOnAppearNeverLoadsTheBundledFixtureWhileStartIsInFlight() {
        let session = AppSession(makeTeeTimeStore: { throw ColdLaunchTestStoreFailure() })

        // `.task { await session.start() }`, unawaited.
        Task { await session.start() }

        XCTAssertNotEqual(
            session.searchStore.state, .idle,
            """
            searchStore.state is still .idle immediately after AppSession's \
            init returns, before start() has run at all — \
            SearchScreen.onAppear's `if store.state == .idle { store.load() }` \
            guard is still true here and will fire.
            """)

        // SearchScreen.onAppear, verbatim.
        if session.searchStore.state == .idle {
            session.searchStore.load()
        }

        XCTAssertNil(
            session.searchStore.payload,
            """
            the bundled golden.json fixture (15 courses, 1755 slots) loaded \
            onto screen in place of the loading state, on the exact \
            precondition this covers: an empty feed on a fresh cold launch.
            """)
    }
}

private struct ColdLaunchTestStoreFailure: Error {}
