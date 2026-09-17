import XCTest
@testable import TeesViews

/// Stage 0 placeholder so the test bundle is not empty. The track that owns
/// this directory should replace it with tests that actually prove something.
final class TeesViewsSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertFalse(TeesViewsModule.version.isEmpty)
    }
}
