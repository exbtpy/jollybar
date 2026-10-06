import Foundation
import CommonCrypto

/// Read-only Grok Bot usage from the desktop app's Cursor session.
///
/// Adapted from grokbot-meter (MIT, Copyright (c) 2026 Nuno Costa):
/// https://github.com/nuno/grokbot-meter
/// The access token is taken from `sand-secrets.json` and, when it is sealed
/// with Chromium safeStorage, decrypted with the Keychain item
/// "Grok Bot Safe Storage" / "Grok Bot Key". The refresh token is never
/// decrypted and never sent. This app does not refresh the Grok Bot sign-in.
///
/// Requests, all POST with body `{}`:
/// - `https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus`
/// - `https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
/// - `https://api2.cursor.sh/aiserver.v1.DashboardService/GetMe`
///
/// Headers: `Authorization: Bearer`, `Content-Type: application/json`,
/// `Connect-Protocol-Version: 1`.
enum GrokBotSessionNotice {
    static let openGrokBot = "Open Grok Bot to refresh sign-in"
    static let keychainDenied = "Keychain access denied. Reopen \(AppIdentity.displayName) to retry."
    static let notSignedIn = "Open Grok Bot and sign in. Teams and Enterprise can use an API key in Settings instead."
}

enum GrokBotKeyState {
    case ok(Data)
    case missing
    case denied
}

protocol GrokBotKeyProviding {
    func derivedKey() -> GrokBotKeyState
}

/// macOS Keychain lookup. A missing item is retried. Deny, cancel, and
/// timeout are remembered for this process so the prompt is not repeated.
final class MacGrokBotKeyProvider: GrokBotKeyProviding {
    private let lock = NSLock()
    private var cached: GrokBotKeyState?

    func derivedKey() -> GrokBotKeyState {
        lock.lock()
        if let cached, !cached.isMissing {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let state = Self.readKey()
        lock.lock()
        if !state.isMissing {
            cached = state
        }
        lock.unlock()
        return state
    }

    /// `security` exit status for errSecItemNotFound.
    private static let itemNotFound: Int32 = 44

    private static func readKey() -> GrokBotKeyState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Grok Bot Safe Storage",
            "-a", "Grok Bot Key",
            "-w"
        ]
        let output = Pipe()
        let discarded = Pipe()
        process.standardOutput = output
        process.standardError = discarded

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .missing
        }
        if finished.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            return .denied
        }
        if process.terminationStatus == itemNotFound {
            return .missing
        }
        if process.terminationStatus != 0 {
            return .denied
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let secret = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !secret.isEmpty, let key = GrokBotSafeStorage.deriveKey(password: secret) else {
            return .missing
        }
        return .ok(key)
    }
}

private extension GrokBotKeyState {
    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}

/// Chromium safeStorage on macOS: PBKDF2-SHA1, then `v10` + AES-128-CBC.
/// The IV is sixteen space bytes. Adapted from grokbot-meter `macSafeStorage.ts`.
enum GrokBotSafeStorage {
    static let iterations = 1003
    static let keyLength = 16

    static func deriveKey(password: String) -> Data? {
        let salt = Array("saltysalt".utf8)
        let saltCount = salt.count
        let passwordLength = password.lengthOfBytes(using: .utf8)
        var key = Data(count: keyLength)
        let status: CCCryptorStatus = password.withCString { passwordPointer in
            salt.withUnsafeBytes { saltBytes in
                key.withUnsafeMutableBytes { keyBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer,
                        passwordLength,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        saltCount,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(iterations),
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    static func decrypt(base64 ciphertext: String, key: Data) -> String? {
        guard key.count == keyLength else { return nil }
        guard var data = decodeCiphertext(ciphertext), data.count >= 3 else { return nil }
        let prefix = data.prefix(3)
        guard prefix.elementsEqual(Array("v10".utf8)) else { return nil }
        data.removeFirst(3)
        guard !data.isEmpty, data.count.isMultiple(of: 16) else { return nil }

        let iv = Data(repeating: 0x20, count: 16)
        let cipherLength = data.count
        var decrypted = Data(count: cipherLength + kCCBlockSizeAES128)
        let outCapacity = decrypted.count
        var moved = 0
        let status = data.withUnsafeBytes { cipherBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    decrypted.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            keyLength,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress,
                            cipherLength,
                            outBytes.baseAddress,
                            outCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, moved > 0 else { return nil }
        decrypted.removeSubrange(moved..<decrypted.count)
        let text = String(data: decrypted, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func decodeCiphertext(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: trimmed), !data.isEmpty {
            return data
        }
        return decodeBase64URL(trimmed)
    }
}

struct CursorOnDemandSpend: Equatable {
    /// `spendLimitUsage.individualUsed`, cents.
    let usedCents: Int64
    /// `spendLimitUsage.individualLimit`, cents. Absent when there is no cap.
    let limitCents: Int64
    /// `billingCycleEnd`.
    let resetsAt: Date?
}

struct CursorDashboardReading: Equatable {
    /// `GetSandUsageStatus.usagePercent`. Used percent of the Grok Bot weekly pool.
    let grokBotPercent: Double?
    let resetsAt: Date?
    let includedLimitZero: Bool
    let hasAvailableUsage: Bool?
    /// `GetMe` email or display name. Nil when that call fails.
    let accountEmail: String?
    /// `planUsage.autoPercentUsed` (or `individualUsage.plan`). Cursor Models.
    /// Medium confidence: public Cursor usage parsers, not this owner's body.
    let cursorModelsPercent: Double?
    /// `planUsage.apiPercentUsed`. Other Models. Same confidence as above.
    let otherModelsPercent: Double?
    /// False when `GetCurrentPeriodUsage` failed. That is not "no cap".
    let onDemandKnown: Bool
    let onDemand: CursorOnDemandSpend?
    let grokBotUnavailableReason: String?
    let cursorModelsUnavailableReason: String?

    var pausedAtLimit: Bool {
        if includedLimitZero { return true }
        if let grokBotPercent, grokBotPercent >= 100 { return true }
        return false
    }
}

enum CursorDashboardFetchResult: Equatable {
    case notSignedIn
    case needsGrokBot(String)
    case keychainDenied(String)
    case failed(String)
    case ready(CursorDashboardReading)
}

enum CursorDashboardPresence: Equatable {
    case absent
    case ready
    case needsRefresh
    case keychainDenied
    case failed
}

/// Parses the three dashboard JSON bodies. Field names accept camelCase and
/// snake_case. `autoPercentUsed` / `apiPercentUsed` are read from `planUsage`
/// first, then `individualUsage.plan`. A missing percent stays nil.
enum CursorDashboardParser {
    private static let week: TimeInterval = 7 * 24 * 60 * 60
    /// Grok Bot's unlimited on-demand sentinel. A limit at or above this is no cap.
    static let unlimitedSpendLimit: Int64 = 2_147_483_647

    static func parseSand(_ data: Data, now: Date = Date()) -> (percent: Double?, resetsAt: Date?, includedLimitZero: Bool, hasAvailableUsage: Bool?, reason: String?) {
        guard let object = jsonObject(data) else {
            return (nil, nil, false, nil, "The Grok Bot usage response was not JSON.")
        }
        let includedLimitZero = bool(object, "includedLimitZero", "included_limit_zero") ?? false
        let hasAvailableUsage = bool(object, "hasAvailableUsage", "has_available_usage")
        let percent = finite(object, "usagePercent", "usage_percent").flatMap(usablePercent)
        var resetsAt = timestamp(object["nextResetTimestampUtc"] ?? object["next_reset_timestamp_utc"])
        let trial = timestamp(object["sandTrialExpiresAt"] ?? object["sand_trial_expires_at"])
        let trialActive = trial.map { $0 > now } ?? false
        if resetsAt == nil, percent != nil || trialActive {
            let start = timestamp(object["currentPeriodStart"] ?? object["current_period_start"])
            if let start {
                resetsAt = start.addingTimeInterval(week)
            } else if let trial {
                resetsAt = trial
            }
        }
        let reason = percent == nil ? "GetSandUsageStatus did not include usagePercent." : nil
        return (percent, resetsAt, includedLimitZero, hasAvailableUsage, reason)
    }

    struct PeriodParse: Equatable {
        var cursorModelsPercent: Double?
        var otherModelsPercent: Double?
        var onDemand: CursorOnDemandSpend?
        var cursorModelsReason: String?
    }

    static func parsePeriod(_ data: Data, now: Date = Date()) -> PeriodParse? {
        guard let object = jsonObject(data) else { return nil }
        _ = now
        let plan = planObject(object)
        let models = plan.flatMap { finite($0, "autoPercentUsed", "auto_percent_used").flatMap(usablePercent) }
        let other = plan.flatMap { finite($0, "apiPercentUsed", "api_percent_used").flatMap(usablePercent) }
        let reason = models == nil
            ? "GetCurrentPeriodUsage did not include planUsage.autoPercentUsed."
            : nil
        return PeriodParse(
            cursorModelsPercent: models,
            otherModelsPercent: other,
            onDemand: parseOnDemand(object),
            cursorModelsReason: reason
        )
    }

    static func parseEmail(_ data: Data) -> String? {
        guard let object = jsonObject(data) else { return nil }
        if let label = accountLabel(object) { return label }
        if let user = object["user"] as? [String: Any], let label = accountLabel(user) { return label }
        if let me = object["me"] as? [String: Any], let label = accountLabel(me) { return label }
        return nil
    }

    static func dashboardURL(base: URL, method: String) -> URL? {
        let root = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast())
            : base.absoluteString
        return URL(string: root + "/aiserver.v1.DashboardService/" + method)
    }

    private static func parseOnDemand(_ object: [String: Any]) -> CursorOnDemandSpend? {
        let spend = (object["spendLimitUsage"] ?? object["spend_limit_usage"]) as? [String: Any]
        guard let spend else { return nil }
        let used = int64(spend, "individualUsed", "individual_used") ?? 0
        guard let limit = normalizeSpendLimit(int64(spend, "individualLimit", "individual_limit")) else {
            return nil
        }
        let reset = timestamp(object["billingCycleEnd"] ?? object["billing_cycle_end"])
        return CursorOnDemandSpend(usedCents: used, limitCents: limit, resetsAt: reset)
    }

    /// Null limit means there is no cap (unlimited sentinel, missing, or <= 0).
    static func normalizeSpendLimit(_ limit: Int64?) -> Int64? {
        guard let limit, limit > 0, limit < unlimitedSpendLimit else { return nil }
        return limit
    }

    private static func planObject(_ root: [String: Any]) -> [String: Any]? {
        let candidates: [[String: Any]?] = [
            (root["planUsage"] ?? root["plan_usage"]) as? [String: Any],
            nestedPlan(root["individualUsage"] ?? root["individual_usage"]),
        ]
        return candidates.compactMap { $0 }.first { hasPlanPercent($0) }
    }

    private static func nestedPlan(_ value: Any?) -> [String: Any]? {
        guard let object = value as? [String: Any] else { return nil }
        return (object["plan"] ?? object["planUsage"] ?? object["plan_usage"]) as? [String: Any]
    }

    private static func hasPlanPercent(_ object: [String: Any]) -> Bool {
        finite(object, "autoPercentUsed", "auto_percent_used") != nil
            || finite(object, "apiPercentUsed", "api_percent_used") != nil
            || finite(object, "totalPercentUsed", "total_percent_used") != nil
    }

    private static func accountLabel(_ object: [String: Any]) -> String? {
        for keys in [["email", "Email"], ["userEmail", "user_email"], ["displayName", "display_name"]] {
            if let text = string(object, keys[0], keys[1])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func string(_ object: [String: Any], _ camel: String, _ snake: String) -> String? {
        (object[camel] ?? object[snake]) as? String
    }

    private static func bool(_ object: [String: Any], _ camel: String, _ snake: String) -> Bool? {
        let value = object[camel] ?? object[snake]
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return number.intValue != 0
        default:
            return nil
        }
    }

    private static func finite(_ object: [String: Any], _ camel: String, _ snake: String) -> Double? {
        JSONValues.double(object[camel] ?? object[snake])
    }

    private static func int64(_ object: [String: Any], _ camel: String, _ snake: String) -> Int64? {
        JSONValues.int64(object[camel] ?? object[snake])
    }

    /// 0...1000. A value slightly above 100 is kept so the bar can sit at the cap.
    private static func usablePercent(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0, value <= 1000 else { return nil }
        return value
    }

    static func timestamp(_ value: Any?) -> Date? {
        switch value {
        case let string as String:
            if let date = DateParsing.parseISO8601(string) { return date }
            if let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return dateFromEpoch(number)
            }
            return nil
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return dateFromEpoch(number.doubleValue)
        default:
            return nil
        }
    }

    static func dateFromEpoch(_ value: Double) -> Date? {
        guard value.isFinite else { return nil }
        let seconds = abs(value) >= 100_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }
}

enum GrokBotSession {
    struct LoadedAccess {
        var access: String?
        var hasCredentials: Bool
        var keychainDenied: Bool
    }

    static func defaultURLs(home: URL) -> [URL] {
        [
            home.appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json"),
            home.appendingPathComponent(".config/Grok Bot/sand-secrets.json"),
            home.appendingPathComponent(".grokbot/sand-secrets.json"),
            home.appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence/sand-secrets.json"),
            home.appendingPathComponent(".config/Grok Bot/sand-client-persistence/sand-secrets.json"),
        ]
    }

    /// Decrypts only the access token. A refresh token marks the file as a
    /// signed-in session and is otherwise ignored.
    static func loadAccess(
        urls: [URL],
        fileManager: FileManager = .default,
        decrypt: (String) -> String?,
        keyDenied: () -> Bool = { false }
    ) -> LoadedAccess {
        var hasCredentials = false
        var sawDenied = false
        let decryptTracking: (String) -> String? = { ciphertext in
            let value = decrypt(ciphertext)
            if value == nil, keyDenied() {
                sawDenied = true
            }
            return value
        }
        for url in urls {
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            var candidates = [tokenFields(object)]
            if let account = activeAccountFields(object) {
                candidates.append(account)
            }
            for fields in candidates {
                if fields.access != nil || fields.refresh != nil {
                    hasCredentials = true
                }
                guard let rawAccess = fields.access else { continue }
                guard let access = unwrap(rawAccess, decrypt: decryptTracking) else { continue }
                if GrokBotToken.looksLikeJWT(access) {
                    return LoadedAccess(access: access, hasCredentials: true, keychainDenied: sawDenied)
                }
            }
        }
        return LoadedAccess(access: nil, hasCredentials: hasCredentials, keychainDenied: sawDenied)
    }

    static func unwrap(_ raw: String, decrypt: (String) -> String?) -> String? {
        let trimmed = normalize(raw)
        guard !trimmed.isEmpty else { return nil }
        let plaintextPrefix = "plaintext:v1:"
        if trimmed.hasPrefix(plaintextPrefix) {
            let plain = trimmed.dropFirst(plaintextPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return plain.isEmpty ? nil : String(plain)
        }
        let scopedPrefix = "scoped:v1:"
        if trimmed.hasPrefix(scopedPrefix) {
            guard let ciphertext = trimmed.split(separator: ":").last, !ciphertext.isEmpty else {
                return nil
            }
            return decrypt(String(ciphertext))
        }
        if GrokBotToken.looksLikeJWT(trimmed) {
            return trimmed
        }
        return decrypt(trimmed)
    }

    private struct TokenFields {
        var access: String?
        var refresh: String?
    }

    private static func tokenFields(_ object: [String: Any]) -> TokenFields {
        TokenFields(
            access: string(object, "cursor-access-token", "cursorAccessToken"),
            refresh: string(object, "cursor-refresh-token", "cursorRefreshToken")
        )
    }

    private static func activeAccountFields(_ object: [String: Any]) -> TokenFields? {
        let raw = object["cursor-accounts"] ?? object["cursorAccounts"] ?? object["cursor_accounts"]
        let inner: [String: Any]?
        if let text = raw as? String {
            let normalized = normalize(text)
            inner = (try? JSONSerialization.jsonObject(with: Data(normalized.utf8)) as? [String: Any])
                ?? (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        } else {
            inner = raw as? [String: Any]
        }
        guard let inner,
              let active = (inner["active"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !active.isEmpty,
              let accounts = inner["accounts"] as? [String: Any],
              let account = accounts[active] as? [String: Any] else {
            return nil
        }
        return tokenFields(account)
    }

    private static func string(_ object: [String: Any], _ first: String, _ second: String) -> String? {
        if let value = object[first] as? String { return value }
        return object[second] as? String
    }

    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
           let string = parsed as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            let inner = trimmed.dropFirst().dropLast().replacingOccurrences(of: "\\\"", with: "\"")
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

enum GrokBotToken {
    private static let skew: TimeInterval = 60

    static func looksLikeJWT(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 24 else { return false }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-+/=")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// An unreadable `exp` is treated as not expired so the server can decide.
    static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = decodeBase64URL(String(parts[1])) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = JSONValues.double(object["exp"]),
              let date = CursorDashboardParser.dateFromEpoch(exp) else {
            return false
        }
        return date.addingTimeInterval(-skew) <= now
    }
}

/// Looks up the safeStorage key only when a ciphertext actually needs it.
private final class GrokBotKeyLookup {
    let provider: GrokBotKeyProviding
    private var state: GrokBotKeyState?
    private(set) var denied = false

    init(provider: GrokBotKeyProviding) {
        self.provider = provider
    }

    func decrypt(_ ciphertext: String) -> String? {
        if state == nil {
            state = provider.derivedKey()
        }
        if case .denied = state {
            denied = true
        }
        guard case .ok(let key) = state else { return nil }
        return GrokBotSafeStorage.decrypt(base64: ciphertext, key: key)
    }
}

struct CursorDashboardProvider {
    let baseURL: URL
    /// When set, only this file is read. A missing override means signed out,
    /// so tests never scan the real home directory.
    let secretsURL: URL?
    let homeDirectory: URL
    let session: URLSession
    let now: () -> Date
    let keyProvider: GrokBotKeyProviding
    let fileManager: FileManager

    func fetch() async -> CursorDashboardFetchResult {
        let urls: [URL]
        if let secretsURL {
            guard fileManager.fileExists(atPath: secretsURL.path) else {
                return .notSignedIn
            }
            urls = [secretsURL]
        } else {
            urls = GrokBotSession.defaultURLs(home: homeDirectory)
        }

        let lookup = GrokBotKeyLookup(provider: keyProvider)
        let loaded = await Task.detached(priority: .userInitiated) {
            GrokBotSession.loadAccess(
                urls: urls,
                fileManager: fileManager,
                decrypt: { lookup.decrypt($0) },
                keyDenied: { lookup.denied }
            )
        }.value

        guard let access = loaded.access else {
            if loaded.keychainDenied {
                return .keychainDenied(GrokBotSessionNotice.keychainDenied)
            }
            if loaded.hasCredentials {
                return .needsGrokBot(GrokBotSessionNotice.openGrokBot)
            }
            return .notSignedIn
        }
        guard HeaderSafety.isSafe(access) else {
            return .needsGrokBot(GrokBotSessionNotice.openGrokBot)
        }
        if GrokBotToken.isExpired(access, now: now()) {
            return .needsGrokBot(GrokBotSessionNotice.openGrokBot)
        }

        let usage = await post(method: "GetSandUsageStatus", token: access)
        switch usage {
        case .unauthorized:
            return .needsGrokBot(GrokBotSessionNotice.openGrokBot)
        case .failed(let message):
            return .failed(message)
        case .ok(let data):
            let sand = CursorDashboardParser.parseSand(data, now: now())
            async let emailCall = post(method: "GetMe", token: access)
            async let periodCall = post(method: "GetCurrentPeriodUsage", token: access)
            let email = await emailCall
            let period = await periodCall
            let emailText: String?
            if case .ok(let emailData) = email {
                emailText = CursorDashboardParser.parseEmail(emailData)
            } else {
                emailText = nil
            }
            let periodParse: CursorDashboardParser.PeriodParse?
            let periodFailed: Bool
            switch period {
            case .ok(let periodData):
                periodParse = CursorDashboardParser.parsePeriod(periodData, now: now())
                periodFailed = periodParse == nil
            case .unauthorized, .failed:
                periodParse = nil
                periodFailed = true
            }
            let reading = CursorDashboardReading(
                grokBotPercent: sand.percent,
                resetsAt: sand.resetsAt,
                includedLimitZero: sand.includedLimitZero,
                hasAvailableUsage: sand.hasAvailableUsage,
                accountEmail: emailText,
                cursorModelsPercent: periodParse?.cursorModelsPercent,
                otherModelsPercent: periodParse?.otherModelsPercent,
                onDemandKnown: !periodFailed,
                onDemand: periodParse?.onDemand,
                grokBotUnavailableReason: sand.reason,
                cursorModelsUnavailableReason: periodFailed
                    ? "Period usage request failed."
                    : periodParse?.cursorModelsReason
            )
            return .ready(reading)
        }
    }

    private enum Call {
        case ok(Data)
        case unauthorized
        case failed(String)
    }

    private func post(method: String, token: String) async -> Call {
        guard let url = CursorDashboardParser.dashboardURL(base: baseURL, method: method) else {
            return .failed("The Cursor dashboard URL is not usable.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("\(method) request failed.")
            }
            if http.statusCode == 401 {
                return .unauthorized
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed("\(method) request failed (HTTP \(http.statusCode)).")
            }
            return .ok(data)
        } catch {
            return .failed("Could not reach the Cursor dashboard.")
        }
    }
}

func decodeBase64URL(_ value: String) -> Data? {
    var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = text.count % 4
    if remainder > 0 {
        text += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: text)
}
