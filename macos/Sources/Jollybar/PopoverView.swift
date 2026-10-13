import SwiftUI
import AppKit

/// Menu-bar style never chooses this window. Every theme opens the companion.
enum PopoverContent {
    static let width: CGFloat = 320

    static func showsCompanionPopover(for theme: MenuTheme) -> Bool {
        switch theme {
        case .percent, .bars, .companion:
            return true
        }
    }

    /// Account email is kept for Settings. It is not one of these lines.
    static func containsAccountEmail(_ model: CompanionPopoverModel, email: String) -> Bool {
        let needle = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return visibleCopy(model).contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    static func visibleCopy(_ model: CompanionPopoverModel) -> [String] {
        var lines = [model.planTitle, model.heroTitle]
        if let value = model.assumedMonthlyNote { lines.append(value) }
        if let value = model.heroStatus { lines.append(value) }
        if let value = model.modelsStatus { lines.append(value) }
        if let value = model.onDemandText { lines.append(value) }
        if let value = model.updaterError { lines.append(value) }
        if let value = model.detailNote { lines.append(value) }
        for row in model.details {
            lines.append(row.title)
            lines.append(row.value)
        }
        return lines
    }
}

struct PopoverView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var appUpdater: AppUpdater
    @AppStorage("setupComplete") private var setupComplete = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !setupComplete && !service.isAuthenticated && !service.cursorConfigured {
            SetupView(
                service: service,
                notificationService: notificationService,
                onComplete: { setupComplete = true }
            )
            .padding()
            .frame(width: PopoverContent.width)
            .background(JollyTheme.background(colorScheme))
        } else {
            CompanionScreen(
                service: service,
                historyService: historyService,
                appUpdater: appUpdater
            )
        }
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
