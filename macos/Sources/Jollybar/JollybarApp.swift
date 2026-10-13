import SwiftUI

@main
struct JollybarApp: App {
    /// Runs before the services and `@AppStorage` read the old config, preferences, or Keychain.
    private let migrated: Bool = {
        IdentityMigration.migrateIfNeeded()
        MenuBarStyleMigration.migrateIfNeeded()
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
                theme: MenuTheme.resolve(menuThemeRaw),
                mood: service.companionMood,
                usedPercent: service.sandOwnsTopSlot
                    ? service.dashboardReading?.grokBotPercent
                    : service.cursorReading?.usedPercent,
                usageWindowStart: UsagePace.resolvedStart(
                    periodStart: service.sandOwnsTopSlot ? service.dashboardReading?.periodStart : nil,
                    reset: service.sandOwnsTopSlot ? service.dashboardReading?.resetsAt : service.cursorReading?.resetsAt
                ),
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
    let usageWindowStart: Date?
    let topFraction: Double?
    let topLabel: String
    let bottomFraction: Double?
    let bottomLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(BudMomentStore.enabledKey) private var momentsEnabled = true
    @StateObject private var power = PowerState()
    @StateObject private var moments = BudMomentPlayer()

    var body: some View {
        Group {
            switch theme {
            case .percent:
                percentItem
            case .bars:
                barsItem
            case .companion:
                MenuBarCompanionItem(
                    mood: mood,
                    usedPercent: usedPercent,
                    usageWindowStart: usageWindowStart,
                    moment: moments.pose,
                    momentActive: moments.isPlaying
                )
            }
        }
        .onAppear { syncMoments() }
        .onDisappear { moments.stop() }
        .onChange(of: reduceMotion) { _, _ in syncMoments() }
        .onChange(of: power.isLowPowerMode) { _, _ in syncMoments() }
        .onChange(of: momentsEnabled) { _, _ in syncMoments() }
        .onChange(of: mood) { _, newValue in
            moments.noteMood(newValue)
        }
        .onChange(of: usedPercent) { _, _ in
            moments.noteUsage(percent: usedPercent, windowStart: usageWindowStart)
        }
        .onChange(of: usageWindowStart) { _, _ in
            moments.noteUsage(percent: usedPercent, windowStart: usageWindowStart)
        }
        .onHover { inside in
            if inside { moments.noteHover() }
        }
        .background(MenuBarHoverCatcher { moments.noteHover() })
    }

    private var percentItem: some View {
        let text = UsageNumber.menuText(usedPercent: usedPercent)
        let tint = JollyTheme.menuTint(mood: mood, usedPercent: usedPercent)?.nsColor
        return Image(nsImage: renderCompanionStatusIcon(
            mood: mood,
            percentText: text,
            tint: tint,
            moment: moments.pose
        ))
        .accessibilityLabel(accessibilityText(percent: text))
    }

    private var barsItem: some View {
        let tint = JollyTheme.menuTint(mood: mood, usedPercent: usedPercent)?.nsColor
        return Image(nsImage: renderIcon(
            topFraction: topFraction,
            topLabel: topLabel,
            bottomFraction: bottomFraction,
            bottomLabel: bottomLabel,
            mouthFraction: MenuBarMouth.fraction(usedPercent: usedPercent),
            tint: tint,
            moment: moments.pose
        ))
        .accessibilityLabel(AppIdentity.displayName)
    }

    private func syncMoments() {
        let allows = momentsEnabled && MotionPolicy.allowsMotion(
            reduceMotion: reduceMotion,
            lowPower: power.isLowPowerMode
        )
        moments.setAllowsMoments(allows)
        moments.noteDayMark()
        moments.noteMood(mood)
        moments.noteUsage(percent: usedPercent, windowStart: usageWindowStart)
    }

    private func accessibilityText(percent: String) -> String {
        if percent == "—" {
            return "\(AppIdentity.companionName), \(mood.caption)"
        }
        return "\(AppIdentity.companionName), \(percent), \(mood.caption)"
    }
}
