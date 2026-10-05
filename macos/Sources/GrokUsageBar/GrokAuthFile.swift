import Foundation

/// One session entry from `~/.grok/auth.json`.
///
/// The file is a JSON object keyed by scope. Official layout
/// (`xai-grok-shell` `auth/model.rs`):
/// - OIDC scope key: `https://auth.x.ai::<client id>`
///   (the enterprise installer uses `https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828`)
/// - Legacy scope key: `https://accounts.x.ai/sign-in`
/// - API-key scope key: `xai::api_key` (not a grok.com session; billing rejects it)
///
/// Entry fields used here: `key`, `auth_mode`, `refresh_token`, `expires_at`,
/// `create_time`, `user_id`, `email`, `oidc_issuer`, `oidc_client_id`.
/// `auth_mode` is snake_case (`oidc`, `external`, `api_key`, `web_login`,
/// alias `grok` for the legacy web login).
///
/// Descriptions never include the token.
struct GrokSessionCredential: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let scopeKey: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let createTime: Date?
    let userId: String
    let email: String?
    let authMode: String
    let oidcIssuer: String?
    let oidcClientId: String?

    /// Official early-invalidation buffer is 5 minutes (`DEFAULT_EARLY_INVALIDATION_SECS`).
    func needsRefresh(at now: Date, leeway: TimeInterval = 300) -> Bool {
        guard hasRefreshMaterial else { return false }
        return expiryDate(leeway: leeway).map { now >= $0 } ?? false
    }

    func isExpired(at now: Date) -> Bool {
        expiryDate(leeway: 0).map { now >= $0 } ?? false
    }

    var hasRefreshMaterial: Bool {
        guard let refreshToken, !refreshToken.isEmpty else { return false }
        return resolvedClientID != nil && resolvedIssuer != nil
    }

    /// Prefer the stored `oidc_client_id`. If a file omitted it, the suffix of
    /// an `https://auth.x.ai::<id>` scope key is the client id the installer uses.
    var resolvedClientID: String? {
        if let oidcClientId, !oidcClientId.isEmpty {
            return oidcClientId
        }
        let prefix = GrokAuthFile.oidcScopePrefix
        guard scopeKey.hasPrefix(prefix) else { return nil }
        let suffix = String(scopeKey.dropFirst(prefix.count))
        return suffix.isEmpty ? nil : suffix
    }

    /// Prefer `oidc_issuer`. OIDC scope keys without an issuer fall back to
    /// `https://auth.x.ai`, which is the issuer `grok login` uses.
    var resolvedIssuer: URL? {
        if let oidcIssuer, let url = URL(string: oidcIssuer), url.scheme != nil {
            return url
        }
        if scopeKey.hasPrefix(GrokAuthFile.oidcScopePrefix) || scopeKey == "https://auth.x.ai" {
            return URL(string: "https://auth.x.ai")
        }
        return nil
    }

    var description: String {
        "GrokSession(scope: \(scopeKey), mode: \(authMode), userSet: \(!userId.isEmpty))"
    }

    var debugDescription: String { description }

    private func expiryDate(leeway: TimeInterval) -> Date? {
        if let expiresAt {
            return expiresAt.addingTimeInterval(-leeway)
        }
        // Official fallback when the server sent no `expires_in`: 30 days from
        // `create_time` (`TOKEN_TTL`). No create time → we do not invent one.
        if let createTime {
            return createTime.addingTimeInterval(GrokAuthFile.tokenTTL - leeway)
        }
        return nil
    }
}

enum GrokAuthLoadResult: Equatable {
    case credential(GrokSessionCredential)
    case missingFile
    case unreadable
    case noUsableSession(String)
}

enum GrokAuthFile {
    static let legacyScope = "https://accounts.x.ai/sign-in"
    static let oidcScopePrefix = "https://auth.x.ai::"
    static let apiKeyScope = "xai::api_key"
    static let tokenTTL: TimeInterval = 30 * 24 * 60 * 60

    static let loginInstructions = "Run `grok login` in Terminal, then refresh."

    static func load(url: URL, now: Date = Date(), fileManager: FileManager = .default) -> GrokAuthLoadResult {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missingFile
        }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable
        }
        return load(from: data, now: now)
    }

    static func load(from data: Data, now: Date = Date()) -> GrokAuthLoadResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable
        }

        let entries: [(String, [String: Any])] = root.compactMap { key, value in
            guard let object = value as? [String: Any] else { return nil }
            return (key, object)
        }

        let oidc = entries
            .filter { $0.0.hasPrefix(oidcScopePrefix) }
            .compactMap { credential(scopeKey: $0.0, entry: $0.1) }
            .filter { isSessionMode($0.authMode) }
        if let best = preferred(oidc, now: now) {
            return .credential(best)
        }

        if let legacy = entries.first(where: { $0.0 == legacyScope }),
           let credential = credential(scopeKey: legacy.0, entry: legacy.1),
           isSessionMode(credential.authMode) {
            return .credential(credential)
        }

        let otherSessions = entries
            .filter { $0.0 != apiKeyScope && !$0.0.hasPrefix(oidcScopePrefix) && $0.0 != legacyScope }
            .compactMap { credential(scopeKey: $0.0, entry: $0.1) }
            .filter { isSessionMode($0.authMode) }
        if let best = preferred(otherSessions, now: now) {
            return .credential(best)
        }

        let modes = entries.compactMap { credential(scopeKey: $0.0, entry: $0.1)?.authMode }
        if modes.contains(where: { $0 == "web_login" || $0 == "grok" }) && oidc.isEmpty {
            return .noUsableSession(
                "The saved grok session is a legacy web login, which cannot call billing. \(loginInstructions)"
            )
        }
        if entries.contains(where: { $0.0 == apiKeyScope }) {
            return .noUsableSession(
                "Found an API key in the grok auth file. SuperGrok usage needs a `grok login` session. \(loginInstructions)"
            )
        }
        return .noUsableSession("No usable grok session in the auth file. \(loginInstructions)")
    }

    /// Rewrites one scope entry's token fields and preserves every other key.
    /// Returns nil when the document or the scope entry is missing.
    static func updatedDocument(
        data: Data,
        scopeKey: String,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        createTime: Date
    ) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entry = root[scopeKey] as? [String: Any] else {
            return nil
        }
        entry["key"] = accessToken
        if let refreshToken, !refreshToken.isEmpty {
            entry["refresh_token"] = refreshToken
        }
        if let expiresAt {
            entry["expires_at"] = DateParsing.formatISO8601(expiresAt)
        }
        entry["create_time"] = DateParsing.formatISO8601(createTime)
        root[scopeKey] = entry
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func writeAtomically(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = url.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: temporary)
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try fileManager.replaceItemAt(url, withItemAt: temporary, options: [.usingNewMetadataOnly])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func preferred(_ credentials: [GrokSessionCredential], now: Date) -> GrokSessionCredential? {
        let usable = credentials.filter { !$0.accessToken.isEmpty }
        let fresh = usable.filter { !$0.isExpired(at: now) }
        return (fresh.isEmpty ? usable : fresh).max { lhs, rhs in
            let left = lhs.expiresAt ?? lhs.createTime ?? .distantPast
            let right = rhs.expiresAt ?? rhs.createTime ?? .distantPast
            return left < right
        }
    }

    private static func isSessionMode(_ mode: String) -> Bool {
        switch mode {
        case "oidc", "external":
            return true
        case "api_key", "web_login", "grok":
            return false
        default:
            // Unknown future modes: accept only if they are not the known rejects.
            return true
        }
    }

    private static func credential(scopeKey: String, entry: [String: Any]) -> GrokSessionCredential? {
        guard let key = entry["key"] as? String else { return nil }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        let mode = (entry["auth_mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GrokSessionCredential(
            scopeKey: scopeKey,
            accessToken: trimmedKey,
            refreshToken: nonEmpty(entry["refresh_token"] as? String),
            expiresAt: (entry["expires_at"] as? String).flatMap(DateParsing.parseISO8601),
            createTime: (entry["create_time"] as? String).flatMap(DateParsing.parseISO8601),
            userId: (entry["user_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            email: nonEmpty(entry["email"] as? String),
            authMode: mode?.isEmpty == false ? mode! : "oidc",
            oidcIssuer: nonEmpty(entry["oidc_issuer"] as? String),
            oidcClientId: nonEmpty(entry["oidc_client_id"] as? String)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum SecretRedaction {
    /// Replaces any secret of at least 8 characters. Short values are left
    /// alone so we don't blank ordinary words that happen to match.
    static func redacting(_ message: String, secrets: [String]) -> String {
        var result = message
        for secret in secrets where secret.count >= 8 {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return result
    }
}
