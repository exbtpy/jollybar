import Foundation
import XCTest
@testable import GrokUsageBar

final class AppIdentityTests: XCTestCase {
    func testSwiftConstantsMatchIdentityFile() throws {
        let root = try Self.repositoryRoot()
        let values = try Self.parseIdentity(root.appendingPathComponent("macos/identity.env"))

        XCTAssertEqual(values["APP_PRODUCT_NAME"], AppIdentity.productName)
        XCTAssertEqual(values["APP_EXECUTABLE_NAME"], AppIdentity.executableName)
        XCTAssertEqual(values["APP_DISPLAY_NAME"], AppIdentity.displayName)
        XCTAssertEqual(values["APP_MENU_TITLE"], AppIdentity.menuTitle)
        XCTAssertEqual(values["APP_BUNDLE_ID"], AppIdentity.bundleIdentifier)
        XCTAssertEqual(values["DMG_NAME"], AppIdentity.diskImageName)
        XCTAssertEqual(values["CONFIG_DIR_NAME"], AppIdentity.configDirectoryName)

        let plist = try String(contentsOf: root.appendingPathComponent("macos/Resources/Info.plist"), encoding: .utf8)
        XCTAssertTrue(plist.contains("<string>\(AppIdentity.bundleIdentifier)</string>"))
        XCTAssertTrue(plist.contains("<string>\(AppIdentity.productName)</string>"))
        XCTAssertTrue(plist.contains("<string>\(AppIdentity.displayName)</string>"))
        XCTAssertTrue(plist.contains("<string>\(AppUpdater.publicKeyPlaceholder)</string>"))

        let package = try String(contentsOf: root.appendingPathComponent("macos/Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains("name: \"\(AppIdentity.productName)\""))

        let buildScript = try String(contentsOf: root.appendingPathComponent("macos/scripts/build.sh"), encoding: .utf8)
        XCTAssertTrue(buildScript.contains(AppUpdater.upstreamSparklePublicKey))
        XCTAssertTrue(buildScript.contains(AppUpdater.publicKeyPlaceholder))

        let cask = try String(contentsOf: root.appendingPathComponent("Casks/\(AppIdentity.configDirectoryName).rb"), encoding: .utf8)
        XCTAssertTrue(cask.contains("cask \"\(AppIdentity.configDirectoryName)\""))
        XCTAssertTrue(cask.contains("app \"\(AppIdentity.productName).app\""))
    }

    /// `#filePath` is `<repo>/macos/Tests/GrokUsageBarTests/<file>.swift`.
    private static func repositoryRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let identity = root.appendingPathComponent("macos/identity.env")
        guard FileManager.default.fileExists(atPath: identity.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
    }

    private static func parseIdentity(_ url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            var value = String(line[line.index(after: equals)...])
            if value.count >= 2,
               (value.hasPrefix("'") && value.hasSuffix("'"))
                || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }
}
