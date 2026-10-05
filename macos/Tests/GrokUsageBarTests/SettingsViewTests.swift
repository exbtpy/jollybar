import XCTest
@testable import GrokUsageBar

final class SettingsViewTests: XCTestCase {
    func testSupportsLaunchAtLoginManagementForSystemApplications() {
        XCTAssertTrue(
            supportsLaunchAtLoginManagement(
                appURL: URL(fileURLWithPath: "/Applications/GrokUsageBar.app"),
                installDirectories: [
                    URL(fileURLWithPath: "/Applications", isDirectory: true),
                    URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true)
                ]
            )
        )
    }

    func testSupportsLaunchAtLoginManagementForUserApplications() {
        XCTAssertTrue(
            supportsLaunchAtLoginManagement(
                appURL: URL(fileURLWithPath: "/Users/test/Applications/GrokUsageBar.app"),
                installDirectories: [
                    URL(fileURLWithPath: "/Applications", isDirectory: true),
                    URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true)
                ]
            )
        )
    }

    func testDoesNotSupportLaunchAtLoginOutsideApplicationsFolders() {
        XCTAssertFalse(
            supportsLaunchAtLoginManagement(
                appURL: URL(fileURLWithPath: "/Users/test/Downloads/GrokUsageBar.app"),
                installDirectories: [
                    URL(fileURLWithPath: "/Applications", isDirectory: true),
                    URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true)
                ]
            )
        )
    }
    // MARK: - Version string

    /// build.sh derives CFBundleVersion from the version (0.0.10 -> 10), so it
    /// must never be appended — it would only restate the number beside it.
    func testDisplayVersionShowsTheMarketingVersionAlone() {
        XCTAssertEqual(SettingsWindowContent.displayVersion("0.0.10"), "0.0.10")
    }

    func testDisplayVersionTrimsWhitespace() {
        XCTAssertEqual(SettingsWindowContent.displayVersion("  1.2.3  "), "1.2.3")
    }

    func testDisplayVersionFallsBackWhenMissing() {
        XCTAssertEqual(SettingsWindowContent.displayVersion(nil), "unknown")
    }

    func testDisplayVersionFallsBackWhenBlank() {
        XCTAssertEqual(SettingsWindowContent.displayVersion("   "), "unknown")
    }
}
