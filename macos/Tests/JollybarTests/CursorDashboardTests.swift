import XCTest
@testable import Jollybar

final class CursorDashboardTests: XCTestCase {
    private let futureToken = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJleHAiOjIwMDAwMDAwMDB9.sig"
    private let ciphertext = "djEwL67V3CvIiaYXP5W66bnUrUE+a0pyL1WdR3mofQ91Hwd10tKmT3oMURr3iOSST9FV"

    func testDerivedKeyAndV10DecryptMatchTheGrokBotMeterVector() throws {
        let key = try XCTUnwrap(GrokBotSafeStorage.deriveKey(password: "test-safe-storage-secret"))
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "e01577979ecb9089bdc67fd397069f52")
        let plain = try XCTUnwrap(GrokBotSafeStorage.decrypt(base64: ciphertext, key: key))
        XCTAssertEqual(plain, "header.payload.signature-token-ok")
    }

    func testPlaintextAccessNeverCallsDecrypt() {
        var calls = 0
        let loaded = GrokBotSession.loadAccess(urls: [], decrypt: { _ in
            calls += 1
            return nil
        })
        XCTAssertEqual(calls, 0)
        XCTAssertNil(loaded.access)

        let token = GrokBotSession.unwrap("plaintext:v1:\(futureToken)") { _ in
            calls += 1
            return nil
        }
        XCTAssertEqual(token, futureToken)
        XCTAssertEqual(calls, 0)
    }

    func testRefreshTokenIsNotDecryptedOrReturned() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sand-secrets.json")
        let body: [String: Any] = [
            "cursor-refresh-token": "scoped:v1:should-not-decrypt",
            "cursor-accounts": [
                "active": "acc",
                "accounts": [
                    "acc": ["cursor-access-token": "plaintext:v1:\(futureToken)"]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        var decrypted: [String] = []
        let loaded = GrokBotSession.loadAccess(urls: [url]) { ciphertext in
            decrypted.append(ciphertext)
            return nil
        }
        XCTAssertEqual(loaded.access, futureToken)
        XCTAssertTrue(decrypted.isEmpty)
        XCTAssertFalse(GrokBotToken.isExpired(futureToken, now: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    func testScopedCiphertextUsesOnlyTheLastSegment() throws {
        let key = try XCTUnwrap(GrokBotSafeStorage.deriveKey(password: "test-safe-storage-secret"))
        let token = GrokBotSession.unwrap("scoped:v1:mac:\(ciphertext)") { value in
            XCTAssertEqual(value, ciphertext)
            return GrokBotSafeStorage.decrypt(base64: value, key: key)
        }
        XCTAssertEqual(token, "header.payload.signature-token-ok")
    }

    func testExpiredTokenIsDetectedWithoutARefresh() {
        let expired = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJleHAiOjEwMDB9.sig"
        XCTAssertTrue(GrokBotToken.isExpired(expired, now: Date()))
        XCTAssertFalse(GrokBotToken.isExpired(futureToken, now: Date()))
    }

    func testSandAndPeriodParsers() throws {
        let sand = """
        {"usagePercent":8,"includedLimitZero":false,"hasAvailableUsage":true,
         "currentPeriodStart":"2026-09-29T00:00:00Z","nextResetTimestampUtc":"2026-10-06T00:00:00Z"}
        """
        let parsed = CursorDashboardParser.parseSand(Data(sand.utf8))
        XCTAssertEqual(parsed.percent, 8 as Double?)
        XCTAssertFalse(parsed.includedLimitZero)
        XCTAssertEqual(parsed.hasAvailableUsage, true as Bool?)
        XCTAssertNotNil(parsed.resetsAt)
        XCTAssertNil(parsed.reason)

        let period = """
        {"planUsage":{"autoPercentUsed":7,"apiPercentUsed":0,"totalPercentUsed":7},
         "spendLimitUsage":{"individualUsed":150,"individualLimit":2000},
         "billingCycleEnd":"2026-10-20T00:00:00Z"}
        """
        let usage = try XCTUnwrap(CursorDashboardParser.parsePeriod(Data(period.utf8)))
        XCTAssertEqual(usage.cursorModelsPercent, 7 as Double?)
        XCTAssertEqual(usage.otherModelsPercent, 0 as Double?)
        XCTAssertEqual(usage.onDemand?.usedCents, 150 as Int64?)
        XCTAssertEqual(usage.onDemand?.limitCents, 2000 as Int64?)
        XCTAssertNil(usage.cursorModelsReason)

        let nested = """
        {"individualUsage":{"plan":{"auto_percent_used":"12","api_percent_used":3}}}
        """
        let nestedUsage = try XCTUnwrap(CursorDashboardParser.parsePeriod(Data(nested.utf8)))
        XCTAssertEqual(nestedUsage.cursorModelsPercent, 12 as Double?)
        XCTAssertEqual(nestedUsage.otherModelsPercent, 3 as Double?)
        XCTAssertNil(nestedUsage.onDemand)

        let unlimited = """
        {"planUsage":{"autoPercentUsed":4,"apiPercentUsed":1},
         "spendLimitUsage":{"individualUsed":10,"individualLimit":2147483647}}
        """
        let noCap = try XCTUnwrap(CursorDashboardParser.parsePeriod(Data(unlimited.utf8)))
        XCTAssertEqual(noCap.cursorModelsPercent, 4 as Double?)
        XCTAssertNil(noCap.onDemand)

        let email = try XCTUnwrap(CursorDashboardParser.parseEmail(Data(#"{"user":{"email":"person@example.com"}}"#.utf8)))
        XCTAssertEqual(email, "person@example.com")
    }

    func testDashboardURLKeepsTheMethodPath() throws {
        let url = try XCTUnwrap(
            CursorDashboardParser.dashboardURL(
                base: URL(string: "https://api2.cursor.sh")!,
                method: "GetSandUsageStatus"
            )
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
        )
    }

    func testCompanionMoodTracksWeeklyUsage() {
        XCTAssertEqual(CompanionMood.resolve(usedPercent: 8, pausedAtLimit: false), .playful)
        XCTAssertEqual(CompanionMood.resolve(usedPercent: 50, pausedAtLimit: false), .steady)
        XCTAssertEqual(CompanionMood.resolve(usedPercent: 75, pausedAtLimit: false), .tired)
        XCTAssertEqual(CompanionMood.resolve(usedPercent: 90, pausedAtLimit: false), .worried)
        XCTAssertEqual(CompanionMood.resolve(usedPercent: 100, pausedAtLimit: false), .asleep)
        XCTAssertEqual(CompanionMood.resolve(usedPercent: 8, pausedAtLimit: true), .asleep)
        XCTAssertEqual(CompanionMood.resolve(usedPercent: nil, pausedAtLimit: false), .unknown)
    }

    func testEachMoodsMouthMatchesItsLabel() {
        XCTAssertEqual(CompanionMood.playful.mouth, .smile)
        XCTAssertEqual(CompanionMood.steady.mouth, .softSmile)
        XCTAssertEqual(CompanionMood.tired.mouth, .flat)
        XCTAssertEqual(CompanionMood.worried.mouth, .frown)
        XCTAssertEqual(CompanionMood.asleep.mouth, .flat)
        XCTAssertEqual(CompanionMood.playful.accessibilityLabel, "Bud, Energetic")
        XCTAssertGreaterThan(MouthCurve.smile.depth, 0.5)
        XCTAssertGreaterThan(MouthCurve.softSmile.depth, 0.5)
        XCTAssertEqual(MouthCurve.flat.depth, 0.5)
        XCTAssertLessThan(MouthCurve.frown.depth, 0.5)
    }

    func testChartOmitsWeeklyWhenThereIsNoPoolAndDrawsTheFirstSamples() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let point = UsageDataPoint(
            timestamp: now,
            pctWeekly: 0,
            pctBot: 0.10,
            includesWeekly: true,
            pctCursorModels: 0.11
        )
        let hidden = UsageChartSeries.displayPoints(from: [point], includeWeekly: false, domain: 86_400)
        let names = UsageChartSeries.orderedNames(in: hidden)
        XCTAssertEqual(names, ["Grok Bot", "Cursor Models"])
        XCTAssertFalse(hidden.contains { $0.series == "Weekly" })
        XCTAssertEqual(hidden.filter { $0.series == "Grok Bot" && !$0.synthesized }.map(\.percent), [10])
        XCTAssertEqual(hidden.filter { $0.series == "Cursor Models" && !$0.synthesized }.map(\.percent), [11])
        XCTAssertEqual(hidden.filter { $0.series == "Grok Bot" }.count, 2)

        let shown = UsageChartSeries.displayPoints(from: [point], includeWeekly: true, domain: 86_400)
        XCTAssertTrue(shown.contains { $0.series == "Weekly" && !$0.synthesized && $0.percent == 0 })
    }
}
