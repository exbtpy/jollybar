import XCTest
@testable import GrokUsageBar

final class GrokAuthFileTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPrefersOidcScopeOverLegacy() throws {
        let legacy = entry(token: "legacy-token-value", mode: "oidc")
        let oidc = entry(token: "oidc-token-value", mode: "oidc", expiresAt: now.addingTimeInterval(3600))
        let result = GrokAuthFile.load(from: document([
            GrokAuthFile.legacyScope: legacy,
            "https://auth.x.ai::client-1": oidc
        ]), now: now)
        guard case .credential(let credential) = result else {
            return XCTFail("expected a credential, got \(result)")
        }
        XCTAssertEqual(credential.scopeKey, "https://auth.x.ai::client-1")
        XCTAssertEqual(credential.email, "person@example.com" as String?)
        XCTAssertFalse(String(describing: credential).contains("oidc-token-value"))
    }

    func testFallsBackToLegacyScope() throws {
        let result = GrokAuthFile.load(from: document([
            GrokAuthFile.legacyScope: entry(token: "legacy-token-value", mode: "external")
        ]), now: now)
        guard case .credential(let credential) = result else {
            return XCTFail("expected a credential")
        }
        XCTAssertEqual(credential.scopeKey, GrokAuthFile.legacyScope)
        XCTAssertEqual(credential.authMode, "external")
    }

    func testApiKeyAloneIsNotASession() throws {
        let result = GrokAuthFile.load(from: document([
            GrokAuthFile.apiKeyScope: entry(token: "xai-management-key-value", mode: "api_key")
        ]), now: now)
        guard case .noUsableSession(let message) = result else {
            return XCTFail("expected no usable session")
        }
        XCTAssertTrue(message.contains("grok login"))
        XCTAssertFalse(message.contains("xai-management-key-value"))
    }

    func testLegacyWebLoginIsRejected() throws {
        let result = GrokAuthFile.load(from: document([
            GrokAuthFile.legacyScope: entry(token: "web-login-token-value", mode: "grok")
        ]), now: now)
        guard case .noUsableSession(let message) = result else {
            return XCTFail("expected no usable session")
        }
        XCTAssertTrue(message.contains("web login"))
        XCTAssertFalse(message.contains("web-login-token-value"))
    }

    func testMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(GrokAuthFile.load(url: url), .missingFile)
    }

    func testClientIDAndIssuerFallbacks() {
        let credential = GrokSessionCredential(
            scopeKey: "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828",
            accessToken: "access-token-value",
            refreshToken: "refresh-token-value",
            expiresAt: nil,
            createTime: nil,
            userId: "u",
            email: nil,
            authMode: "oidc",
            oidcIssuer: nil,
            oidcClientId: nil
        )
        XCTAssertEqual(credential.resolvedClientID, "b1a00492-073a-47ea-816f-4c329264a828")
        XCTAssertEqual(credential.resolvedIssuer?.absoluteString, "https://auth.x.ai" as String?)
        XCTAssertFalse(credential.isExpired(at: now))
    }

    func testExpiryUsesExpiresAtAndThirtyDayFallback() {
        let expiring = GrokSessionCredential(
            scopeKey: "scope",
            accessToken: "access-token-value",
            refreshToken: "refresh-token-value",
            expiresAt: now.addingTimeInterval(60),
            createTime: now,
            userId: "",
            email: nil,
            authMode: "oidc",
            oidcIssuer: "https://auth.x.ai",
            oidcClientId: "client"
        )
        XCTAssertTrue(expiring.needsRefresh(at: now))
        XCTAssertFalse(expiring.isExpired(at: now))

        let aged = GrokSessionCredential(
            scopeKey: "scope",
            accessToken: "access-token-value",
            refreshToken: nil,
            expiresAt: nil,
            createTime: now.addingTimeInterval(-(GrokAuthFile.tokenTTL + 10)),
            userId: "",
            email: nil,
            authMode: "oidc",
            oidcIssuer: nil,
            oidcClientId: nil
        )
        XCTAssertTrue(aged.isExpired(at: now))
        XCTAssertFalse(aged.needsRefresh(at: now))
    }

    func testUpdatedDocumentPreservesUnknownFields() throws {
        let data = document([
            "https://auth.x.ai::client": entry(token: "old-access-token", mode: "oidc")
        ])
        let updated = try XCTUnwrap(GrokAuthFile.updatedDocument(
            data: data,
            scopeKey: "https://auth.x.ai::client",
            accessToken: "new-access-token",
            refreshToken: "new-refresh-token",
            expiresAt: now,
            createTime: now
        ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let entry = try XCTUnwrap(root["https://auth.x.ai::client"] as? [String: Any])
        XCTAssertEqual(entry["key"] as? String, "new-access-token" as String?)
        XCTAssertEqual(entry["refresh_token"] as? String, "new-refresh-token" as String?)
        XCTAssertEqual(entry["email"] as? String, "person@example.com" as String?)
        XCTAssertEqual(entry["custom_flag"] as? Bool, true as Bool?)
    }

    func testRedactionRemovesLongSecrets() {
        let message = "bad super-secret-token-value"
        XCTAssertEqual(
            SecretRedaction.redacting(message, secrets: ["super-secret-token-value"]),
            "bad [redacted]"
        )
    }

    func testLoopbackOverrideAndAuthPath() {
        XCTAssertEqual(
            EndpointOverride.resolvedURL(
                environment: [EndpointOverride.proxyKey: "http://127.0.0.1:9/v1"],
                key: EndpointOverride.proxyKey,
                defaultURL: EndpointOverride.defaultProxyBase
            ).absoluteString,
            "http://127.0.0.1:9/v1"
        )
        XCTAssertEqual(
            EndpointOverride.resolvedURL(
                environment: [EndpointOverride.proxyKey: "https://evil.example/v1"],
                key: EndpointOverride.proxyKey,
                defaultURL: EndpointOverride.defaultProxyBase
            ),
            EndpointOverride.defaultProxyBase
        )
        XCTAssertFalse(EndpointOverride.allowsRefreshIssuer(URL(string: "http://evil.example/token")!))
        XCTAssertTrue(EndpointOverride.allowsRefreshIssuer(URL(string: "https://auth.x.ai")!))
        XCTAssertTrue(EndpointOverride.allowsRefreshIssuer(URL(string: "http://127.0.0.1:9/oidc")!))

        let path = EndpointOverride.authFileURL(environment: [
            EndpointOverride.authFileKey: "~/Library/grok-auth.json"
        ])
        XCTAssertTrue(path.path.hasSuffix("Library/grok-auth.json"))
        XCTAssertFalse(path.path.contains("~"))
    }

    func testUpstreamFeedIsRejected() {
        XCTAssertFalse(AppUpdater.isUsableUpdateFeed("https://blimp-labs.github.io/claude-usage-bar/appcast.xml"))
        XCTAssertFalse(AppUpdater.isUsableUpdateFeed("https://example.com/claude-usage-bar/appcast.xml"))
        XCTAssertFalse(AppUpdater.isUsableUpdateFeed(nil))
        XCTAssertFalse(AppUpdater.isUsableUpdateFeed("http://example.com/appcast.xml"))
        XCTAssertTrue(AppUpdater.isUsableUpdateFeed("https://example.com/grok-usage-bar/appcast.xml"))
    }

    private func entry(token: String, mode: String, expiresAt: Date? = nil) -> [String: Any] {
        var entry: [String: Any] = [
            "key": token,
            "auth_mode": mode,
            "create_time": "2026-09-01T00:00:00Z",
            "user_id": "user-1",
            "email": "person@example.com",
            "custom_flag": true
        ]
        if let expiresAt {
            entry["expires_at"] = DateParsing.formatISO8601(expiresAt)
        }
        return entry
    }

    private func document(_ entries: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: entries)
    }
}
