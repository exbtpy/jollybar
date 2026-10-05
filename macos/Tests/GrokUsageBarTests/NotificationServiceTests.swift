import XCTest
@testable import GrokUsageBar

final class NotificationServiceTests: XCTestCase {
    func testNoAlertWhenOff() {
        XCTAssertNil(crossedWeeklyThreshold(threshold: 0, previous: 10, current: 90))
    }

    func testFiresWhenCrossing() {
        XCTAssertEqual(
            crossedWeeklyThreshold(threshold: 80, previous: 70, current: 85),
            ThresholdAlert(window: "Weekly", pct: 85)
        )
    }

    func testNoAlertWhenStayingAbove() {
        XCTAssertNil(crossedWeeklyThreshold(threshold: 80, previous: 85, current: 90))
    }

    func testNoAlertWhenStayingBelow() {
        XCTAssertNil(crossedWeeklyThreshold(threshold: 80, previous: 50, current: 70))
    }

    func testExactThresholdTriggers() {
        XCTAssertEqual(
            crossedWeeklyThreshold(threshold: 80, previous: 79, current: 80),
            ThresholdAlert(window: "Weekly", pct: 80)
        )
    }

    func testFirstPollFiresWhenAlreadyAboveThreshold() {
        XCTAssertEqual(
            crossedWeeklyThreshold(threshold: 25, previous: 0, current: 60),
            ThresholdAlert(window: "Weekly", pct: 60)
        )
    }

    func testFirstPollDoesNotFireWhenBelowThreshold() {
        XCTAssertNil(crossedWeeklyThreshold(threshold: 80, previous: 0, current: 30))
    }

    func testAnAppBundleIsSupported() throws {
        let bundle = try fixtureBundle(packageType: "APPL")
        XCTAssertTrue(supportsUserNotifications(bundle: bundle))
    }

    func testSupportDoesNotDependOnThePathExtension() throws {
        for name in ["Renamed", "Upper.APP", "NoExtension"] {
            let bundle = try fixtureBundle(packageType: "APPL", directoryName: name)
            XCTAssertTrue(supportsUserNotifications(bundle: bundle), "should support \(name)")
        }
    }

    func testAnAppExtensionIsNotSupported() throws {
        let bundle = try fixtureBundle(packageType: "XPC!", directoryName: "Thing.appex")
        XCTAssertFalse(supportsUserNotifications(bundle: bundle))
    }

    func testABundleWithNoPackageTypeIsNotSupported() throws {
        let bundle = try fixtureBundle(packageType: nil)
        XCTAssertFalse(supportsUserNotifications(bundle: bundle))
    }

    /// Regression: this call aborted the whole test process with SIGABRT
    /// ("bundleProxyForCurrentProcess is nil"): under xctest Bundle.main is
    /// /Applications/Xcode.app/Contents/Developer/usr/bin, which has an
    /// identifier, so the old identifier-only guard let it
    /// reach UNUserNotificationCenter.current().
    @MainActor
    func testConstructingTheServiceWithoutAnAppBundleDoesNotAbort() {
        let service = NotificationService()
        XCTAssertFalse(service.isAvailable, "the test host is not an app bundle")
    }

    private func fixtureBundle(
        packageType: String?,
        directoryName: String = "Fixture.app"
    ) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        var info: [String: Any] = ["CFBundleIdentifier": "com.example.fixture"]
        if let packageType { info["CFBundlePackageType"] = packageType }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        return try XCTUnwrap(Bundle(url: root))
    }
}
