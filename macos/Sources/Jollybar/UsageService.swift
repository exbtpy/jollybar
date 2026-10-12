import Foundation
import Combine

/// Polls the grok.com weekly pool and the Grok Bot session on this Mac.
///
/// A failure on one source does not clear the other. The Cursor Admin API is
/// only the fallback when Grok Bot is not signed in here, and that fallback
/// stays on its hourly schedule. A 429 still holds Refresh back for `Retry-After`.
@MainActor
final class UsageService: ObservableObject {
    @Published var reading: GrokBillingReading?
    @Published var management: ManagementSnapshot?
    @Published var cursorReading: CursorGrokBotReading?
    @Published var dashboardReading: CursorDashboardReading?
    @Published var dashboardPresence: CursorDashboardPresence = .absent
    @Published var lastError: String?
    @Published var managementError: String?
    @Published var cursorError: String?
    @Published var dashboardError: String?
    @Published var lastUpdated: Date?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var pollingMinutes: Int
    @Published private(set) var managementTeamID: String
    @Published private(set) var managementConfigured = false
    @Published private(set) var cursorConfigured = false
    @Published private(set) var cursorMemberEmail: String
    @Published private(set) var cursorOrganizationID: String
    @Published private(set) var cursorBudgetDollars: Double?

    var historyService: UsageHistoryService?
    var notificationService: NotificationService?

    /// True when the signed-in grok.com account has a SuperGrok pool.
    var showsSuperGrokPool: Bool {
        reading?.hasWeeklyPool == true
    }

    /// 0...1 when a SuperGrok weekly percent is available.
    var weeklyFraction: Double? {
        guard showsSuperGrokPool, let percent = reading?.usedPercent else { return nil }
        return min(max(percent / 100.0, 0), 1)
    }

    /// The top bar is the Grok Bot weekly meter when a sand session exists.
    /// Otherwise it is Admin API spend, labeled separately.
    var sandOwnsTopSlot: Bool {
        dashboardPresence != .absent
    }

    var topLabel: String { sandOwnsTopSlot ? "GB" : (cursorConfigured ? "Sp" : "GB") }

    var bottomLabel: String { showsSuperGrokPool ? "Wk" : "CM" }

    /// 0...1 for the top menu-bar meter.
    var topFraction: Double? {
        if sandOwnsTopSlot {
            return fraction(dashboardReading?.grokBotPercent)
        }
        return fraction(cursorReading?.usedPercent)
    }

    /// 0...1 for the bottom menu-bar meter.
    var bottomFraction: Double? {
        if showsSuperGrokPool {
            return weeklyFraction
        }
        return fraction(dashboardReading?.cursorModelsPercent)
    }

    var companionMood: CompanionMood {
        let percent = sandOwnsTopSlot ? dashboardReading?.grokBotPercent : cursorReading?.usedPercent
        let paused = sandOwnsTopSlot ? (dashboardReading?.pausedAtLimit == true) : false
        return CompanionMood.resolve(usedPercent: percent, pausedAtLimit: paused)
    }

    /// Kept for callers that mean the top meter. Grok Bot weekly when sand is
    /// present, otherwise the Admin spend fallback.
    var botFraction: Double? { topFraction }

    private func fraction(_ percent: Double?) -> Double? {
        guard let percent else { return nil }
        return min(max(percent / 100.0, 0), 1)
    }

    static let defaultPollingMinutes = 30
    static let pollingOptions = [5, 15, 30, 60]
    nonisolated static let maxBackoffInterval: TimeInterval = 60 * 60

    private var timer: Timer?
    private var currentInterval: TimeInterval
    private let session: URLSession
    /// Retained for the lifetime of the default session. Unused when a test injects its own session.
    private let redirectDelegate: SameOriginRedirectDelegate
    private let proxyBaseURL: URL
    private let managementBaseURL: URL
    private let cursorBaseURL: URL
    private let dashboardBaseURL: URL
    private let sandSecretsURL: URL?
    private let homeDirectory: URL
    private let keyProvider: GrokBotKeyProviding
    private let authFileURL: URL
    private let secretStore: SecretStoring
    private let defaults: UserDefaults
    private let now: () -> Date
    private var cursorCache = CursorResponseCache()
    /// Earliest time an automatic Cursor poll may run. Refresh ignores this.
    private var nextCursorFetchAt: Date?
    /// Earliest time any Cursor poll may run, including Refresh, after HTTP 429.
    private var cursorBackoffUntil: Date?

    private var baseInterval: TimeInterval { TimeInterval(pollingMinutes * 60) }

    nonisolated static func backoffInterval(
        retryAfter: TimeInterval?,
        currentInterval: TimeInterval
    ) -> TimeInterval {
        min(max(retryAfter ?? currentInterval, currentInterval * 2), maxBackoffInterval)
    }

    init(
        session: URLSession? = nil,
        proxyBaseURL: URL? = nil,
        managementBaseURL: URL? = nil,
        cursorBaseURL: URL? = nil,
        dashboardBaseURL: URL? = nil,
        sandSecretsURL: URL? = nil,
        keyProvider: GrokBotKeyProviding = MacGrokBotKeyProvider(),
        authFileURL: URL? = nil,
        secretStore: SecretStoring = KeychainSecretStore(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        let redirectDelegate = SameOriginRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            self.session = URLSession(
                configuration: configuration,
                delegate: redirectDelegate,
                delegateQueue: nil
            )
        }
        self.proxyBaseURL = proxyBaseURL ?? EndpointOverride.resolvedURL(
            key: EndpointOverride.proxyKey,
            defaultURL: EndpointOverride.defaultProxyBase
        )
        self.managementBaseURL = managementBaseURL ?? EndpointOverride.resolvedURL(
            key: EndpointOverride.managementKey,
            defaultURL: EndpointOverride.defaultManagementBase
        )
        self.cursorBaseURL = cursorBaseURL ?? EndpointOverride.resolvedURL(
            key: EndpointOverride.cursorKey,
            defaultURL: EndpointOverride.defaultCursorBase
        )
        self.dashboardBaseURL = dashboardBaseURL ?? EndpointOverride.resolvedURL(
            key: EndpointOverride.dashboardKey,
            defaultURL: EndpointOverride.defaultDashboardBase
        )
        self.sandSecretsURL = sandSecretsURL ?? EndpointOverride.sandSecretsURL()
        self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        self.keyProvider = keyProvider
        self.authFileURL = authFileURL ?? EndpointOverride.authFileURL()
        self.secretStore = secretStore
        self.defaults = defaults
        self.now = now
        let stored = defaults.integer(forKey: "pollingMinutes")
        let minutes = Self.pollingOptions.contains(stored) ? stored : Self.defaultPollingMinutes
        self.pollingMinutes = minutes
        self.currentInterval = TimeInterval(minutes * 60)
        let team = defaults.string(forKey: "managementTeamID") ?? ""
        self.managementTeamID = team
        self.managementConfigured = !team.isEmpty && secretStore.load(account: ManagementSecret.account) != nil
        self.cursorMemberEmail = defaults.string(forKey: "cursorMemberEmail") ?? ""
        self.cursorOrganizationID = defaults.string(forKey: "cursorOrganizationID") ?? ""
        self.cursorBudgetDollars = defaults.object(forKey: "cursorBudgetDollars") as? Double
        self.cursorConfigured = secretStore.load(account: CursorSecret.account) != nil
    }

    /// Plants the grok.com address. The popover must ignore it; Settings may show it.
    func replaceAccountEmail(_ email: String?) {
        accountEmail = email
    }

    func updatePollingInterval(_ minutes: Int) {
        pollingMinutes = minutes
        defaults.set(minutes, forKey: "pollingMinutes")
        currentInterval = TimeInterval(minutes * 60)
        scheduleTimer()
        Task { await fetchUsage() }
    }

    func saveManagementSettings(teamID: String, key: String) {
        let trimmedTeam = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard XAIManagementProvider.isValidTeamID(trimmedTeam) else {
            managementError = "Enter a team ID that uses only letters, numbers, dots, hyphens, or underscores."
            return
        }
        if !trimmedKey.isEmpty {
            do {
                try secretStore.save(trimmedKey, account: ManagementSecret.account)
            } catch {
                managementError = "Could not save the management key to the Keychain."
                return
            }
        } else if secretStore.load(account: ManagementSecret.account) == nil {
            managementError = "Enter a management key."
            return
        }
        defaults.set(trimmedTeam, forKey: "managementTeamID")
        managementTeamID = trimmedTeam
        managementConfigured = true
        managementError = nil
        Task { await fetchUsage() }
    }

    func clearManagementSettings() {
        secretStore.delete(account: ManagementSecret.account)
        defaults.removeObject(forKey: "managementTeamID")
        managementTeamID = ""
        managementConfigured = false
        management = nil
        managementError = nil
    }

    func saveCursorSettings(apiKey: String, email: String, organizationID: String, budget: String) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOrg = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBudget = budget.trimmingCharacters(in: .whitespacesAndNewlines)

        let budgetValue: Double?
        if trimmedBudget.isEmpty {
            budgetValue = nil
        } else if let parsed = Double(trimmedBudget), parsed.isFinite, parsed > 0 {
            budgetValue = parsed
        } else {
            cursorError = "Enter a monthly budget in dollars, or leave it blank."
            return
        }
        if !trimmedEmail.isEmpty && !CursorUsageParser.isPlausibleEmail(trimmedEmail) {
            cursorError = "The member email is not usable."
            return
        }
        if !trimmedOrg.isEmpty && !CursorUsageParser.isPlausibleOrganizationID(trimmedOrg) {
            cursorError = "An organization id looks like org_…."
            return
        }
        if !trimmedKey.isEmpty {
            guard CursorUsageParser.isPlausibleAPIKey(trimmedKey) else {
                cursorError = "Enter a Cursor API key that starts with crsr_."
                return
            }
            do {
                try secretStore.save(trimmedKey, account: CursorSecret.account)
            } catch {
                cursorError = "Could not save the Cursor API key to the Keychain."
                return
            }
        } else if secretStore.load(account: CursorSecret.account) == nil {
            cursorError = "Enter a Cursor API key."
            return
        }

        defaults.set(trimmedEmail, forKey: "cursorMemberEmail")
        defaults.set(trimmedOrg, forKey: "cursorOrganizationID")
        if let budgetValue {
            defaults.set(budgetValue, forKey: "cursorBudgetDollars")
        } else {
            defaults.removeObject(forKey: "cursorBudgetDollars")
        }
        cursorMemberEmail = trimmedEmail
        cursorOrganizationID = trimmedOrg
        cursorBudgetDollars = budgetValue
        cursorConfigured = true
        cursorError = nil
        cursorCache = CursorResponseCache()
        cursorBackoffUntil = nil
        nextCursorFetchAt = nil
    }

    func clearCursorSettings() {
        secretStore.delete(account: CursorSecret.account)
        defaults.removeObject(forKey: "cursorMemberEmail")
        defaults.removeObject(forKey: "cursorOrganizationID")
        defaults.removeObject(forKey: "cursorBudgetDollars")
        cursorMemberEmail = ""
        cursorOrganizationID = ""
        cursorBudgetDollars = nil
        cursorConfigured = false
        cursorReading = nil
        cursorError = nil
        cursorCache = CursorResponseCache()
        cursorBackoffUntil = nil
        nextCursorFetchAt = nil
    }

    func startPolling() {
        Task { await fetchUsage(refreshCursor: true) }
        scheduleTimer()
    }

    /// `refreshCursor` skips the hourly cap. It still waits out a Cursor 429.
    func fetchUsage(refreshCursor: Bool = false) async {
        let weeklySample = await fetchWeekly()
        await fetchDashboard()
        let adminSample: Double?
        if sandOwnsTopSlot {
            adminSample = nil
        } else {
            adminSample = await fetchCursor(refresh: refreshCursor)
        }
        let topSample = sandOwnsTopSlot ? fraction(dashboardReading?.grokBotPercent) : adminSample
        let modelsSample = showsSuperGrokPool ? nil : fraction(dashboardReading?.cursorModelsPercent)
        guard weeklySample != nil || topSample != nil || modelsSample != nil else { return }
        historyService?.recordDataPoint(
            pctWeekly: weeklyFraction ?? 0,
            pctBot: topSample,
            includesWeekly: weeklySample != nil,
            pctCursorModels: modelsSample
        )
        notificationService?.checkAndNotify(
            botFraction: topSample,
            weeklyFraction: weeklySample
        )
    }

    /// The weekly fraction to notify on, or nil when this poll did not produce one.
    private func fetchWeekly() async -> Double? {
        let provider = GrokCLIWeeklyProvider(
            authFileURL: authFileURL,
            proxyBaseURL: proxyBaseURL,
            session: session,
            now: now,
            fileManager: .default
        )
        switch await provider.fetch() {
        case .needsLogin(let message):
            isAuthenticated = false
            accountEmail = nil
            reading = nil
            management = nil
            lastError = message
            return nil
        case .failed(let message, let shouldBackoff, let retryAfter):
            isAuthenticated = true
            lastError = message
            if shouldBackoff {
                currentInterval = Self.backoffInterval(
                    retryAfter: retryAfter,
                    currentInterval: currentInterval
                )
                scheduleTimer()
            }
            await fetchManagement()
            return nil
        case .ready(let reading, let email):
            isAuthenticated = true
            accountEmail = email
            self.reading = reading
            lastUpdated = now()
            let sample: Double?
            if reading.hasWeeklyPool, let percent = reading.usedPercent {
                lastError = nil
                sample = min(max(percent / 100.0, 0), 1)
            } else if reading.hasWeeklyPool {
                lastError = reading.unavailableReason
                sample = nil
            } else {
                // Signed in, but this grok.com account has no SuperGrok pool.
                lastError = reading.unavailableReason
                sample = nil
            }
            if currentInterval != baseInterval {
                currentInterval = baseInterval
                scheduleTimer()
            }
            await fetchManagement()
            return sample
        }
    }

    private func fetchDashboard() async {
        let provider = CursorDashboardProvider(
            baseURL: dashboardBaseURL,
            secretsURL: sandSecretsURL,
            homeDirectory: homeDirectory,
            session: session,
            now: now,
            keyProvider: keyProvider,
            fileManager: .default
        )
        switch await provider.fetch() {
        case .notSignedIn:
            dashboardPresence = .absent
            dashboardReading = nil
            dashboardError = nil
        case .needsGrokBot(let message):
            dashboardPresence = .needsRefresh
            dashboardReading = nil
            dashboardError = message
        case .keychainDenied(let message):
            dashboardPresence = .keychainDenied
            dashboardReading = nil
            dashboardError = message
        case .failed(let message):
            dashboardPresence = .failed
            dashboardError = message
        case .ready(let reading):
            dashboardPresence = .ready
            dashboardReading = reading
            dashboardError = nil
            lastUpdated = now()
        }
    }

    /// The bot fraction to notify on, or nil when this poll did not produce a new percent.
    private func fetchCursor(refresh: Bool) async -> Double? {
        guard cursorConfigured, let key = secretStore.load(account: CursorSecret.account) else {
            cursorConfigured = false
            return nil
        }
        let moment = now()
        if let until = cursorBackoffUntil, moment < until {
            return nil
        }
        if !refresh, let next = nextCursorFetchAt, moment < next {
            return nil
        }
        nextCursorFetchAt = moment.addingTimeInterval(CursorUsageParser.hourlyInterval)

        let provider = CursorGrokBotProvider(
            baseURL: cursorBaseURL,
            apiKey: key,
            memberEmail: cursorMemberEmail,
            organizationID: cursorOrganizationID,
            budgetDollars: cursorBudgetDollars,
            session: session,
            now: now
        )
        let (outcome, cache) = await provider.fetch(cache: cursorCache)
        cursorCache = cache
        switch outcome {
        case .notConfigured:
            cursorConfigured = false
            cursorReading = nil
            cursorError = nil
            return nil
        case .notModified:
            cursorError = nil
            cursorBackoffUntil = nil
            lastUpdated = moment
            return nil
        case .ready(let reading):
            cursorBackoffUntil = nil
            cursorReading = reading
            cursorError = reading.unavailableReason
            lastUpdated = moment
            guard let percent = reading.usedPercent else { return nil }
            return min(max(percent / 100.0, 0), 1)
        case .failed(let message, let retryAfter, let clearReading):
            cursorError = message
            if clearReading {
                cursorReading = nil
            }
            if let retryAfter {
                cursorBackoffUntil = moment.addingTimeInterval(retryAfter)
            }
            return nil
        }
    }

    private func fetchManagement() async {
        guard managementConfigured,
              let key = secretStore.load(account: ManagementSecret.account) else {
            management = nil
            managementConfigured = false
            return
        }
        let provider = XAIManagementProvider(
            baseURL: managementBaseURL,
            teamID: managementTeamID,
            apiKey: key,
            session: session,
            now: now
        )
        switch await provider.fetch() {
        case .notConfigured:
            management = nil
            managementConfigured = false
        case .ready(let snapshot):
            management = snapshot
            managementError = nil
        case .failed(let message):
            managementError = message
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = currentInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.fetchUsage() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
