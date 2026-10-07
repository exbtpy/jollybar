import Darwin
import XCTest
@testable import Jollybar

/// End-to-end tests against `scripts/mock-server.py`.
@MainActor
final class MockServerIntegrationTests: XCTestCase {
    private var server: MockServer?

    override func setUp() async throws {
        try await super.setUp()
        server = try MockServer.start()
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        try await super.tearDown()
    }

    func testNormalScenarioReadsWeeklyPoolProductsAndCredits() async throws {
        let harness = try makeHarness()
        await harness.service.fetchUsage()

        XCTAssertNil(harness.service.lastError)
        XCTAssertTrue(harness.service.isAuthenticated)
        XCTAssertEqual(harness.service.accountEmail, "person@example.com" as String?)
        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)
        XCTAssertEqual(
            harness.service.reading?.products.map(\.displayName),
            ["Grok Build", "Grok Chat", "Imagine"] as [String]?
        )
        XCTAssertEqual(harness.service.reading?.extraCreditsCents, 1250 as Int64?)
        XCTAssertNotNil(harness.service.reading?.resetsAt)
        XCTAssertEqual(harness.service.weeklyFraction ?? -1, 0.42, accuracy: 0.001)
        XCTAssertEqual(harness.history.history.dataPoints.count, 1)
        XCTAssertEqual(harness.history.history.dataPoints.first?.pctWeekly ?? -1, 0.42, accuracy: 0.001)
    }

    func testOmittedPercentOnAWeeklyWindowIsNotAPool() async throws {
        let harness = try makeHarness()
        try await setScenario("omitted_zero")
        await harness.service.fetchUsage()

        XCTAssertNil(harness.service.lastError)
        XCTAssertNil(harness.service.reading?.usedPercent)
        XCTAssertEqual(harness.service.reading?.hasWeeklyPool, false as Bool?)
        XCTAssertNil(harness.service.weeklyFraction)
        XCTAssertEqual(harness.service.bottomLabel, "CM")
    }

    func testProductBreakdownWithoutOverallDoesNotInventAPercent() async throws {
        let harness = try makeHarness()
        try await setScenario("products_without_overall")
        await harness.service.fetchUsage()

        XCTAssertNil(harness.service.reading?.usedPercent)
        XCTAssertEqual(harness.service.reading?.products.first?.displayName, "Grok Build" as String?)
        XCTAssertTrue(harness.service.lastError?.contains("creditUsagePercent") == true)
        XCTAssertTrue(harness.history.history.dataPoints.isEmpty)
    }

    func testStringCentsAreParsed() async throws {
        let harness = try makeHarness()
        try await setScenario("string_cents")
        await harness.service.fetchUsage()
        XCTAssertEqual(harness.service.reading?.extraCreditsCents, 2500 as Int64?)
        XCTAssertEqual(harness.service.reading?.onDemandCapCents, 500 as Int64?)
        XCTAssertEqual(harness.service.reading?.usedPercent, 15.0 as Double?)
    }

    func testMissingAuthFileAsksForGrokLogin() async throws {
        let harness = try makeHarness(writeAuth: false)
        await harness.service.fetchUsage()
        XCTAssertFalse(harness.service.isAuthenticated)
        XCTAssertNil(harness.service.reading)
        XCTAssertTrue(harness.service.lastError?.contains("grok login") == true)
    }

    func testUnauthorizedResponseDoesNotDeleteTheAuthFile() async throws {
        let harness = try makeHarness(token: "super-secret-token-value", refresh: nil)
        try await setScenario("unauthenticated")
        await harness.service.fetchUsage()

        XCTAssertFalse(harness.service.isAuthenticated)
        XCTAssertTrue(harness.service.lastError?.contains("grok login") == true)
        XCTAssertFalse(harness.service.lastError?.contains("super-secret-token-value") == true)
        let saved = try Data(contentsOf: harness.authURL)
        let text = String(decoding: saved, as: UTF8.self)
        XCTAssertTrue(text.contains("super-secret-token-value"))
    }

    func testStaleTokenRefreshesOnceAndRetries() async throws {
        let server = try XCTUnwrap(self.server)
        let harness = try makeHarness(
            token: "super-secret-token-value",
            refresh: "super-secret-refresh-value",
            issuer: "http://127.0.0.1:\(server.port)/oidc"
        )
        try await setScenario("stale_then_ok")
        await harness.service.fetchUsage()

        XCTAssertNil(harness.service.lastError, harness.service.lastError ?? "")
        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)
        XCTAssertFalse(harness.service.lastError?.contains("super-secret-token-value") == true)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: harness.authURL)) as? [String: Any]
        let entry = saved?["https://auth.x.ai::test-client"] as? [String: Any]
        XCTAssertEqual(entry?["key"] as? String, "refreshed-access" as String?)
        XCTAssertEqual(entry?["refresh_token"] as? String, "refreshed-refresh" as String?)
        XCTAssertEqual(entry?["email"] as? String, "person@example.com" as String?)
    }

    func testServerErrorRedactsABodyThatEchoesTheToken() async throws {
        let harness = try makeHarness(token: "super-secret-token-value")
        try await setScenario("echo_auth")
        await harness.service.fetchUsage()

        XCTAssertTrue(harness.service.isAuthenticated)
        XCTAssertTrue(harness.service.lastError?.contains("HTTP 500") == true)
        XCTAssertFalse(harness.service.lastError?.contains("super-secret-token-value") == true)
    }

    func testRateLimitBacksOffWithoutCrashing() async throws {
        let harness = try makeHarness()
        try await setScenario("rate_limited")
        await harness.service.fetchUsage()
        XCTAssertTrue(harness.service.lastError?.contains("Rate limited") == true)
        XCTAssertTrue(harness.service.isAuthenticated)
    }

    func testManagementAPIIsOptionalAndSeparate() async throws {
        let harness = try makeHarness()
        harness.service.saveManagementSettings(teamID: "team-1", key: "management-key-value")
        await harness.service.fetchUsage()

        XCTAssertEqual(harness.service.management?.prepaidTotalCents, -1000 as Int64?)
        XCTAssertEqual(harness.service.management?.spend7dUSD ?? -1, 1.5, accuracy: 0.001)
        XCTAssertNil(harness.service.managementError)
        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)
        XCTAssertFalse(harness.service.lastError?.contains("management-key-value") == true)
    }

    func testSwitchingScenariosUpdatesTheWeeklyPercent() async throws {
        let harness = try makeHarness()
        await harness.service.fetchUsage()
        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)

        try await setScenario("high")
        await harness.service.fetchUsage()
        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 92, accuracy: 0.001)
        XCTAssertEqual(harness.history.history.dataPoints.count, 2)
    }

    func testCursorGrokBotIsFivePercentAndWeeklyStays() async throws {
        let harness = try makeHarness()
        harness.service.saveCursorSettings(
            apiKey: "crsr_test_key_123456",
            email: "person@example.com",
            organizationID: "",
            budget: ""
        )
        await harness.service.fetchUsage(refreshCursor: true)

        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(harness.service.cursorReading?.usedPercent), 5, accuracy: 0.01)
        XCTAssertEqual(harness.service.cursorReading?.limitSource, "spend limit" as String?)
        XCTAssertEqual(harness.service.botFraction ?? -1, 0.05, accuracy: 0.001)
        XCTAssertEqual(harness.service.weeklyFraction ?? -1, 0.42, accuracy: 0.001)
        XCTAssertNil(harness.service.cursorError)
        let point = try XCTUnwrap(harness.history.history.dataPoints.first)
        XCTAssertEqual(try XCTUnwrap(point.pctBot), 0.05, accuracy: 0.001)
        XCTAssertTrue(point.includesWeekly)
        let detail = harness.service.cursorReading?.amountDetail ?? ""
        XCTAssertFalse(detail.contains("crsr_"))
        XCTAssertTrue(harness.service.cursorReading?.resetIsAssumedMonthly == true)
    }

    func testSandSessionIsTheGrokBotWeeklyMeter() async throws {
        let harness = try makeHarness(sandAccess: Self.futureAccessToken)
        await harness.service.fetchUsage(refreshCursor: true)

        XCTAssertEqual(try XCTUnwrap(harness.service.dashboardReading?.grokBotPercent), 8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(harness.service.dashboardReading?.cursorModelsPercent), 7, accuracy: 0.001)
        XCTAssertEqual(harness.service.dashboardReading?.otherModelsPercent, 0 as Double?)
        XCTAssertEqual(harness.service.dashboardReading?.onDemand?.usedCents, 150 as Int64?)
        XCTAssertEqual(harness.service.dashboardReading?.onDemand?.limitCents, 2000 as Int64?)
        XCTAssertEqual(harness.service.dashboardReading?.accountEmail, "grokbot-user@example.com" as String?)
        XCTAssertEqual(harness.service.topLabel, "GB")
        XCTAssertEqual(harness.service.bottomLabel, "Wk")
        XCTAssertEqual(harness.service.botFraction ?? -1, 0.08, accuracy: 0.001)
        XCTAssertEqual(harness.service.weeklyFraction ?? -1, 0.42, accuracy: 0.001)
        XCTAssertNil(harness.service.cursorReading)
        let point = try XCTUnwrap(harness.history.history.dataPoints.first)
        XCTAssertEqual(try XCTUnwrap(point.pctBot), 0.08, accuracy: 0.001)
        XCTAssertTrue(point.includesWeekly)
        XCTAssertNil(point.pctCursorModels)
    }

    func testNoSuperGrokPoolUsesCursorModelsOnTheBottomSlot() async throws {
        let harness = try makeHarness(sandAccess: Self.futureAccessToken)
        try await setScenario("omitted_zero")
        await harness.service.fetchUsage()

        XCTAssertEqual(harness.service.reading?.hasWeeklyPool, false as Bool?)
        XCTAssertNil(harness.service.weeklyFraction)
        XCTAssertEqual(harness.service.bottomLabel, "CM")
        XCTAssertEqual(harness.service.bottomFraction ?? -1, 0.07, accuracy: 0.001)
        XCTAssertEqual(harness.service.botFraction ?? -1, 0.08, accuracy: 0.001)
        let point = try XCTUnwrap(harness.history.history.dataPoints.first)
        XCTAssertFalse(point.includesWeekly)
        XCTAssertEqual(try XCTUnwrap(point.pctCursorModels), 0.07, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(point.pctBot), 0.08, accuracy: 0.001)
    }

    func testSandUnauthorizedDoesNotClearTheWeeklyPoolOrUseTheAdminKey() async throws {
        let harness = try makeHarness(sandAccess: Self.futureAccessToken)
        await harness.service.fetchUsage()
        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)

        try await setScenario("sand_unauthorized")
        harness.service.saveCursorSettings(
            apiKey: "crsr_test_key_123456",
            email: "person@example.com",
            organizationID: "",
            budget: "40"
        )
        await harness.service.fetchUsage(refreshCursor: true)

        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)
        XCTAssertNil(harness.service.dashboardReading)
        XCTAssertEqual(harness.service.dashboardError, GrokBotSessionNotice.openGrokBot)
        XCTAssertNil(harness.service.cursorReading)
        XCTAssertTrue(harness.service.sandOwnsTopSlot)
    }

    func testExpiredSandTokenAsksToOpenGrokBot() async throws {
        let harness = try makeHarness(sandAccess: Self.expiredAccessToken)
        await harness.service.fetchUsage()

        XCTAssertEqual(harness.service.dashboardError, GrokBotSessionNotice.openGrokBot)
        XCTAssertNil(harness.service.dashboardReading?.grokBotPercent)
        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)
    }

    func testCursorUnauthorizedDoesNotClearTheWeeklyPool() async throws {
        let harness = try makeHarness()
        await harness.service.fetchUsage()
        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)

        try await setScenario("cursor_unauthorized")
        harness.service.saveCursorSettings(
            apiKey: "crsr_test_key_123456",
            email: "person@example.com",
            organizationID: "",
            budget: "40"
        )
        await harness.service.fetchUsage(refreshCursor: true)

        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)
        XCTAssertNil(harness.service.cursorReading)
        XCTAssertTrue(harness.service.cursorError?.contains("401") == true)
        XCTAssertFalse(harness.service.cursorError?.contains("crsr_") == true)
    }

    func testCursorForbiddenNamesThePlanRequirement() async throws {
        let harness = try makeHarness()
        try await setScenario("cursor_forbidden")
        harness.service.saveCursorSettings(
            apiKey: "crsr_test_key_123456",
            email: "person@example.com",
            organizationID: "",
            budget: ""
        )
        await harness.service.fetchUsage(refreshCursor: true)

        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)
        XCTAssertNil(harness.service.cursorReading)
        XCTAssertTrue(harness.service.cursorError?.contains("403") == true)
        XCTAssertTrue(harness.service.cursorError?.contains("Teams") == true)
    }

    func testCursorEventsWithoutApplicationTypeAreNotGrokBot() async throws {
        let harness = try makeHarness()
        try await setScenario("cursor_no_type")
        harness.service.saveCursorSettings(
            apiKey: "crsr_test_key_123456",
            email: "person@example.com",
            organizationID: "",
            budget: "50"
        )
        await harness.service.fetchUsage(refreshCursor: true)

        XCTAssertNil(harness.service.cursorReading?.usedPercent)
        XCTAssertNil(harness.service.cursorReading?.usedCents)
        XCTAssertTrue(harness.service.cursorError?.contains("application_type") == true)
        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)
        let point = try XCTUnwrap(harness.history.history.dataPoints.first)
        XCTAssertNil(point.pctBot)
        XCTAssertTrue(point.includesWeekly)
    }

    func testCursorRateLimitKeepsTheLastBotReading() async throws {
        let harness = try makeHarness()
        harness.service.saveCursorSettings(
            apiKey: "crsr_test_key_123456",
            email: "person@example.com",
            organizationID: "",
            budget: ""
        )
        await harness.service.fetchUsage(refreshCursor: true)
        XCTAssertEqual(try XCTUnwrap(harness.service.cursorReading?.usedPercent), 5, accuracy: 0.01)

        try await setScenario("cursor_rate_limited")
        await harness.service.fetchUsage(refreshCursor: true)

        XCTAssertEqual(try XCTUnwrap(harness.service.cursorReading?.usedPercent), 5, accuracy: 0.01)
        XCTAssertTrue(harness.service.cursorError?.localizedCaseInsensitiveContains("rate") == true)
        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)
    }

    func testCursorNotModifiedKeepsTheReading() async throws {
        let harness = try makeHarness()
        harness.service.saveCursorSettings(
            apiKey: "crsr_test_key_123456",
            email: "person@example.com",
            organizationID: "",
            budget: ""
        )
        await harness.service.fetchUsage(refreshCursor: true)
        XCTAssertEqual(try XCTUnwrap(harness.service.cursorReading?.usedPercent), 5, accuracy: 0.01)

        await harness.service.fetchUsage(refreshCursor: true)
        XCTAssertEqual(try XCTUnwrap(harness.service.cursorReading?.usedPercent), 5, accuracy: 0.01)
        XCTAssertNil(harness.service.cursorError)
        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)
    }

    func testMonthlyBudgetIsTheDenominatorWhenEmailIsOmitted() async throws {
        let harness = try makeHarness()
        harness.service.saveCursorSettings(
            apiKey: "crsr_test_key_123456",
            email: "",
            organizationID: "",
            budget: "20"
        )
        await harness.service.fetchUsage(refreshCursor: true)

        XCTAssertEqual(try XCTUnwrap(harness.service.cursorReading?.usedPercent), 12.5, accuracy: 0.01)
        XCTAssertEqual(harness.service.cursorReading?.limitSource, "monthly budget" as String?)
        XCTAssertEqual(try XCTUnwrap(harness.service.reading?.usedPercent), 42, accuracy: 0.001)
    }

    private func setScenario(_ name: String) async throws {
        try await XCTUnwrap(server).setScenario(name)
    }

    private struct Harness {
        let service: UsageService
        let history: UsageHistoryService
        let authURL: URL
    }

    private static let futureAccessToken = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJleHAiOjIwMDAwMDAwMDB9.sig"
    private static let expiredAccessToken = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJleHAiOjEwMDB9.sig"

    private func makeHarness(
        writeAuth: Bool = true,
        token: String = "test-access-token",
        refresh: String? = "test-refresh-token",
        issuer: String? = nil,
        sandAccess: String? = nil
    ) throws -> Harness {
        let server = try XCTUnwrap(self.server)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let authURL = directory.appendingPathComponent("auth.json")
        if writeAuth {
            var entry: [String: Any] = [
                "key": token,
                "auth_mode": "oidc",
                "create_time": "2026-09-01T00:00:00Z",
                "user_id": "user-1",
                "email": "person@example.com",
                "expires_at": "2026-12-01T00:00:00Z",
                "oidc_client_id": "test-client"
            ]
            if let refresh {
                entry["refresh_token"] = refresh
            }
            if let issuer {
                entry["oidc_issuer"] = issuer
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "https://auth.x.ai::test-client": entry
            ])
            try data.write(to: authURL)
        }

        let suite = "JollybarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let secretsURL = directory.appendingPathComponent("sand-secrets.json")
        if let sandAccess {
            let payload = ["cursor-access-token": "plaintext:v1:\(sandAccess)"]
            try JSONSerialization.data(withJSONObject: payload).write(to: secretsURL)
        }

        let history = UsageHistoryService(historyFileURL: directory.appendingPathComponent("history.json"))
        let service = UsageService(
            session: URLSession(configuration: .ephemeral),
            proxyBaseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            managementBaseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            cursorBaseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            dashboardBaseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            sandSecretsURL: secretsURL,
            keyProvider: MissingKeyProvider(),
            authFileURL: authURL,
            secretStore: MemorySecretStore(),
            defaults: defaults
        )
        service.historyService = history
        return Harness(service: service, history: history, authURL: authURL)
    }
}

private final class MissingKeyProvider: GrokBotKeyProviding {
    func derivedKey() -> GrokBotKeyState { .missing }
}

private struct MockServerLaunchError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private final class MockServer {
    let port: Int
    private let process: Process
    private let logHandle: FileHandle
    private let logURL: URL

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private init(port: Int, process: Process, logHandle: FileHandle, logURL: URL) {
        self.port = port
        self.process = process
        self.logHandle = logHandle
        self.logURL = logURL
    }

    static func start() throws -> MockServer {
        let script = repositoryRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("mock-server.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("mock-server.py not found at \(script.path)")
        }
        guard let python = resolvedPython() else {
            throw MockServerLaunchError("python3 was not on PATH. CI should run actions/setup-python before swift test.")
        }

        // Bind a port here so the test does not have to scrape a banner out of
        // a pipe. The previous runner never delivered that banner, and a port
        // file written by Python was not visible before the deadline either.
        let port = try reserveLoopbackPort()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-mock-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.arguments = ["-u", script.path, "--port", String(port)]
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw MockServerLaunchError("Could not launch \(python): \(error.localizedDescription)")
        }

        guard waitUntilAccepting(port: port, process: process) else {
            let status = process.isRunning ? "still running" : "exited \(process.terminationStatus)"
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? logHandle.close()
            let log = (try? String(contentsOf: logURL, encoding: .utf8))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            try? FileManager.default.removeItem(at: logURL)
            throw MockServerLaunchError(
                """
                Mock server did not accept connections on 127.0.0.1:\(port) (\(status)).
                python: \(python)
                log: \(log.isEmpty ? "<empty>" : log)
                """
            )
        }
        return MockServer(port: port, process: process, logHandle: logHandle, logURL: logURL)
    }

    /// First executable `python3` on PATH. An absolute path avoids `/usr/bin/env`
    /// and a Command Line Tools stub that can sit forever without running the script.
    private static func resolvedPython() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("python3").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func reserveLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MockServerLaunchError("socket() failed while reserving a port")
        }
        defer { close(fd) }
        var reuse: Int32 = 1
        let reuseSize = socklen_t(MemoryLayout<Int32>.size)
        _ = withUnsafePointer(to: &reuse) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, pointer, reuseSize)
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        var ipv4 = in_addr()
        _ = inet_pton(AF_INET, "127.0.0.1", &ipv4)
        addr.sin_addr = ipv4
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw MockServerLaunchError("bind() failed while reserving a port")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                getsockname(fd, pointer, &length)
            }
        }
        guard named == 0 else {
            throw MockServerLaunchError("getsockname() failed while reserving a port")
        }
        let port = Int(UInt16(bigEndian: actual.sin_port))
        guard port > 0 else {
            throw MockServerLaunchError("reserved port was 0")
        }
        return port
    }

    private static func waitUntilAccepting(port: Int, process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !process.isRunning {
                return false
            }
            if canConnect(port: port) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        var ipv4 = in_addr()
        _ = inet_pton(AF_INET, "127.0.0.1", &ipv4)
        addr.sin_addr = ipv4
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    func setScenario(_ name: String) async throws {
        let url = baseURL.appendingPathComponent("scenario").appendingPathComponent(name)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode
        XCTAssertEqual(status, 200, "Unknown mock scenario '\(name)'")
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? logHandle.close()
        if FileManager.default.fileExists(atPath: logURL.path) {
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    /// `#filePath` is `<repo>/macos/Tests/JollybarTests/<file>.swift`.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
