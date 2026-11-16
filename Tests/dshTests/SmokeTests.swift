import XCTest
@testable import DSHCore

final class SmokeTests: XCTestCase {
    func testSmokeHarness() {
        XCTAssertEqual(Smoke.run(), 0)
    }
}
