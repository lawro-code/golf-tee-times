import XCTest
@testable import TeesPush

/// Stage 0 placeholder so the test bundle is not empty. The track that owns
/// this directory should replace it with tests that actually prove something.
final class TeesPushSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertFalse(TeesPushModule.version.isEmpty)
    }
}
