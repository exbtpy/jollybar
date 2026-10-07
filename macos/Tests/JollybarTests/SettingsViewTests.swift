import XCTest
@testable import Jollybar

final class SettingsViewTests: XCTestCase {
    func testSupportsLaunchAtLoginManagementForSystemApplications() {
        XCTAssertTrue(
            supportsLaunchAtLoginManagement(
                appURL: URL(fileURLWithPath: "/Applications/Jollybar.app"),
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
                appURL: URL(fileURLWithPath: "/Users/test/Applications/Jollybar.app"),
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
                appURL: URL(fileURLWithPath: "/Users/test/Downloads/Jollybar.app"),
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

    // MARK: - Window height

    /// A scaled 13-inch MacBook Air leaves about 800pt of visible frame.
    func testContentHeightsFitAThirteenInchMacBookAir() {
        let heights = SettingsLayout.contentHeights(visibleHeight: 800)

        XCTAssertEqual(heights.minimum, 320)
        XCTAssertEqual(heights.ideal, 640)
        XCTAssertEqual(heights.maximum, 752)
        XCTAssertLessThanOrEqual(heights.ideal + SettingsLayout.titleBarAllowance, 800)
        XCTAssertLessThanOrEqual(heights.maximum + SettingsLayout.titleBarAllowance, 800)
        XCTAssertLessThanOrEqual(heights.minimum, heights.ideal)
        XCTAssertLessThanOrEqual(heights.ideal, heights.maximum)
    }

    func testContentHeightsStayPreferredOnALargeScreen() {
        let heights = SettingsLayout.contentHeights(visibleHeight: 1200)

        XCTAssertEqual(heights.minimum, SettingsLayout.minimumContentHeight)
        XCTAssertEqual(heights.ideal, SettingsLayout.preferredContentHeight)
        XCTAssertEqual(heights.maximum, 1200 - SettingsLayout.titleBarAllowance)
        XCTAssertLessThan(heights.ideal, heights.maximum)
    }

    func testContentHeightsShrinkOnAShortScreen() {
        let heights = SettingsLayout.contentHeights(visibleHeight: 500)

        XCTAssertEqual(heights.maximum, 452)
        XCTAssertEqual(heights.ideal, 452)
        XCTAssertEqual(heights.minimum, SettingsLayout.minimumContentHeight)
        XCTAssertLessThanOrEqual(heights.maximum + SettingsLayout.titleBarAllowance, 500)
    }

    func testContentHeightsStayInsideATinyVisibleFrame() {
        let heights = SettingsLayout.contentHeights(visibleHeight: 100)

        XCTAssertEqual(heights.minimum, 52)
        XCTAssertEqual(heights.ideal, 52)
        XCTAssertEqual(heights.maximum, 52)
        XCTAssertLessThanOrEqual(heights.maximum + SettingsLayout.titleBarAllowance, 100)
    }

    func testContentHeightsTreatAMissingScreenAsALaptopFrame() {
        let heights = SettingsLayout.contentHeights(visibleHeight: .nan)
        let fallback = SettingsLayout.contentHeights(visibleHeight: SettingsLayout.fallbackVisibleHeight)

        XCTAssertEqual(heights, fallback)
    }

    func testClampedContentSizeKeepsAWindowThatAlreadyFits() {
        let size = SettingsLayout.clampedContentSize(
            currentWidth: 480,
            currentHeight: 500,
            visibleHeight: 800
        )

        XCTAssertEqual(size.width, 480)
        XCTAssertEqual(size.height, 500)
    }

    func testClampedContentSizePullsAnOverflowingWindowInsideTheVisibleFrame() {
        let size = SettingsLayout.clampedContentSize(
            currentWidth: 440,
            currentHeight: 1400,
            visibleHeight: 800
        )

        XCTAssertEqual(size.width, SettingsLayout.windowWidth)
        XCTAssertEqual(size.height, 640)
        XCTAssertLessThanOrEqual(size.height + SettingsLayout.titleBarAllowance, 800)
    }

    func testClampedContentSizeRaisesAWindowThatIsTooShort() {
        let size = SettingsLayout.clampedContentSize(
            currentWidth: 200,
            currentHeight: 80,
            visibleHeight: 800
        )

        XCTAssertEqual(size.width, SettingsLayout.windowWidth)
        XCTAssertEqual(size.height, 640)
    }

    func testAdvancedCursorSettingsStayCollapsedUntilNeeded() {
        XCTAssertFalse(SettingsLayout.expandsAdvancedCursorSettings(configured: false, hasError: false))
        XCTAssertTrue(SettingsLayout.expandsAdvancedCursorSettings(configured: true, hasError: false))
        XCTAssertTrue(SettingsLayout.expandsAdvancedCursorSettings(configured: false, hasError: true))
    }
}
