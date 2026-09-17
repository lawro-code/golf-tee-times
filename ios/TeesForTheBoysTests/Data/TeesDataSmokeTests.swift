import XCTest
@testable import TeesData

/// Stage 0 placeholder so the test bundle is not empty. The track that owns
/// this directory should replace it with tests that actually prove something.
final class TeesDataSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertFalse(TeesDataModule.version.isEmpty)
    }
}
