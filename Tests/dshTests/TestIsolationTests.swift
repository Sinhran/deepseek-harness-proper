import XCTest
@testable import DSHCore

/// Tests must never touch the user's real data, whatever runner starts them
/// (Xcode, `swift test`, CI).
final class TestIsolationTests: XCTestCase {
    func testTestsNeverUseRealAppData() {
        XCTAssertTrue(Settings.isTestRun, "test runner not detected")
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dsh-proper").path
        for dir in [Settings.supportDir, Settings.sessionsDir, Settings.pluginsDir, MCPHub.configFile] {
            XCTAssertFalse(dir.path.hasPrefix(real), "\(dir.path) is the real app data folder")
        }
        XCTAssertEqual(Settings.shared.apiKey, "", "the real Keychain API key is never read in tests")
    }
}
