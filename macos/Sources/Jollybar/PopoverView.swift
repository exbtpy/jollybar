import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var appUpdater: AppUpdater
    @AppStorage("setupComplete") private var setupComplete = false
    @AppStorage(MenuTheme.defaultsKey) private var menuThemeRaw = MenuTheme.defaultTheme.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var theme: MenuTheme {
        MenuTheme.resolve(menuThemeRaw)
    }

    var body: some View {
        if !setupComplete && !service.isAuthenticated && !service.cursorConfigured {
            SetupView(
                service: service,
                notificationService: notificationService,
                onComplete: { setupComplete = true }
            )
            .padding()
            .frame(width: theme.showsCompanionPopover ? 320 : 360)
            .background(theme.showsCompanionPopover ? JollyTheme.background(colorScheme) : Color.clear)
        } else if theme.showsCompanionPopover {
            CompanionScreen(
                service: service,
                historyService: historyService,
                appUpdater: appUpdater
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                header
                usageView
            }
            .padding()
            .frame(width: 360)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(AppIdentity.menuTitle))
                .font(.headline)
            if let tier = service.reading?.subscriptionTier, !tier.isEmpty {
                Text(tier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let email = service.accountEmail ?? service.dashboardReading?.accountEmail {
                Text(email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var usageView: some View {
        meterRow(
            title: service.sandOwnsTopSlot
                ? L10n.text("meter.grokBot", "Grok Bot")
                : (service.cursorConfigured
                    ? L10n.text("meter.grokBotSpend", "Grok Bot spend")
                    : L10n.text("meter.grokBot", "Grok Bot")),
            percent: service.sandOwnsTopSlot ? service.dashboardReading?.grokBotPercent : service.cursorReading?.usedPercent,
            fraction: service.topFraction,
            detail: service.sandOwnsTopSlot ? nil : service.cursorReading?.amountDetail,
            reset: service.sandOwnsTopSlot ? service.dashboardReading?.resetsAt : service.cursorReading?.resetsAt,
            footnote: botFootnote,
            status: botStatus
        )

        meterRow(
            title: service.showsSuperGrokPool
                ? L10n.text("meter.superGrok", "SuperGrok")
                : L10n.text("meter.cursorModels", "Cursor Models"),
            percent: service.showsSuperGrokPool ? service.reading?.usedPercent : service.dashboardReading?.cursorModelsPercent,
            fraction: service.bottomFraction,
            detail: nil,
            reset: service.showsSuperGrokPool ? service.reading?.resetsAt : nil,
            footnote: nil,
            status: bottomStatus
        )

        if hasDetails {
            DisclosureGroup(L10n.text("section.details", "Details")) {
                details
            }
            .font(.caption)
        }

        Divider()
        UsageChartView(
            historyService: historyService,
            showsWeeklyPool: service.showsSuperGrokPool
        )

        if let updaterError = appUpdater.lastError {
            Divider()
            Label(updaterError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        HStack(spacing: 12) {
            if let updated = service.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }

        HStack(spacing: 8) {
            settingsButton
            Spacer()
            Button(L10n.text("footer.refresh", "Refresh")) {
                Task { await service.fetchUsage(refreshCursor: true) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Button(L10n.text("settings.checkNow", "Check for Updates…")) {
                appUpdater.checkForUpdates()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(!appUpdater.isConfigured)
            Button(L10n.text("footer.quit", "Quit")) { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var botFootnote: String? {
        guard !service.sandOwnsTopSlot, service.cursorReading?.resetIsAssumedMonthly == true else { return nil }
        return L10n.text(
            "meter.assumedMonthly",
            "Cycle end is the next calendar month after the billing-cycle start."
        )
    }

    private var botStatus: MeterStatus? {
        switch service.dashboardPresence {
        case .absent:
            if service.cursorConfigured {
                if let error = service.cursorError {
                    return MeterStatus(text: error, isError: true)
                }
                return nil
            }
            return MeterStatus(text: GrokBotSessionNotice.notSignedIn, isError: false)
        case .needsRefresh, .keychainDenied, .failed:
            return MeterStatus(text: service.dashboardError ?? GrokBotSessionNotice.openGrokBot, isError: true)
        case .ready:
            if let reason = service.dashboardReading?.grokBotUnavailableReason {
                return MeterStatus(text: reason, isError: true)
            }
            return nil
        }
    }

    private var bottomStatus: MeterStatus? {
        if service.showsSuperGrokPool {
            if let error = service.lastError {
                let hint = error.localizedCaseInsensitiveContains("grok login")
                return MeterStatus(text: error, isError: !hint)
            }
            if !service.isAuthenticated {
                return MeterStatus(text: L10n.text("notice.grokLogin", "Run grok login"), isError: false)
            }
            return nil
        }
        if let reason = service.dashboardReading?.cursorModelsUnavailableReason,
           service.dashboardPresence == .ready || service.dashboardPresence == .failed {
            return MeterStatus(text: reason, isError: service.dashboardReading?.cursorModelsPercent == nil)
        }
        if service.dashboardPresence == .absent {
            return MeterStatus(text: L10n.text(
                "notice.modelsAfterSignIn",
                "Cursor Models usage appears after Grok Bot is signed in."
            ), isError: false)
        }
        if service.dashboardError != nil {
            return MeterStatus(text: L10n.text("notice.modelsUnavailable", "Cursor Models unavailable."), isError: false)
        }
        return nil
    }

    private var hasDetails: Bool {
        if service.dashboardReading?.otherModelsPercent != nil { return true }
        if service.dashboardReading?.onDemandKnown == true { return true }
        if service.showsSuperGrokPool, service.dashboardReading?.cursorModelsPercent != nil { return true }
        if !service.showsSuperGrokPool, service.lastError != nil { return true }
        let products = service.reading?.products ?? []
        if service.showsSuperGrokPool, !products.isEmpty { return true }
        if service.reading?.extraCreditsCents != nil { return true }
        if let cap = service.reading?.onDemandCapCents, cap > 0 || (service.reading?.onDemandUsedCents ?? 0) > 0 {
            return true
        }
        return service.managementConfigured
    }

    @ViewBuilder
    private var details: some View {
        if !service.showsSuperGrokPool, let error = service.lastError {
            Text(error)
                .font(.caption2)
                .foregroundStyle(error.localizedCaseInsensitiveContains("grok login") ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        if service.showsSuperGrokPool, let percent = service.dashboardReading?.cursorModelsPercent {
            labeled(L10n.text("meter.cursorModels", "Cursor Models"), "\(Int(round(percent)))%")
                .padding(.top, 4)
        }
        if let percent = service.dashboardReading?.otherModelsPercent {
            labeled(L10n.text("meter.otherModels", "Other models"), "\(Int(round(percent)))%")
        }
        if service.dashboardReading?.onDemandKnown == true {
            if let spend = service.dashboardReading?.onDemand {
                labeled(
                    L10n.text("meter.onDemand", "On-demand"),
                    "\(USDFormat.cents(spend.usedCents)) / \(USDFormat.cents(spend.limitCents))"
                )
            } else {
                labeled(L10n.text("meter.onDemand", "On-demand"), L10n.text("meter.noCap", "No cap"))
            }
        }
        let products = service.showsSuperGrokPool ? (service.reading?.products ?? []) : []
        if !products.isEmpty {
            productRows(products)
                .padding(.top, 4)
        }
        if let cents = service.reading?.extraCreditsCents {
            HStack {
                Text(L10n.text("detail.extraCredits", "Extra Usage Credits"))
                Spacer()
                Text(USDFormat.cents(cents))
                    .monospacedDigit()
            }
            .padding(.top, 4)
        }
        if let cap = service.reading?.onDemandCapCents, cap > 0 || (service.reading?.onDemandUsedCents ?? 0) > 0 {
            HStack {
                Text(L10n.text("detail.grokOnDemand", "grok.com on-demand"))
                Spacer()
                Text("\(USDFormat.cents(service.reading?.onDemandUsedCents ?? 0)) / \(USDFormat.cents(cap))")
                    .monospacedDigit()
            }
        }
        if service.managementConfigured {
            managementSection
                .padding(.top, 4)
        }
    }

    private func meterRow(
        title: String,
        percent: Double?,
        fraction: Double?,
        detail: String?,
        reset: Date?,
        footnote: String?,
        status: MeterStatus?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(percentText(percent))
                    .font(.subheadline)
                    .monospacedDigit()
            }
            ProgressView(value: fraction ?? 0, total: 1.0)
                .tint(colorForPct(fraction ?? 0))
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let reset {
                Text(resetCountdown(until: reset, now: Date()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status {
                Text(status.text)
                    .font(.caption2)
                    .foregroundStyle(status.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func percentText(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return "\(Int(round(percent)))%"
    }

    private var managementSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("settings.apiSection", "Developer API"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let snapshot = service.management {
                if let cents = snapshot.prepaidTotalCents {
                    labeled("Prepaid total", USDFormat.cents(cents))
                }
                if let spend = snapshot.spend7dUSD {
                    labeled("Spend, 7 days", USDFormat.amount(spend))
                }
            }
            if let error = service.managementError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.text(
                "detail.managementLong",
                "Console prepaid balance and API spend. Separate from the weekly pool. The documented balance is shown with its sign."
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption)
                .monospacedDigit()
        }
    }

    private static let inlineProductLimit = 6
    private static let productRowHeight: CGFloat = 28

    @ViewBuilder
    private func productRows(_ products: [GrokProductUsage]) -> some View {
        let rows = VStack(alignment: .leading, spacing: 6) {
            ForEach(products) { product in
                HStack {
                    Text(product.displayName)
                        .font(.caption)
                    Spacer()
                    Text(productPercent(product))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        if products.count > Self.inlineProductLimit {
            ScrollView { rows }
                .frame(height: CGFloat(Self.inlineProductLimit) * Self.productRowHeight)
        } else {
            rows
        }
    }

    private func productPercent(_ product: GrokProductUsage) -> String {
        guard let percent = product.usagePercent else { return "—" }
        return "\(Int(round(percent)))%"
    }

    private var settingsButton: some View {
        SettingsLink {
            Text(L10n.text("footer.settingsEllipsis", "Settings…"))
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

private struct SetupView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var notificationService: NotificationService
    var onComplete: () -> Void

    var body: some View {
        Text(L10n.text("setup.welcome", "Welcome"))
            .font(.headline)
        Text(L10n.text(
            "setup.body",
            "\(AppIdentity.displayName) shows Grok Bot weekly usage and, when your grok.com account has one, the SuperGrok pool."
        ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Divider()
        LaunchAtLoginToggle(controlSize: .small, useSwitchStyle: true)
        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("settings.notifications", "Notifications"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !notificationService.isAvailable {
                Text(notificationsUnavailableMessage())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            SetupThresholdSlider(
                label: L10n.text("meter.grokBot", "Grok Bot"),
                value: notificationService.thresholdBot,
                onChange: { notificationService.setThresholdBot($0) }
            )
            SetupThresholdSlider(
                label: L10n.text("settings.weeklyPool", "Weekly pool"),
                value: notificationService.thresholdWeekly,
                onChange: { notificationService.setThresholdWeekly($0) }
            )
        }
        .disabled(!notificationService.isAvailable)

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("settings.polling", "Polling Interval"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { service.pollingMinutes },
                set: { service.updatePollingInterval($0) }
            )) {
                ForEach(UsageService.pollingOptions, id: \.self) { mins in
                    Text(localizedPollingInterval(for: mins, locale: .autoupdatingCurrent))
                        .tag(mins)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if isDiscouragedPollingOption(service.pollingMinutes) {
                Text(L10n.text("setup.pollingWarning", "Frequent polling may cause rate limiting"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }

        Divider()
        Button(L10n.text("setup.start", "Get Started")) { onComplete() }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        HStack {
            Spacer()
            Button(L10n.text("footer.quit", "Quit")) { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SetupThresholdSlider: View {
    let label: String
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.callout)
                Spacer()
                Text(value > 0 ? "\(value)%" : L10n.text("settings.off", "Off"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(Int($0)) }
                ),
                in: 0...100,
                step: 5
            )
            .controlSize(.small)
        }
    }
}

private struct MeterStatus {
    let text: String
    let isError: Bool
}

/// "Resets 54 min, 29 secs" or "Resets 3 days, 4 hrs", matching the two-window layout.
func resetCountdown(until date: Date, now: Date) -> String {
    let seconds = Int(date.timeIntervalSince(now))
    if seconds <= 0 { return "Resets now" }
    let minutes = seconds / 60
    let hours = minutes / 60
    let days = hours / 24
    if days >= 1 {
        let remainingHours = hours % 24
        let dayWord = days == 1 ? "day" : "days"
        let hourWord = remainingHours == 1 ? "hr" : "hrs"
        return "Resets \(days) \(dayWord), \(remainingHours) \(hourWord)"
    }
    if hours >= 1 {
        let remainingMinutes = minutes % 60
        let hourWord = hours == 1 ? "hr" : "hrs"
        return "Resets \(hours) \(hourWord), \(remainingMinutes) min"
    }
    let remainingSeconds = seconds % 60
    return "Resets \(minutes) min, \(remainingSeconds) secs"
}

private func colorForPct(_ pct: Double) -> Color {
    switch pct {
    case ..<0.60: return .green
    case 0.60..<0.80: return .yellow
    default: return .red
    }
}
