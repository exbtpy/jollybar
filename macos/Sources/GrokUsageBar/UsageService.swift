import Foundation
import Combine

/// Polls the weekly SuperGrok pool and, when configured, the Management API.
///
/// The menu bar and history track the weekly pool percent only. The Management
/// API snapshot is extra detail in the popover; a failure there does not clear
/// the weekly reading.
@MainActor
final class UsageService: ObservableObject {
    @Published var reading: GrokBillingReading?
    @Published var management: ManagementSnapshot?
    @Published var lastError: String?
    @Published var managementError: String?
    @Published var lastUpdated: Date?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var pollingMinutes: Int
    @Published private(set) var managementTeamID: String
    @Published private(set) var managementConfigured = false

    var historyService: UsageHistoryService?
    var notificationService: NotificationService?

    /// 0...1 when a weekly percent is available.
    var weeklyFraction: Double? {
        guard let percent = reading?.usedPercent else { return nil }
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
    private let authFileURL: URL
    private let secretStore: SecretStoring
    private let defaults: UserDefaults
    private let now: () -> Date

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

    func startPolling() {
        Task { await fetchUsage() }
        scheduleTimer()
    }

    func fetchUsage() async {
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
        case .ready(let reading, let email):
            isAuthenticated = true
            accountEmail = email
            self.reading = reading
            lastUpdated = now()
            if reading.usedPercent == nil {
                lastError = reading.unavailableReason
            } else {
                lastError = nil
                let fraction = min(max((reading.usedPercent ?? 0) / 100.0, 0), 1)
                historyService?.recordDataPoint(pctWeekly: fraction)
                notificationService?.checkAndNotify(weeklyFraction: fraction)
            }
            if currentInterval != baseInterval {
                currentInterval = baseInterval
                scheduleTimer()
            }
            await fetchManagement()
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
