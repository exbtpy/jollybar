import Foundation
import Security

/// Previous product names. Kept so an existing install keeps its history,
/// preferences, and Keychain items after the rename to Jollybar. Do not point
/// these at the current `AppIdentity` values.
enum LegacyIdentity {
    static let bundleIdentifier = "com.exbtpy.GrokUsageBar"
    static let configDirectoryName = "grok-usage-bar"
}

enum KeychainMigrationStatus: Equatable {
    case copied
    case alreadyPresent
    case absent
    /// The read was denied or failed. The next launch tries again.
    case unavailable
}

protocol KeychainCopying {
    func copyIfAbsent(account: String, fromService: String, toService: String) -> KeychainMigrationStatus
}

enum KeychainRead: Equatable {
    case found(String)
    case missing
    case unavailable
}

struct SecurityKeychain: KeychainCopying {
    func copyIfAbsent(account: String, fromService: String, toService: String) -> KeychainMigrationStatus {
        switch Self.read(service: toService, account: account) {
        case .found:
            return .alreadyPresent
        case .missing:
            break
        case .unavailable:
            return .unavailable
        }

        switch Self.read(service: fromService, account: account) {
        case .found(let secret):
            return Self.write(secret, service: toService, account: account) ? .copied : .unavailable
        case .missing:
            return .absent
        case .unavailable:
            return .unavailable
        }
    }

    static func classify(status: OSStatus, item: CFTypeRef?) -> KeychainRead {
        switch status {
        case errSecSuccess:
            guard let data = data(from: item), let secret = String(data: data, encoding: .utf8) else {
                return .unavailable
            }
            // An empty item is not a saved key. Treat it as absent so launch does not retry it.
            if secret.isEmpty { return .missing }
            return .found(secret)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable
        }
    }

    private static func data(from item: CFTypeRef?) -> Data? {
        if let data = item as? Data { return data }
        guard let item, CFGetTypeID(item) == CFDataGetTypeID() else { return nil }
        return item as! CFData as Data
    }

    private static func read(service: String, account: String) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return classify(status: status, item: item)
    }

    private static func write(_ secret: String, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}

/// One-time copy from the previous bundle id, config directory, and Keychain
/// service. Safe to run on every launch: a marker stops a second pass, and a
/// value that already exists is never replaced.
enum IdentityMigration {
    static let preferencesMarker = "jollybarMigratedLegacyPreferences"
    static let keychainMarker = "jollybarMigratedLegacyKeychain"
    static let configMarkerName = ".migrated-from-grok-usage-bar"

    static let keychainAccounts = [ManagementSecret.account, CursorSecret.account]

    static func migrateIfNeeded(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        keychain: KeychainCopying = SecurityKeychain()
    ) {
        migrateConfigDirectory(fileManager: fileManager, home: homeDirectory)
        migratePreferences(fileManager: fileManager, home: homeDirectory, defaults: defaults)
        migrateKeychain(defaults: defaults, keychain: keychain)
    }

    static func migrateConfigDirectory(fileManager: FileManager, home: URL) {
        let configRoot = home.appendingPathComponent(".config", isDirectory: true)
        let newDir = configRoot.appendingPathComponent(AppIdentity.configDirectoryName, isDirectory: true)
        let oldDir = configRoot.appendingPathComponent(LegacyIdentity.configDirectoryName, isDirectory: true)
        let marker = newDir.appendingPathComponent(configMarkerName)

        if fileManager.fileExists(atPath: marker.path) { return }

        var newIsDirectory: ObjCBool = false
        let newExists = fileManager.fileExists(atPath: newDir.path, isDirectory: &newIsDirectory)
        if newExists && !newIsDirectory.boolValue {
            return
        }

        var oldIsDirectory: ObjCBool = false
        let oldExists = fileManager.fileExists(atPath: oldDir.path, isDirectory: &oldIsDirectory)
        if oldExists && !oldIsDirectory.boolValue {
            guard prepareDirectory(newDir, fileManager: fileManager) else { return }
            writeMarker(marker, fileManager: fileManager)
            return
        }

        if oldExists && !newExists {
            do {
                try fileManager.createDirectory(at: configRoot, withIntermediateDirectories: true)
                try fileManager.moveItem(at: oldDir, to: newDir)
            } catch {
                guard !fileManager.fileExists(atPath: newDir.path) else { return }
                do {
                    try fileManager.copyItem(at: oldDir, to: newDir)
                } catch {
                    return
                }
            }
            writeMarker(marker, fileManager: fileManager)
            return
        }

        if oldExists && newExists {
            guard copyMissing(from: oldDir, to: newDir, fileManager: fileManager) else { return }
            writeMarker(marker, fileManager: fileManager)
            return
        }

        guard prepareDirectory(newDir, fileManager: fileManager) else { return }
        writeMarker(marker, fileManager: fileManager)
    }

    static func migratePreferences(fileManager: FileManager, home: URL, defaults: UserDefaults) {
        if defaults.bool(forKey: preferencesMarker) { return }
        // Flush the previous app's domain so a just-quit process is on disk.
        CFPreferencesAppSynchronize(LegacyIdentity.bundleIdentifier as CFString)

        let plist = home
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(LegacyIdentity.bundleIdentifier).plist")
        guard fileManager.fileExists(atPath: plist.path) else {
            defaults.set(true, forKey: preferencesMarker)
            return
        }
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = object as? [String: Any] else {
            return
        }

        let reserved: Set<String> = [preferencesMarker, keychainMarker]
        for (key, value) in values where !reserved.contains(key) {
            if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: preferencesMarker)
    }

    static func migrateKeychain(defaults: UserDefaults, keychain: KeychainCopying) {
        if defaults.bool(forKey: keychainMarker) { return }
        guard LegacyIdentity.bundleIdentifier != AppIdentity.bundleIdentifier else {
            defaults.set(true, forKey: keychainMarker)
            return
        }

        var retryLater = false
        for account in keychainAccounts {
            let status = keychain.copyIfAbsent(
                account: account,
                fromService: LegacyIdentity.bundleIdentifier,
                toService: AppIdentity.bundleIdentifier
            )
            if status == .unavailable {
                retryLater = true
            }
        }
        if !retryLater {
            defaults.set(true, forKey: keychainMarker)
        }
    }

    private static func prepareDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    private static func writeMarker(_ url: URL, fileManager: FileManager) {
        if fileManager.fileExists(atPath: url.path) { return }
        fileManager.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
    }

    /// Copies items that are missing at the destination. An existing file is
    /// left as it is, including when the older copy differs.
    private static func copyMissing(from source: URL, to destination: URL, fileManager: FileManager) -> Bool {
        let items: [URL]
        do {
            items = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        } catch {
            return false
        }

        for item in items {
            let dest = destination.appendingPathComponent(item.lastPathComponent)
            var sourceIsDirectory: ObjCBool = false
            let sourceExists = fileManager.fileExists(atPath: item.path, isDirectory: &sourceIsDirectory)
            guard sourceExists else { continue }

            var destIsDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dest.path, isDirectory: &destIsDirectory) {
                if sourceIsDirectory.boolValue && destIsDirectory.boolValue {
                    if !copyMissing(from: item, to: dest, fileManager: fileManager) {
                        return false
                    }
                }
                continue
            }

            do {
                try fileManager.copyItem(at: item, to: dest)
            } catch {
                return false
            }
        }
        return true
    }
}
