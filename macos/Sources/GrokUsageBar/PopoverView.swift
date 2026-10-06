import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var appUpdater: AppUpdater
    @AppStorage("setupComplete") private var setupComplete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !setupComplete && !service.isAuthenticated && !service.cursorConfigured {
                SetupView(
                    service: service,
                    notificationService: notificationService,
                    onComplete: { setupComplete = true }
                )
            } else {
                header
                usageView
            }
        }
        .padding()
        .frame(width: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Grok Usage")
                .font(.headline)
            if let tier = service.reading?.subscriptionTier, !tier.isEmpty {
                Text(tier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let email = service.accountEmail {
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
            title: "Grok Bot",
            percent: service.cursorReading?.usedPercent,
            fraction: service.botFraction,
            detail: service.cursorReading?.amountDetail,
            reset: service.cursorReading?.resetsAt,
            footnote: botFootnote,
            status: botStatus
        )

        meterRow(
            title: "Weekly pool",
            percent: service.reading?.usedPercent,
            fraction: service.weeklyFraction,
            detail: nil,
            reset: service.reading?.resetsAt,
            footnote: weeklyFootnote,
            status: weeklyStatus
        )

        if hasWeeklyDetails {
            DisclosureGroup("By product and credits") {
                weeklyDetails
            }
            .font(.caption)
        }

        Divider()
        UsageChartView(historyService: historyService)

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
            Button("Refresh") {
                Task { await service.fetchUsage(refreshCursor: true) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Button("Check for Updates…") {
                appUpdater.checkForUpdates()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(!appUpdater.isConfigured)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var botFootnote: String? {
        guard service.cursorReading?.resetIsAssumedMonthly == true else { return nil }
        return "Cycle end is the next calendar month after the billing-cycle start."
    }

    private var botStatus: MeterStatus? {
        if let error = service.cursorError {
            return MeterStatus(text: error, isError: true)
        }
        if !service.cursorConfigured {
            return MeterStatus(text: "Add a Cursor API key in Settings.", isError: false)
        }
        return nil
    }

    private var weeklyFootnote: String? {
        guard service.reading?.assumedZero == true else { return nil }
        return "The weekly percent field was omitted for this period, so this shows 0% used."
    }

    private var weeklyStatus: MeterStatus? {
        if let error = service.lastError {
            let hint = error.localizedCaseInsensitiveContains("grok login")
            return MeterStatus(text: error, isError: !hint)
        }
        if !service.isAuthenticated {
            return MeterStatus(text: "Run grok login", isError: false)
        }
        return nil
    }

    private var hasWeeklyDetails: Bool {
        let products = service.reading?.products ?? []
        if !products.isEmpty { return true }
        if service.reading?.extraCreditsCents != nil { return true }
        if let cap = service.reading?.onDemandCapCents, cap > 0 || (service.reading?.onDemandUsedCents ?? 0) > 0 {
            return true
        }
        return service.managementConfigured
    }

    @ViewBuilder
    private var weeklyDetails: some View {
        let products = service.reading?.products ?? []
        if !products.isEmpty {
            productRows(products)
                .padding(.top, 4)
        }
        if let cents = service.reading?.extraCreditsCents {
            HStack {
                Text("Extra Usage Credits")
                Spacer()
                Text(USDFormat.cents(cents))
                    .monospacedDigit()
            }
            .padding(.top, 4)
        }
        if let cap = service.reading?.onDemandCapCents, cap > 0 || (service.reading?.onDemandUsedCents ?? 0) > 0 {
            HStack {
                Text("On-demand")
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
            Text("Developer API")
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
            Text("Console prepaid balance and API spend. Separate from the weekly pool. The documented balance is shown with its sign.")
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
            Text("Settings…")
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
        Text("Welcome")
            .font(.headline)
        Text("Grok Usage Bar shows Cursor Grok Bot spend and the grok.com weekly pool, each on its own bar.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Divider()
        LaunchAtLoginToggle(controlSize: .small, useSwitchStyle: true)
        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !notificationService.isAvailable {
                Text(notificationsUnavailableMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            SetupThresholdSlider(
                label: "Grok Bot",
                value: notificationService.thresholdBot,
                onChange: { notificationService.setThresholdBot($0) }
            )
            SetupThresholdSlider(
                label: "Weekly pool",
                value: notificationService.thresholdWeekly,
                onChange: { notificationService.setThresholdWeekly($0) }
            )
        }
        .disabled(!notificationService.isAvailable)

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            Text("Polling Interval")
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
                Text("Frequent polling may cause rate limiting")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }

        Divider()
        Button("Get Started") { onComplete() }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        HStack {
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
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
                Text(value > 0 ? "\(value)%" : "Off")
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
