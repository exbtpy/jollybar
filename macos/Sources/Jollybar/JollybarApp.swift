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
    @AppStorage(MenuTheme.defaultsKey) private var menuThemeRaw = MenuTheme.defaultTheme.rawValue

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                service: service,
                historyService: historyService,
                notificationService: notificationService,
                appUpdater: appUpdater
            )
        } label: {
            MenuBarLabel(
                theme: MenuTheme(rawValue: menuThemeRaw) ?? .companion,
                mood: service.companionMood,
                usedPercent: service.sandOwnsTopSlot
                    ? service.dashboardReading?.grokBotPercent
                    : service.cursorReading?.usedPercent,
                topFraction: service.topFraction,
                topLabel: service.topLabel,
                bottomFraction: service.bottomFraction,
                bottomLabel: service.bottomLabel
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

struct MenuBarLabel: View {
    let theme: MenuTheme
    let mood: CompanionMood
    let usedPercent: Double?
    let topFraction: Double?
    let topLabel: String
    let bottomFraction: Double?
    let bottomLabel: String

    var body: some View {
        if theme == .companion {
            let text = UsageNumber.menuText(usedPercent: usedPercent)
            let tint = JollyTheme.menuTint(mood: mood, usedPercent: usedPercent)?.nsColor
            Image(nsImage: renderCompanionStatusIcon(mood: mood, percentText: text, tint: tint))
                .accessibilityLabel(accessibilityText(percent: text))
        } else {
            Image(nsImage: renderIcon(
                topFraction: topFraction,
                topLabel: topLabel,
                bottomFraction: bottomFraction,
                bottomLabel: bottomLabel,
                theme: .classic,
                mood: mood
            ))
            .accessibilityLabel(AppIdentity.displayName)
        }
    }

    private func accessibilityText(percent: String) -> String {
        if percent == "—" {
            return "\(AppIdentity.companionName), \(mood.caption)"
        }
        return "\(AppIdentity.companionName), \(percent), \(mood.caption)"
    }
}
