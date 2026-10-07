import Security
import XCTest
@testable import Jollybar

final class IdentityMigrationTests: XCTestCase {
    private var home: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        home = fileManager.temporaryDirectory
            .appendingPathComponent("jollybar-migration-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        suite = "JollybarMigration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? fileManager.removeItem(at: home)
        super.tearDown()
    }

    func testLegacyNamesStayDistinctFromTheCurrentIdentity() {
        XCTAssertEqual(LegacyIdentity.bundleIdentifier, "com.exbtpy.GrokUsageBar")
        XCTAssertEqual(LegacyIdentity.configDirectoryName, "grok-usage-bar")
        XCTAssertNotEqual(LegacyIdentity.bundleIdentifier, AppIdentity.bundleIdentifier)
        XCTAssertNotEqual(LegacyIdentity.configDirectoryName, AppIdentity.configDirectoryName)
    }

    func testMovesTheConfigDirectoryOnceAndKeepsPermissions() throws {
        let history = try writeHistory(named: "old-history", in: legacyConfigDirectory)
        let perms = try posixPermissions(history)

        migrate()

        let moved = configDirectory.appendingPathComponent("history.json")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "old-history")
        XCTAssertEqual(try posixPermissions(moved), perms)
        XCTAssertFalse(fileManager.fileExists(atPath: legacyConfigDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: markerURL.path))

        try fileManager.createDirectory(at: legacyConfigDirectory, withIntermediateDirectories: true)
        try "later".write(to: legacyConfigDirectory.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
        migrate()
        XCTAssertFalse(fileManager.fileExists(atPath: configDirectory.appendingPathComponent("later.txt").path))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "old-history")
    }

    func testDoesNotReplaceHistoryThatAlreadyExists() throws {
        _ = try writeHistory(named: "old-history", in: legacyConfigDirectory)
        _ = try writeHistory(named: "new-history", in: configDirectory)
        try "note".write(to: legacyConfigDirectory.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        migrate()

        XCTAssertEqual(
            try String(contentsOf: configDirectory.appendingPathComponent("history.json"), encoding: .utf8),
            "new-history"
        )
        XCTAssertEqual(
            try String(contentsOf: configDirectory.appendingPathComponent("note.txt"), encoding: .utf8),
            "note"
        )
        XCTAssertTrue(fileManager.fileExists(atPath: legacyConfigDirectory.appendingPathComponent("history.json").path))

        try "after".write(to: legacyConfigDirectory.appendingPathComponent("after.txt"), atomically: true, encoding: .utf8)
        migrate()
        XCTAssertFalse(fileManager.fileExists(atPath: configDirectory.appendingPathComponent("after.txt").path))
    }

    func testDoesNotReplaceAFileOccupyingTheNewConfigPath() throws {
        try fileManager.createDirectory(
            at: configDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "keep".write(to: configDirectory, atomically: true, encoding: .utf8)
        _ = try writeHistory(named: "old-history", in: legacyConfigDirectory)

        migrate()

        XCTAssertEqual(try String(contentsOf: configDirectory, encoding: .utf8), "keep")
        XCTAssertTrue(fileManager.fileExists(atPath: legacyConfigDirectory.appendingPathComponent("history.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: markerURL.path))
    }

    func testCopiesMissingPreferenceKeysAndLeavesExistingOnes() throws {
        defaults.set(15, forKey: "pollingMinutes")
        try writeLegacyPreferences([
            "pollingMinutes": 5,
            "menuTheme": "companion",
            "notificationThresholdBot": 80
        ])

        migrate()

        XCTAssertEqual(defaults.integer(forKey: "pollingMinutes"), 15)
        XCTAssertEqual(defaults.string(forKey: "menuTheme"), "companion")
        XCTAssertEqual(defaults.integer(forKey: "notificationThresholdBot"), 80)
        XCTAssertTrue(defaults.bool(forKey: IdentityMigration.preferencesMarker))

        try writeLegacyPreferences([
            "pollingMinutes": 5,
            "notificationThresholdBot": 95,
            "cursorMemberEmail": "person@example.com"
        ])
        migrate()

        XCTAssertEqual(defaults.integer(forKey: "pollingMinutes"), 15)
        XCTAssertEqual(defaults.integer(forKey: "notificationThresholdBot"), 80)
        XCTAssertNil(defaults.string(forKey: "cursorMemberEmail"))
    }

    func testUnreadableLegacyPreferencesAreRetried() throws {
        let plist = legacyPreferencesURL
        try fileManager.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not a plist".write(to: plist, atomically: true, encoding: .utf8)

        migrate()
        XCTAssertFalse(defaults.bool(forKey: IdentityMigration.preferencesMarker))

        try fileManager.removeItem(at: plist)
        try writeLegacyPreferences(["notificationThresholdWeekly": 90])
        migrate()
        XCTAssertEqual(defaults.integer(forKey: "notificationThresholdWeekly"), 90)
        XCTAssertTrue(defaults.bool(forKey: IdentityMigration.preferencesMarker))
    }

    func testKeychainCopyIsIdempotentAndDoesNotClobber() {
        let keychain = FakeKeychain()
        keychain.values[keychain.key(LegacyIdentity.bundleIdentifier, ManagementSecret.account)] = "mgmt-secret"
        keychain.values[keychain.key(LegacyIdentity.bundleIdentifier, CursorSecret.account)] = "cursor-secret"
        keychain.values[keychain.key(AppIdentity.bundleIdentifier, CursorSecret.account)] = "already-saved"

        migrate(keychain: keychain)

        XCTAssertEqual(
            keychain.values[keychain.key(AppIdentity.bundleIdentifier, ManagementSecret.account)],
            "mgmt-secret"
        )
        XCTAssertEqual(
            keychain.values[keychain.key(AppIdentity.bundleIdentifier, CursorSecret.account)],
            "already-saved"
        )
        XCTAssertEqual(
            keychain.values[keychain.key(LegacyIdentity.bundleIdentifier, ManagementSecret.account)],
            "mgmt-secret"
        )
        XCTAssertTrue(defaults.bool(forKey: IdentityMigration.keychainMarker))

        keychain.values[keychain.key(LegacyIdentity.bundleIdentifier, ManagementSecret.account)] = "rotated"
        migrate(keychain: keychain)
        XCTAssertEqual(
            keychain.values[keychain.key(AppIdentity.bundleIdentifier, ManagementSecret.account)],
            "mgmt-secret"
        )
    }

    func testDeniedKeychainReadIsRetriedOnTheNextLaunch() {
        let keychain = FakeKeychain()
        keychain.values[keychain.key(LegacyIdentity.bundleIdentifier, CursorSecret.account)] = "cursor-secret"
        keychain.unavailableServices.insert(LegacyIdentity.bundleIdentifier)

        migrate(keychain: keychain)
        XCTAssertNil(keychain.values[keychain.key(AppIdentity.bundleIdentifier, CursorSecret.account)])
        XCTAssertFalse(defaults.bool(forKey: IdentityMigration.keychainMarker))

        keychain.unavailableServices.removeAll()
        migrate(keychain: keychain)
        XCTAssertEqual(
            keychain.values[keychain.key(AppIdentity.bundleIdentifier, CursorSecret.account)],
            "cursor-secret"
        )
        XCTAssertTrue(defaults.bool(forKey: IdentityMigration.keychainMarker))
    }

    func testKeychainStatusMappingDoesNotTreatFailureAsMissing() {
        XCTAssertEqual(
            SecurityKeychain.classify(status: errSecItemNotFound, item: nil),
            .missing
        )
        XCTAssertEqual(
            SecurityKeychain.classify(status: errSecSuccess, item: Data("secret".utf8) as CFData),
            .found("secret")
        )
        XCTAssertEqual(
            SecurityKeychain.classify(status: errSecAuthFailed, item: nil),
            .unavailable
        )
        XCTAssertEqual(
            SecurityKeychain.classify(status: errSecSuccess, item: Data() as CFData),
            .missing
        )
        XCTAssertEqual(
            SecurityKeychain.classify(status: errSecSuccess, item: Data([0xFF]) as CFData),
            .unavailable
        )
    }

    private var configDirectory: URL {
        home.appendingPathComponent(".config/\(AppIdentity.configDirectoryName)", isDirectory: true)
    }

    private var legacyConfigDirectory: URL {
        home.appendingPathComponent(".config/\(LegacyIdentity.configDirectoryName)", isDirectory: true)
    }

    private var markerURL: URL {
        configDirectory.appendingPathComponent(IdentityMigration.configMarkerName)
    }

    private var legacyPreferencesURL: URL {
        home.appendingPathComponent("Library/Preferences/\(LegacyIdentity.bundleIdentifier).plist")
    }

    private func migrate(keychain: KeychainCopying = FakeKeychain()) {
        IdentityMigration.migrateIfNeeded(
            fileManager: fileManager,
            homeDirectory: home,
            defaults: defaults,
            keychain: keychain
        )
    }

    @discardableResult
    private func writeHistory(named contents: String, in directory: URL) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func writeLegacyPreferences(_ values: [String: Any]) throws {
        let url = legacyPreferencesURL
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        try data.write(to: url)
    }

    private func posixPermissions(_ url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}

private final class FakeKeychain: KeychainCopying {
    var values: [String: String] = [:]
    var unavailableServices: Set<String> = []

    func key(_ service: String, _ account: String) -> String {
        "\(service)\n\(account)"
    }

    func copyIfAbsent(account: String, fromService: String, toService: String) -> KeychainMigrationStatus {
        if unavailableServices.contains(toService) {
            return .unavailable
        }
        if values[key(toService, account)] != nil {
            return .alreadyPresent
        }
        if unavailableServices.contains(fromService) {
            return .unavailable
        }
        guard let secret = values[key(fromService, account)] else {
            return .absent
        }
        values[key(toService, account)] = secret
        return .copied
    }
}
