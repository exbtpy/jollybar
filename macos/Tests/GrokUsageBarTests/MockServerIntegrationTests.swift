import XCTest
@testable import GrokUsageBar

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

    func testOmittedPercentOnAWeeklyWindowShowsZero() async throws {
        let harness = try makeHarness()
        try await setScenario("omitted_zero")
        await harness.service.fetchUsage()

        XCTAssertNil(harness.service.lastError)
        XCTAssertEqual(harness.service.reading?.usedPercent, 0.0 as Double?)
        XCTAssertEqual(harness.service.reading?.assumedZero, true as Bool?)
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

    private func setScenario(_ name: String) async throws {
        try await XCTUnwrap(server).setScenario(name)
    }

    private struct Harness {
        let service: UsageService
        let history: UsageHistoryService
        let authURL: URL
    }

    private func makeHarness(
        writeAuth: Bool = true,
        token: String = "test-access-token",
        refresh: String? = "test-refresh-token",
        issuer: String? = nil
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

        let suite = "GrokUsageBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let history = UsageHistoryService(historyFileURL: directory.appendingPathComponent("history.json"))
        let service = UsageService(
            session: URLSession(configuration: .ephemeral),
            proxyBaseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            managementBaseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            authFileURL: authURL,
            secretStore: MemorySecretStore(),
            defaults: defaults
        )
        service.historyService = history
        return Harness(service: service, history: history, authURL: authURL)
    }
}

private struct MockServerLaunchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class MockServer {
    let port: Int
    private let process: Process

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private init(port: Int, process: Process) {
        self.port = port
        self.process = process
    }

    static func start() throws -> MockServer {
        let script = repositoryRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("mock-server.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("mock-server.py not found at \(script.path)")
        }

        let portFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-mock-port-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: portFile) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.arguments = [
            "python3", "-u", script.path,
            "--port", "0",
            "--port-file", portFile.path
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw MockServerLaunchError("Could not launch python3: \(error.localizedDescription)")
        }
        guard let port = waitForPort(portFile: portFile, process: process) else {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
            let stdout = collectedOutput(output)
            let stderr = collectedOutput(errors)
            throw MockServerLaunchError(
                """
                Mock server did not report a port.
                stdout: \(stdout)
                stderr: \(stderr)
                """
            )
        }
        return MockServer(port: port, process: process)
    }

    /// The server writes the bound port to a file. Polling that file avoids
    /// racing a pipe that never delivered the banner on the macOS runner.
    private static func waitForPort(portFile: URL, process: Process) -> Int? {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let text = try? String(contentsOf: portFile, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let port = Int(trimmed), port > 0 {
                    return port
                }
            }
            if !process.isRunning {
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private static func collectedOutput(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.availableData
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "<empty>" : text
    }

    func setScenario(_ name: String) async throws {
        let url = baseURL.appendingPathComponent("scenario").appendingPathComponent(name)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode
        XCTAssertEqual(status, 200, "Unknown mock scenario '\(name)'")
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    /// `#filePath` is `<repo>/macos/Tests/GrokUsageBarTests/<file>.swift`.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
