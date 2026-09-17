import XCTest
@testable import TeesDesign

/// Stage 0 placeholder so the test bundle is not empty. The track that owns
/// this directory should replace it with tests that actually prove something.
final class TeesDesignSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertFalse(TeesDesignModule.version.isEmpty)
    }
}
