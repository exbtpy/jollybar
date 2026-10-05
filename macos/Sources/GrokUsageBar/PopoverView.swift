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
            if !setupComplete && !service.isAuthenticated {
                SetupView(
                    service: service,
                    notificationService: notificationService,
                    onComplete: { setupComplete = true }
                )
            } else {
                header
                if !service.isAuthenticated {
                    signInView
                } else {
                    usageView
                }
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
    private var signInView: some View {
        Text("This app reads the session created by the grok CLI. It does not start its own login.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Text("grok login")
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

        Text("Then choose Refresh.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if let error = service.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }

        Divider()
        HStack {
            settingsButton
            Spacer()
            Button("Refresh") {
                Task { await service.fetchUsage() }
            }
            .buttonStyle(.borderless)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var usageView: some View {
        weeklyRow

        if service.reading?.assumedZero == true {
            Text("The weekly percent field was omitted for this period, so this shows 0% used.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        let products = service.reading?.products ?? []
        if !products.isEmpty {
            Divider()
            Text("By product")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            productRows(products)
        }

        if let cents = service.reading?.extraCreditsCents {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Extra Usage Credits")
                        .font(.subheadline)
                    Spacer()
                    Text(USDFormat.cents(cents))
                        .font(.subheadline)
                        .monospacedDigit()
                }
                Text("Prepaid balance reported with the weekly pool.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        if let cap = service.reading?.onDemandCapCents, cap > 0 || (service.reading?.onDemandUsedCents ?? 0) > 0 {
            HStack {
                Text("On-demand")
                    .font(.caption)
                Spacer()
                Text("\(USDFormat.cents(service.reading?.onDemandUsedCents ?? 0)) / \(USDFormat.cents(cap))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }

        if service.managementConfigured {
            Divider()
            managementSection
        }

        Divider()
        UsageChartView(historyService: historyService)

        if let error = service.lastError {
            Divider()
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let updaterError = appUpdater.lastError {
            Divider()
            Label(updaterError, systemImage: "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(.red)
                .font(.caption)
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

        HStack(spacing: 12) {
            settingsButton
            Spacer()
            Button("Refresh") {
                Task { await service.fetchUsage() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var weeklyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Weekly pool")
                    .font(.subheadline)
                Spacer()
                Text(weeklyText)
                    .font(.subheadline)
                    .monospacedDigit()
            }
            ProgressView(value: service.weeklyFraction ?? 0, total: 1.0)
                .tint(colorForPct(service.weeklyFraction ?? 0))
            if let reset = service.reading?.resetsAt {
                Text("Resets \(reset, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(reset.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var weeklyText: String {
        guard let percent = service.reading?.usedPercent else { return "—" }
        return "\(Int(round(percent)))% used"
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
        Text("Grok Usage Bar shows the shared weekly pool from a grok CLI login.")
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

private func colorForPct(_ pct: Double) -> Color {
    switch pct {
    case ..<0.60: return .green
    case 0.60..<0.80: return .yellow
    default: return .red
    }
}
