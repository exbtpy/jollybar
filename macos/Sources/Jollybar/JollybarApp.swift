import SwiftUI

@main
struct JollybarApp: App {
    /// Runs before the services and `@AppStorage` read the old config, preferences, or Keychain.
    private let migrated: Bool = {
        IdentityMigration.migrateIfNeeded()
        return true
    }()
    @StateObject private var service = UsageService()
    @StateObject private var historyService = UsageHistoryService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var appUpdater = AppUpdater()
    @AppStorage(MenuTheme.defaultsKey) private var menuThemeRaw = MenuTheme.classic.rawValue

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                service: service,
                historyService: historyService,
                notificationService: notificationService,
                appUpdater: appUpdater
            )
        } label: {
            Image(nsImage: renderIcon(
                topFraction: service.topFraction,
                topLabel: service.topLabel,
                bottomFraction: service.bottomFraction,
                bottomLabel: service.bottomLabel,
                theme: MenuTheme(rawValue: menuThemeRaw) ?? .classic,
                mood: service.companionMood
            ))
                .accessibilityLabel(
                    MenuTheme(rawValue: menuThemeRaw) == .companion
                        ? AppIdentity.companionName
                        : AppIdentity.displayName
                )
                .task {
                    _ = migrated
                    if service.isAuthenticated && !UserDefaults.standard.bool(forKey: "setupComplete") {
                        UserDefaults.standard.set(true, forKey: "setupComplete")
                    }
                    historyService.loadHistory()
                    service.historyService = historyService
                    service.notificationService = notificationService
                    service.startPolling()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindowContent(
                service: service,
                notificationService: notificationService,
                appUpdater: appUpdater
            )
        }
        .windowResizability(.automatic)
        .defaultSize(width: SettingsLayout.windowWidth, height: SettingsLayout.openingContentHeight)
        .windowStyle(.titleBar)
    }
}
