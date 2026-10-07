import AppKit
import SwiftUI

struct LabeledValue: Equatable, Identifiable {
    var id: String
    var title: String
    var value: String
}

struct CompanionPopoverModel: Equatable {
    var mood: CompanionMood
    var planTitle: String
    var heroTitle: String
    var usedPercent: Double?
    var percentStyle: UsagePercentStyle
    var periodStart: Date?
    var resetsAt: Date?
    var assumedMonthlyNote: String?
    var heroStatus: String?
    var heroStatusIsError: Bool
    var cursorModelsPercent: Double?
    var otherModelsPercent: Double?
    var superGrokPercent: Double?
    var modelsStatus: String?
    var modelsStatusIsError: Bool
    var onDemandText: String?
    var sprouts: [SproutWeek.Day]
    var sproutReady: Bool
    var chartMode: UsageChartMode
    var syncedAt: Date?
    var updaterError: String?
    var details: [LabeledValue]
    var detailNote: String?

    var showsSprouts: Bool {
        chartMode == .sprout && sproutReady
    }
}

@MainActor
enum CompanionPopoverModelBuilder {
    static func make(
        service: UsageService,
        appUpdater: AppUpdater,
        percentStyle: UsagePercentStyle,
        chartMode: UsageChartMode,
        sprouts: [SproutWeek.Day]
    ) -> CompanionPopoverModel {
        let dashboard = service.dashboardReading
        let heroIsSand = service.sandOwnsTopSlot
        let used = heroIsSand ? dashboard?.grokBotPercent : service.cursorReading?.usedPercent
        let heroStatus = heroNotice(service)
        let modelStatus = modelsNotice(service)
        return CompanionPopoverModel(
            mood: service.companionMood,
            planTitle: planTitle(service),
            heroTitle: heroIsSand
                ? L10n.text("meter.grokBot", "Grok Bot")
                : (service.cursorConfigured
                    ? L10n.text("meter.grokBotSpend", "Grok Bot spend")
                    : L10n.text("meter.grokBot", "Grok Bot")),
            usedPercent: used,
            percentStyle: percentStyle,
            periodStart: heroIsSand ? dashboard?.periodStart : nil,
            resetsAt: heroIsSand ? dashboard?.resetsAt : service.cursorReading?.resetsAt,
            assumedMonthlyNote: assumedMonthlyNote(service),
            heroStatus: heroStatus?.text,
            heroStatusIsError: heroStatus?.isError ?? false,
            cursorModelsPercent: dashboard?.cursorModelsPercent,
            otherModelsPercent: dashboard?.otherModelsPercent,
            superGrokPercent: service.showsSuperGrokPool ? service.reading?.usedPercent : nil,
            modelsStatus: modelStatus?.text,
            modelsStatusIsError: modelStatus?.isError ?? false,
            onDemandText: onDemandText(dashboard),
            sprouts: sprouts,
            sproutReady: sprouts.count == 7,
            chartMode: chartMode,
            syncedAt: service.lastUpdated,
            updaterError: appUpdater.lastError,
            details: detailRows(service),
            detailNote: service.managementConfigured
                ? L10n.text(
                    "detail.managementNote",
                    "Console prepaid balance and API spend. Separate from the weekly pool."
                )
                : nil
        )
    }

    private static func planTitle(_ service: UsageService) -> String {
        if let tier = service.reading?.subscriptionTier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tier.isEmpty {
            return tier
        }
        if service.showsSuperGrokPool {
            return L10n.text("plan.weekly", "Weekly")
        }
        return L10n.text("plan.grokBot", "Grok Bot")
    }

    private static func assumedMonthlyNote(_ service: UsageService) -> String? {
        guard !service.sandOwnsTopSlot, service.cursorReading?.resetIsAssumedMonthly == true else { return nil }
        return L10n.text(
            "meter.assumedMonthly",
            "Cycle end is the next calendar month after the billing-cycle start."
        )
    }

    private static func onDemandText(_ dashboard: CursorDashboardReading?) -> String? {
        guard dashboard?.onDemandKnown == true, let spend = dashboard?.onDemand else { return nil }
        return "\(USDFormat.cents(spend.usedCents)) / \(USDFormat.cents(spend.limitCents))"
    }

    private static func heroNotice(_ service: UsageService) -> (text: String, isError: Bool)? {
        switch service.dashboardPresence {
        case .absent:
            if service.cursorConfigured {
                if let error = service.cursorError {
                    return (error, true)
                }
                return nil
            }
            return (GrokBotSessionNotice.notSignedIn, false)
        case .needsRefresh, .keychainDenied, .failed:
            return (service.dashboardError ?? GrokBotSessionNotice.openGrokBot, true)
        case .ready:
            if let reason = service.dashboardReading?.grokBotUnavailableReason {
                return (reason, true)
            }
            return nil
        }
    }

    private static func modelsNotice(_ service: UsageService) -> (text: String, isError: Bool)? {
        if service.showsSuperGrokPool {
            if let error = service.lastError {
                let hint = error.localizedCaseInsensitiveContains("grok login")
                return (error, !hint)
            }
            if !service.isAuthenticated {
                return (L10n.text("notice.grokLogin", "Run grok login"), false)
            }
        }
        if let reason = service.dashboardReading?.cursorModelsUnavailableReason,
           service.dashboardPresence == .ready || service.dashboardPresence == .failed {
            return (reason, service.dashboardReading?.cursorModelsPercent == nil)
        }
        if service.dashboardPresence == .absent {
            return (L10n.text(
                "notice.modelsAfterSignIn",
                "Cursor Models usage appears after Grok Bot is signed in."
            ), false)
        }
        if service.dashboardError != nil, service.dashboardReading?.cursorModelsPercent == nil {
            return (L10n.text("notice.modelsUnavailable", "Cursor Models unavailable."), false)
        }
        return nil
    }

    private static func detailRows(_ service: UsageService) -> [LabeledValue] {
        var rows: [LabeledValue] = []
        if !service.showsSuperGrokPool, let error = service.lastError {
            rows.append(LabeledValue(id: "grok-error", title: L10n.text("detail.grok", "Grok"), value: error))
        }
        for product in service.showsSuperGrokPool ? (service.reading?.products ?? []) : [] {
            let value = product.usagePercent.map { "\(Int(round($0)))%" } ?? "—"
            rows.append(LabeledValue(id: "product-\(product.id)", title: product.displayName, value: value))
        }
        if let cents = service.reading?.extraCreditsCents {
            rows.append(LabeledValue(
                id: "extra",
                title: L10n.text("detail.extraCredits", "Extra Usage Credits"),
                value: USDFormat.cents(cents)
            ))
        }
        if let cap = service.reading?.onDemandCapCents, cap > 0 || (service.reading?.onDemandUsedCents ?? 0) > 0 {
            rows.append(LabeledValue(
                id: "grok-ondemand",
                title: L10n.text("detail.grokOnDemand", "grok.com on-demand"),
                value: "\(USDFormat.cents(service.reading?.onDemandUsedCents ?? 0)) / \(USDFormat.cents(cap))"
            ))
        }
        if let snapshot = service.management {
            if let cents = snapshot.prepaidTotalCents {
                rows.append(LabeledValue(
                    id: "prepaid",
                    title: L10n.text("detail.prepaid", "Prepaid total"),
                    value: USDFormat.cents(cents)
                ))
            }
            if let spend = snapshot.spend7dUSD {
                rows.append(LabeledValue(
                    id: "spend7",
                    title: L10n.text("detail.spend7", "Spend, 7 days"),
                    value: USDFormat.amount(spend)
                ))
            }
        }
        if let error = service.managementError {
            rows.append(LabeledValue(id: "management-error", title: L10n.text("detail.api", "Developer API"), value: error))
        }
        return rows
    }
}

struct CompanionScreen: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @ObservedObject var appUpdater: AppUpdater
    @AppStorage(UsagePercentStyle.defaultsKey) private var percentStyleRaw = UsagePercentStyle.used.rawValue
    @AppStorage(UsageChartMode.defaultsKey) private var chartModeRaw = UsageChartMode.sprout.rawValue
    @AppStorage("lastSeenUsageWindowStart") private var lastSeenWindow: Double = 0
    @AppStorage("lastCelebratedUsageWindowStart") private var lastCelebratedWindow: Double = 0
    @State private var celebrate = false
    @State private var popoverVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var power = PowerState()

    var body: some View {
        let style = UsagePercentStyle(rawValue: percentStyleRaw) ?? .used
        let mode = UsageChartMode(rawValue: chartModeRaw) ?? .sprout
        let sprouts = SproutWeek.build(points: historyService.history.dataPoints, now: Date()) ?? []
        let model = CompanionPopoverModelBuilder.make(
            service: service,
            appUpdater: appUpdater,
            percentStyle: style,
            chartMode: mode,
            sprouts: sprouts
        )
        let motion = popoverVisible && MotionPolicy.allowsMotion(
            reduceMotion: reduceMotion,
            lowPower: power.isLowPowerMode
        )
        CompanionPopover(
            model: model,
            motionEnabled: motion,
            celebrate: celebrate && motion,
            onCelebrationFinished: { celebrate = false },
            onChartMode: { chartModeRaw = $0.rawValue },
            onRefresh: { Task { await service.fetchUsage(refreshCursor: true) } },
            historyChart: {
                UsageChartView(
                    historyService: historyService,
                    showsWeeklyPool: service.showsSuperGrokPool
                )
            }
        )
        .background(PopoverWindowVisible(isVisible: $popoverVisible))
        .background(CompanionWindowChrome())
        .onAppear { evaluateCelebration() }
        .onChange(of: popoverVisible) { _, _ in evaluateCelebration() }
        .onChange(of: service.dashboardReading) { _, _ in evaluateCelebration() }
        .onChange(of: service.cursorReading) { _, _ in evaluateCelebration() }
    }

    private func evaluateCelebration() {
        let start = UsagePace.resolvedStart(
            periodStart: service.sandOwnsTopSlot ? service.dashboardReading?.periodStart : nil,
            reset: service.sandOwnsTopSlot ? service.dashboardReading?.resetsAt : service.cursorReading?.resetsAt
        )
        let previous = lastSeenWindow > 0 ? Date(timeIntervalSince1970: lastSeenWindow) : nil
        let already = lastCelebratedWindow > 0 ? Date(timeIntervalSince1970: lastCelebratedWindow) : nil
        if let window = ResetCelebration.windowToCelebrate(
            previousWindowStart: previous,
            currentWindowStart: start,
            alreadyCelebrated: already
        ) {
            if popoverVisible {
                celebrate = true
                lastCelebratedWindow = window.timeIntervalSince1970
                lastSeenWindow = window.timeIntervalSince1970
            }
            return
        }
        if let start {
            lastSeenWindow = start.timeIntervalSince1970
        }
    }
}

struct CompanionPopover<HistoryChart: View>: View {
    var model: CompanionPopoverModel
    var frozenNow: Date?
    var locale: Locale = .autoupdatingCurrent
    var calendar: Calendar = .current
    var motionEnabled: Bool
    var celebrate: Bool
    var onCelebrationFinished: () -> Void
    var onChartMode: (UsageChartMode) -> Void
    var onRefresh: () -> Void
    @ViewBuilder var historyChart: () -> HistoryChart

    @Environment(\.colorScheme) private var scheme
    @State private var barFraction: Double = 0

    var body: some View {
        Group {
            if let frozenNow {
                layout(now: frozenNow)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    layout(now: timeline.date)
                }
            }
        }
        .frame(width: 320)
        .background(JollyTheme.background(scheme))
        .onAppear { syncBar(animated: false) }
        .onChange(of: heroFraction) { _, _ in
            if !celebrate { syncBar(animated: motionEnabled) }
        }
        .onChange(of: celebrate) { _, isOn in
            guard isOn else { return }
            guard motionEnabled else {
                onCelebrationFinished()
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { barFraction = 1 }
            withAnimation(.spring(duration: 0.6)) { barFraction = heroFraction }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                onCelebrationFinished()
            }
        }
    }

    private var heroFraction: Double {
        guard let used = model.usedPercent, used.isFinite else { return 0 }
        return min(max(used / 100, 0), 1)
    }

    private func syncBar(animated: Bool) {
        if animated {
            withAnimation(.spring(duration: 0.35)) { barFraction = heroFraction }
        } else {
            barFraction = heroFraction
        }
    }

    private func layout(now: Date) -> some View {
        let forecast = UsagePace.forecast(
            usedPercent: model.usedPercent,
            periodStart: model.periodStart,
            reset: model.resetsAt,
            now: now
        )
        let speech = BudSpeech.line(
            mood: model.mood,
            forecast: forecast,
            reset: model.resetsAt,
            seed: BudSpeech.seed(
                periodStart: model.periodStart,
                reset: model.resetsAt,
                kind: BudSpeech.kind(mood: model.mood, forecast: forecast)
            ),
            locale: locale,
            calendar: calendar
        )
        return VStack(alignment: .leading, spacing: 8) {
            stage(speech: speech)
            hero(now: now, forecast: forecast)
            modelsCard
            weekCard
            if let updaterError = model.updaterError {
                Text(updaterError)
                    .font(JollyType.rounded(11, weight: .medium))
                    .foregroundStyle(JollyTheme.worried.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.details.isEmpty || model.detailNote != nil {
                moreSection
            }
            footer
        }
        .padding(14)
        .overlay {
            if celebrate && motionEnabled {
                ConfettiBurst()
                    .allowsHitTesting(false)
            }
        }
    }

    private func stage(speech: String) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 4) {
                BudStage(mood: model.mood, motionEnabled: motionEnabled)
                    .padding(.top, 26)
                Text(speech)
                    .font(JollyType.rounded(13, weight: .medium))
                    .foregroundStyle(JollyTheme.ink.color.opacity(0.84))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
            HStack(alignment: .center) {
                Text(model.planTitle)
                    .font(JollyType.label(9))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(JollyTheme.deepTeal.color)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.62)))
                Spacer(minLength: 8)
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JollyTheme.ink.color.opacity(0.72))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("footer.settings", "Settings"))
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .background(stageBackground)
    }

    private var stageBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(JollyTheme.cream.color)
            .overlay(
                RadialGradient(
                    colors: [
                        JollyTheme.teal.color.opacity(0.34),
                        JollyTheme.teal.color.opacity(0)
                    ],
                    center: .init(x: 0.5, y: 0.42),
                    startRadius: 4,
                    endRadius: 120
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(JollyTheme.deepTeal.color.opacity(0.16), lineWidth: 1)
            )
    }

    private func hero(now: Date, forecast: UsagePace.Forecast?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.heroTitle)
                .font(JollyType.label(10))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(JollyTheme.secondaryText(scheme))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(UsageNumber.heroText(usedPercent: model.usedPercent, style: model.percentStyle))
                    .font(JollyType.rounded(36, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(JollyTheme.primaryText(scheme))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(model.percentStyle.settingsTitle)
                    .font(JollyType.label(10))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(JollyTheme.secondaryText(scheme))
            }
            paceBar(forecast: forecast)
            if let reset = model.resetsAt {
                Text(UsagePaceFormat.resetLine(reset: reset, now: now, locale: locale, calendar: calendar))
                    .font(JollyType.rounded(11, weight: .regular))
                    .foregroundStyle(JollyTheme.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let forecast, let used = model.usedPercent {
                Text(UsagePaceFormat.paceLine(
                    forecast: forecast,
                    usedPercent: used,
                    locale: locale,
                    calendar: calendar
                ))
                .font(JollyType.rounded(11, weight: .medium))
                .foregroundStyle(JollyTheme.primaryText(scheme).opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            }
            if let note = model.assumedMonthlyNote {
                Text(note)
                    .font(JollyType.rounded(10, weight: .regular))
                    .foregroundStyle(JollyTheme.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.heroStatus {
                Text(status)
                    .font(JollyType.rounded(11, weight: .medium))
                    .foregroundStyle(model.heroStatusIsError ? JollyTheme.worried.color : JollyTheme.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heroBackground)
    }

    private func paceBar(forecast: UsagePace.Forecast?) -> some View {
        Capsule()
            .fill(JollyTheme.track(scheme))
            .frame(height: 10)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(model.mood.accent)
                        .frame(width: max(barFraction * geo.size.width, barFraction > 0 ? 10 : 0))
                }
            }
            .clipShape(Capsule())
            .overlay {
                if let forecast {
                    GeometryReader { geo in
                        BudLeafShape()
                            .fill(JollyTheme.deepTeal.color)
                            .frame(width: 11, height: 14)
                            .overlay(
                                Capsule()
                                    .fill(JollyTheme.cream.color.opacity(0.75))
                                    .frame(width: 1.2, height: 7)
                            )
                            .position(
                                x: geo.size.width * UsagePace.leafFraction(forecast),
                                y: geo.size.height / 2
                            )
                    }
                }
            }
            .frame(height: 16)
            .accessibilityLabel(L10n.text("meter.pace", "Weekly pace"))
    }

    private var heroBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(JollyTheme.cardFill(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(JollyTheme.moodWash(model.mood))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(JollyTheme.hairline(scheme), lineWidth: 1)
            )
    }

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.text("meter.cursorModels", "Cursor Models"))
                .font(JollyType.label(10))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(JollyTheme.secondaryText(scheme))
            thinMeter(
                title: L10n.text("meter.cursorModelsShort", "Cursor models"),
                percent: model.cursorModelsPercent,
                tint: JollyTheme.teal.color
            )
            thinMeter(
                title: L10n.text("meter.otherModels", "Other models"),
                percent: model.otherModelsPercent,
                tint: JollyTheme.deepTeal.color
            )
            if let superGrok = model.superGrokPercent {
                thinMeter(
                    title: L10n.text("meter.superGrok", "SuperGrok"),
                    percent: superGrok,
                    tint: JollyTheme.steady.color
                )
            }
            if let onDemand = model.onDemandText {
                HStack {
                    Text(L10n.text("meter.onDemand", "On-demand"))
                        .font(JollyType.label(10))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(JollyTheme.secondaryText(scheme))
                    Spacer()
                    Text(onDemand)
                        .font(JollyType.rounded(12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(JollyTheme.primaryText(scheme))
                }
            }
            if let status = model.modelsStatus {
                Text(status)
                    .font(JollyType.rounded(11, weight: .medium))
                    .foregroundStyle(model.modelsStatusIsError ? JollyTheme.worried.color : JollyTheme.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func thinMeter(title: String, percent: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(JollyType.label(9))
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .foregroundStyle(JollyTheme.secondaryText(scheme))
                Spacer()
                Text(percent.map { "\(Int(round($0)))%" } ?? "—")
                    .font(JollyType.rounded(11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(JollyTheme.primaryText(scheme))
            }
            Capsule()
                .fill(JollyTheme.track(scheme))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        let fraction = percent.map { min(max($0 / 100, 0), 1) } ?? 0
                        Capsule()
                            .fill(tint)
                            .frame(width: max(fraction * geo.size.width, fraction > 0 ? 6 : 0))
                    }
                }
                .clipShape(Capsule())
        }
    }

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("week.title", "The week"))
                    .font(JollyType.label(10))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(JollyTheme.secondaryText(scheme))
                Spacer()
                chartToggle
            }
            if model.showsSprouts {
                sproutChart
            } else {
                historyChart()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var chartToggle: some View {
        HStack(spacing: 2) {
            toggleChip(.sprout, title: L10n.text("week.sprout", "Week"))
            toggleChip(.history, title: L10n.text("week.history", "History"))
        }
        .padding(2)
        .background(Capsule().fill(JollyTheme.track(scheme)))
    }

    private func toggleChip(_ mode: UsageChartMode, title: String) -> some View {
        let selected = model.chartMode == mode
        return Button {
            onChartMode(mode)
        } label: {
            Text(title)
                .font(JollyType.label(9))
                .textCase(.uppercase)
                .tracking(0.4)
                .foregroundStyle(selected ? JollyTheme.ink.color : JollyTheme.secondaryText(scheme))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(selected ? JollyTheme.cream.color : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private var sproutChart: some View {
        let maxPoints = model.sprouts.map(\.usagePoints).max() ?? 0
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(model.sprouts) { day in
                sproutColumn(day, maxPoints: maxPoints)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func sproutColumn(_ day: SproutWeek.Day, maxPoints: Double) -> some View {
        let height = SproutWeek.stemHeight(usagePoints: day.usagePoints, maxPoints: maxPoints)
        let tint = day.isToday ? model.mood.accent : JollyTheme.deepTeal.color.opacity(0.8)
        let symbol = day.start.formatted(
            JollyClock.style(locale: locale, calendar: calendar)
                .weekday(.narrow)
        )
        return VStack(spacing: 3) {
            ZStack {
                if day.isToday {
                    BudMarker(mood: model.mood)
                }
            }
            .frame(height: 14)
            VStack(spacing: 0) {
                if day.usagePoints > 0.05 {
                    BudLeafShape()
                        .fill(tint)
                        .frame(width: 9, height: 11)
                        .rotationEffect(.degrees(-18))
                }
                Capsule()
                    .fill(tint)
                    .frame(width: day.isToday ? 4 : 3, height: height)
            }
            .frame(height: 60, alignment: .bottom)
            Text(symbol)
                .font(JollyType.label(8))
                .textCase(.uppercase)
                .foregroundStyle(day.isToday ? model.mood.accent : JollyTheme.secondaryText(scheme))
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(symbol)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(JollyTheme.cardFill(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(JollyTheme.hairline(scheme), lineWidth: 1)
            )
    }

    private var moreSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.details) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.title)
                            .foregroundStyle(JollyTheme.secondaryText(scheme))
                        Spacer(minLength: 8)
                        Text(row.value)
                            .monospacedDigit()
                            .foregroundStyle(JollyTheme.primaryText(scheme))
                            .multilineTextAlignment(.trailing)
                    }
                    .font(JollyType.rounded(11, weight: .regular))
                }
                if let note = model.detailNote {
                    Text(note)
                        .font(JollyType.rounded(10, weight: .regular))
                        .foregroundStyle(JollyTheme.secondaryText(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        } label: {
            Text(L10n.text("section.more", "More"))
                .font(JollyType.label(10))
                .textCase(.uppercase)
                .tracking(0.7)
                .foregroundStyle(JollyTheme.secondaryText(scheme))
        }
        .tint(JollyTheme.secondaryText(scheme))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(syncedLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 6)
            Button(L10n.text("footer.refresh", "Refresh")) {
                onRefresh()
            }
            .buttonStyle(.plain)
            Button(L10n.text("footer.quit", "Quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .font(JollyType.label(10))
        .textCase(.uppercase)
        .tracking(0.5)
        .foregroundStyle(JollyTheme.secondaryText(scheme))
    }

    private var syncedLabel: String {
        guard let synced = model.syncedAt else {
            return L10n.text("footer.waiting", "Waiting")
        }
        let time = JollyClock.time(synced, locale: locale, calendar: calendar)
        return L10n.format("footer.synced", "Synced %@", locale: locale, time)
    }
}

private struct BudStage: View {
    var mood: CompanionMood
    var motionEnabled: Bool
    @State private var squish = false
    @State private var reaction: CGFloat = 1
    @State private var heartsVisible = false
    @State private var heartLift: CGFloat = 0

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !motionEnabled)) { timeline in
                let phase = motionEnabled ? timeline.date.timeIntervalSinceReferenceDate : 0
                let cycle = phase.truncatingRemainder(dividingBy: 4)
                let breathe = motionEnabled ? CGFloat(sin(phase * .pi / 2)) * 0.028 : 0
                BudFigure(mood: mood, eyeOpen: blink(cycle))
                    .scaleEffect(
                        x: (1 + breathe) * (squish ? 1.08 : 1) * reaction,
                        y: (1 - breathe * 0.55) * (squish ? 0.88 : 1) * reaction
                    )
            }
            .animation(motionEnabled ? .spring(duration: 0.35) : nil, value: squish)
            if heartsVisible {
                hearts
            }
        }
        .frame(width: 120, height: 96)
        .contentShape(Rectangle())
        .onTapGesture { poke() }
        .onChange(of: mood) { _, _ in react() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(mood.accessibilityLabel)
        .accessibilityHint(L10n.text("bud.poke", "Poke Bud"))
    }

    private var hearts: some View {
        HStack(spacing: 22) {
            heart.offset(y: -6 - heartLift * 18)
            heart.offset(x: 6, y: -14 - heartLift * 20)
        }
        .opacity(1 - Double(heartLift))
        .allowsHitTesting(false)
    }

    private var heart: some View {
        BudHeartShape()
            .fill(JollyTheme.worried.color)
            .frame(width: 10, height: 10)
    }

    private func blink(_ cycle: TimeInterval) -> CGFloat {
        guard motionEnabled, mood != .asleep else { return 1 }
        let start = 2.2
        let end = 2.42
        guard cycle >= start, cycle <= end else { return 1 }
        let t = (cycle - start) / (end - start)
        let closed = t < 0.5 ? t * 2 : (1 - t) * 2
        return CGFloat(1 - closed)
    }

    private func poke() {
        heartsVisible = true
        if motionEnabled {
            heartLift = 0
            var hold = Transaction()
            hold.disablesAnimations = true
            withTransaction(hold) { squish = true }
            withAnimation(.easeOut(duration: 0.7)) { heartLift = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                withAnimation(.spring(duration: 0.35, bounce: 0.45)) { squish = false }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            heartsVisible = false
            heartLift = 0
        }
    }

    private func react() {
        guard motionEnabled else { return }
        reaction = 1.08
        withAnimation(.spring(duration: 0.6, bounce: 0.4)) { reaction = 1 }
    }
}

private struct ConfettiBurst: View {
    @State private var launched = false

    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color(index))
                    .frame(width: index.isMultiple(of: 3) ? 7 : 5, height: 8)
                    .rotationEffect(.degrees(launched ? angle(index) : 0))
                    .offset(launched ? end(index) : start(index))
                    .opacity(launched ? 0 : 1)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { launched = true }
        }
        .allowsHitTesting(false)
    }

    private func color(_ index: Int) -> Color {
        switch index % 3 {
        case 0: return JollyTheme.teal.color
        case 1: return JollyTheme.cream.color
        default: return JollyTheme.deepTeal.color
        }
    }

    private func start(_ index: Int) -> CGSize {
        CGSize(width: CGFloat((index % 5) - 2) * 8, height: 20)
    }

    private func end(_ index: Int) -> CGSize {
        let column = CGFloat(index % 6) - 2.5
        return CGSize(width: column * 28, height: CGFloat(40 + (index * 17) % 80))
    }

    private func angle(_ index: Int) -> Double {
        Double((index * 47) % 180) - 90
    }
}

struct CompanionWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.style(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.style(nsView.window) }
    }

    static func style(_ window: NSWindow?) {
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.hasShadow = true
    }
}

@MainActor
final class PowerState: ObservableObject {
    @Published private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSProcessInfoPowerStateDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
