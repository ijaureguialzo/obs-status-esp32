import XCTest

@testable import ObsStatus

final class ObsStatusVersionTests: XCTestCase {
    /// The exact values depend on the local git-ignored version.txt (or the
    /// 1.0.0 / 1 fallback in CI), so only the "X (Y)" shape is asserted.
    func testDisplayFormat() {
        XCTAssertFalse(ObsStatusVersion.version.isEmpty)
        XCTAssertFalse(ObsStatusVersion.build.isEmpty)
        XCTAssertTrue(ObsStatusVersion.display.contains("("), ObsStatusVersion.display)
        XCTAssertTrue(ObsStatusVersion.display.hasSuffix(")"), ObsStatusVersion.display)
        XCTAssertEqual(ObsStatusVersion.display,
                       "\(ObsStatusVersion.version) (\(ObsStatusVersion.build))")
    }
}
