import SwiftUI

@main
struct GrokUsageBarApp: App {
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
                .task {
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
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }
}
