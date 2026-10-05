import Foundation

enum EndpointOverride {
    static let proxyKey = "GROK_USAGE_BAR_PROXY_BASE"
    static let managementKey = "GROK_USAGE_BAR_MANAGEMENT_BASE"
    static let authFileKey = "GROK_USAGE_BAR_AUTH_FILE"

    static let defaultProxyBase = URL(string: "https://cli-chat-proxy.grok.com/v1")!
    static let defaultManagementBase = URL(string: "https://management-api.x.ai")!

    nonisolated private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Honours an http(s) loopback override. Anything else is ignored so an
    /// environment variable cannot redirect a bearer token off this machine.
    static func resolvedURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        key: String,
        defaultURL: URL
    ) -> URL {
        let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return defaultURL }
        guard let url = URL(string: raw), isLoopbackHTTP(url) else {
            print("""
            [Endpoint] Ignoring \(key) — only http(s) loopback URLs are allowed. \
            Using \(defaultURL.absoluteString).
            """)
            return defaultURL
        }
        return url
    }

    static func authFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment[authFileKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return expandingTilde(override, fileManager: fileManager)
        }
        if let home = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            return expandingTilde(home, fileManager: fileManager).appendingPathComponent("auth.json")
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok")
            .appendingPathComponent("auth.json")
    }

    static func isLoopbackHTTP(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return loopbackHosts.contains(host)
    }

    /// Refresh tokens are only sent to https issuers, or to loopback http so
    /// tests can stand in for auth.x.ai. A tampered auth file cannot point the
    /// refresh grant at an arbitrary cleartext host.
    static func allowsRefreshIssuer(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && isLoopbackHTTP(url)
    }

    private static func expandingTilde(_ path: String, fileManager: FileManager) -> URL {
        if path == "~" {
            return fileManager.homeDirectoryForCurrentUser
        }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(rest)
        }
        return URL(fileURLWithPath: path)
    }
}

/// Bearer tokens are only sent to the host that was asked for. A 3xx to
/// another host, port, or scheme is not followed, so the Authorization header
/// cannot ride along to somewhere else.
enum RedirectPolicy {
    static func allows(from original: URL, to redirected: URL) -> Bool {
        guard let originalScheme = original.scheme?.lowercased(),
              let redirectedScheme = redirected.scheme?.lowercased(),
              originalScheme == redirectedScheme,
              let originalHost = original.host?.lowercased(),
              let redirectedHost = redirected.host?.lowercased(),
              originalHost == redirectedHost else {
            return false
        }
        return port(of: original) == port(of: redirected)
    }

    private static func port(of url: URL) -> Int {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return -1
        }
    }
}

final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let redirected = request.url,
              RedirectPolicy.allows(from: original, to: redirected) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Header values copied out of an auth file. Control characters would split
/// the header; anything outside printable ASCII is refused rather than sent.
enum HeaderSafety {
    static func isSafe(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 8192 else { return false }
        return value.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }
}

enum WeeklyPoolFetchResult: Equatable {
    case ready(GrokBillingReading, email: String?)
    case needsLogin(String)
    case failed(String, shouldBackoff: Bool, retryAfter: TimeInterval?)
}

enum ManagementFetchResult: Equatable {
    case notConfigured
    case ready(ManagementSnapshot)
    case failed(String)
}

protocol WeeklyPoolProviding {
    func fetch() async -> WeeklyPoolFetchResult
}

protocol ManagementProviding {
    func fetch() async -> ManagementFetchResult
}

/// Reads the weekly SuperGrok pool with the token `grok login` already stored.
/// Does not start an OAuth login. A missing or unusable auth file becomes
/// `needsLogin`. Refresh uses the stored refresh token against the issuer's
/// OIDC token endpoint and writes the new token back to the same auth file.
struct GrokCLIWeeklyProvider: WeeklyPoolProviding {
    let authFileURL: URL
    let proxyBaseURL: URL
    let session: URLSession
    let now: () -> Date
    let fileManager: FileManager

    func fetch() async -> WeeklyPoolFetchResult {
        switch GrokAuthFile.load(url: authFileURL, now: now(), fileManager: fileManager) {
        case .missingFile:
            return .needsLogin(
                "No grok CLI session found. \(GrokAuthFile.loginInstructions)"
            )
        case .unreadable:
            return .failed("Could not read the grok auth file.", shouldBackoff: false, retryAfter: nil)
        case .noUsableSession(let message):
            return .needsLogin(message)
        case .credential(let credential):
            var active = credential
            if active.needsRefresh(at: now()) {
                switch await refresh(active) {
                case .refreshed(let updated):
                    active = updated
                case .permanent(let message):
                    if active.isExpired(at: now()) {
                        return .needsLogin(message)
                    }
                case .transient(let message):
                    if active.isExpired(at: now()) {
                        return .failed(message, shouldBackoff: true, retryAfter: nil)
                    }
                }
            }
            return await requestBilling(credential: active, allowRefresh: true)
        }
    }

    private func requestBilling(
        credential: GrokSessionCredential,
        allowRefresh: Bool
    ) async -> WeeklyPoolFetchResult {
        guard HeaderSafety.isSafe(credential.accessToken) else {
            return .needsLogin("The saved session token is not usable. \(GrokAuthFile.loginInstructions)")
        }
        let url = billingURL
        do {
            let (data, http) = try await send(credential: credential, url: url)
            if http.statusCode == 401, allowRefresh {
                switch await refresh(credential) {
                case .refreshed(let updated):
                    return await requestBilling(credential: updated, allowRefresh: false)
                case .permanent(let message):
                    return .needsLogin(message)
                case .transient(let message):
                    return .failed(message, shouldBackoff: true, retryAfter: nil)
                }
            }
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                return .failed(
                    "Rate limited by the billing service.",
                    shouldBackoff: true,
                    retryAfter: retryAfter
                )
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = safeErrorDetail(data, secrets: secrets(in: credential))
                let suffix = detail.map { " \($0)" } ?? ""
                return .failed(
                    "Billing request failed (HTTP \(http.statusCode)).\(suffix)",
                    shouldBackoff: true,
                    retryAfter: nil
                )
            }
            let reading = GrokBillingParser.parse(data, now: now())
            return .ready(reading, email: credential.email)
        } catch {
            return .failed(
                "Could not reach the billing service. Will retry.",
                shouldBackoff: true,
                retryAfter: nil
            )
        }
    }

    private var billingURL: URL {
        let endpoint = proxyBaseURL.appendingPathComponent("billing")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "format", value: "credits")]
        return components?.url ?? endpoint
    }

    private func send(
        credential: GrokSessionCredential,
        url: URL
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        // Required by the CLI proxy so the bearer is validated as a CLI session.
        // Verified in grok-build `billing.rs` and the shell README (`xai-grok-cli`).
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Honest client name. The official CLI sends its own version here.
        // claudia's captured call succeeded with only Authorization and
        // X-XAI-Token-Auth, so this header is not treated as load-bearing.
        request.setValue("grok-usage-bar", forHTTPHeaderField: "x-grok-client-version")
        if HeaderSafety.isSafe(credential.userId) {
            request.setValue(credential.userId, forHTTPHeaderField: "x-userid")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    private enum RefreshOutcome {
        case refreshed(GrokSessionCredential)
        case permanent(String)
        case transient(String)
    }

    private func refresh(_ credential: GrokSessionCredential) async -> RefreshOutcome {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty,
              let clientID = credential.resolvedClientID,
              let issuer = credential.resolvedIssuer,
              EndpointOverride.allowsRefreshIssuer(issuer) else {
            return .permanent("Session expired. \(GrokAuthFile.loginInstructions)")
        }

        let discovery = issuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/.well-known/openid-configuration"
        guard let discoveryURL = URL(string: discovery) else {
            return .permanent("Session expired. \(GrokAuthFile.loginInstructions)")
        }

        let tokenEndpoint: URL
        do {
            var request = URLRequest(url: discoveryURL)
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let endpointString = json["token_endpoint"] as? String,
                  let endpoint = URL(string: endpointString),
                  EndpointOverride.allowsRefreshIssuer(endpoint) else {
                return .transient("Could not refresh the grok session. Will retry.")
            }
            tokenEndpoint = endpoint
        } catch {
            return .transient("Could not refresh the grok session. Will retry.")
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(urlFormEncode(refreshToken))",
            "client_id=\(urlFormEncode(clientID))"
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .transient("Could not refresh the grok session. Will retry.")
            }
            data = responseData
            http = httpResponse
        } catch {
            return .transient("Could not refresh the grok session. Will retry.")
        }

        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            if (400..<500).contains(http.statusCode) {
                return .permanent("Session expired. \(GrokAuthFile.loginInstructions)")
            }
            return .transient("Could not refresh the grok session. Will retry.")
        }

        let rotatedRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        let expiresAt: Date?
        if let seconds = JSONValues.double(json["expires_in"]) {
            expiresAt = now().addingTimeInterval(seconds)
        } else {
            expiresAt = nil
        }
        let created = now()
        guard let original = try? Data(contentsOf: authFileURL),
              let updated = GrokAuthFile.updatedDocument(
                data: original,
                scopeKey: credential.scopeKey,
                accessToken: accessToken,
                refreshToken: rotatedRefresh,
                expiresAt: expiresAt,
                createTime: created
              ) else {
            return .transient("Could not refresh the grok session. Will retry.")
        }
        do {
            try GrokAuthFile.writeAtomically(updated, to: authFileURL, fileManager: fileManager)
        } catch {
            return .transient("Could not refresh the grok session. Will retry.")
        }

        let updated = GrokSessionCredential(
            scopeKey: credential.scopeKey,
            accessToken: accessToken,
            refreshToken: rotatedRefresh,
            expiresAt: expiresAt,
            createTime: created,
            userId: credential.userId,
            email: credential.email,
            authMode: credential.authMode,
            oidcIssuer: credential.oidcIssuer,
            oidcClientId: credential.oidcClientId
        )
        return .refreshed(updated)
    }

    private func secrets(in credential: GrokSessionCredential) -> [String] {
        [credential.accessToken, credential.refreshToken].compactMap { $0 }
    }

    private func safeErrorDetail(_ data: Data, secrets: [String]) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? String else {
            return nil
        }
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 180, !trimmed.contains("Bearer") else {
            return nil
        }
        let redacted = SecretRedaction.redacting(trimmed, secrets: secrets)
        guard redacted == trimmed else { return nil }
        return trimmed
    }

    private func urlFormEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Optional console prepaid balance and 7-day API spend.
/// The management key stays in the Keychain; this type only receives it for the request.
struct XAIManagementProvider: ManagementProviding {
    let baseURL: URL
    let teamID: String
    let apiKey: String
    let session: URLSession
    let now: () -> Date

    static func isValidTeamID(_ id: String) -> Bool {
        guard (1...128).contains(id.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    func fetch() async -> ManagementFetchResult {
        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.isEmpty, !key.isEmpty else { return .notConfigured }
        guard Self.isValidTeamID(team) else {
            return .failed("Team ID contains unsupported characters.")
        }
        guard HeaderSafety.isSafe(key) else {
            return .failed("The management key is not usable.")
        }

        guard let balanceURL = endpoint("prepaid/balance", teamID: team),
              let usageURL = endpoint("usage", teamID: team) else {
            return .failed("Could not build the Management API URL.")
        }

        do {
            let (balanceData, balanceHTTP) = try await send(url: balanceURL, method: "GET", body: nil, apiKey: key)
            guard (200..<300).contains(balanceHTTP.statusCode) else {
                return .failed("Management API balance failed (HTTP \(balanceHTTP.statusCode)).")
            }
            let cents: Int64?
            switch ManagementAPIParser.parseBalance(balanceData) {
            case .success(let value):
                cents = value
            case .failure:
                return .failed("Management API balance had an unexpected shape.")
            }

            let end = now()
            let start = end.addingTimeInterval(-7 * 24 * 60 * 60)
            let payload: [String: Any] = [
                "analyticsRequest": [
                    "timeRange": [
                        "startTime": DateParsing.formatAnalyticsTimestamp(start),
                        "endTime": DateParsing.formatAnalyticsTimestamp(end),
                        "timezone": "Etc/GMT"
                    ],
                    "timeUnit": "TIME_UNIT_DAY",
                    "values": [
                        ["name": "usd", "aggregation": "AGGREGATION_SUM"]
                    ],
                    "groupBy": ["description"],
                    "filters": []
                ]
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let (spendData, spendHTTP) = try await send(url: usageURL, method: "POST", body: body, apiKey: key)
            let spend: Double?
            if (200..<300).contains(spendHTTP.statusCode) {
                switch ManagementAPIParser.parseSpend(spendData) {
                case .success(let value):
                    spend = value
                case .failure:
                    spend = nil
                }
            } else {
                spend = nil
            }
            return .ready(ManagementSnapshot(prepaidTotalCents: cents, spend7dUSD: spend))
        } catch {
            return .failed("Could not reach the Management API.")
        }
    }

    private func endpoint(_ suffix: String, teamID: String) -> URL? {
        let encoded = teamID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? teamID
        let root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(root)/v1/billing/teams/\(encoded)/\(suffix)")
    }

    private func send(
        url: URL,
        method: String,
        body: Data?,
        apiKey: String
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
