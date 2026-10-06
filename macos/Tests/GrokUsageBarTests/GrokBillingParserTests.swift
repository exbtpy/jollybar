import XCTest
@testable import GrokUsageBar

final class GrokBillingParserTests: XCTestCase {
    func testClaudiaCapturedWeeklyShape() throws {
        let json = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
          "start":"2026-08-08T01:53:09.930537+00:00","end":"2026-08-15T01:53:09.930537+00:00"},
          "creditUsagePercent":100.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},
          "productUsage":[{"product":"GrokBuild","usagePercent":100.0},{"product":"GrokChat"}],
          "isUnifiedBillingUser":true,"prepaidBalance":{"val":0},
          "billingPeriodStart":"2026-08-08T01:53:09.930537+00:00",
          "billingPeriodEnd":"2026-08-15T01:53:09.930537+00:00"}}
        """
        let reading = GrokBillingParser.parse(Data(json.utf8))
        XCTAssertEqual(reading.usedPercent, 100.0 as Double?)
        XCTAssertTrue(reading.hasWeeklyPool)
        XCTAssertNil(reading.unavailableReason)
        XCTAssertEqual(reading.products.map(\.displayName), ["Grok Build", "Grok Chat"])
        XCTAssertEqual(reading.products[0].usagePercent, 100.0 as Double?)
        XCTAssertNil(reading.products[1].usagePercent)
        XCTAssertEqual(reading.extraCreditsCents, 0 as Int64?)
        XCTAssertEqual(reading.isUnifiedBillingUser, true as Bool?)
        let reset = try XCTUnwrap(reading.resetsAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(calendar.component(.day, from: reset), 15)
        XCTAssertEqual(calendar.component(.month, from: reset), 8)
    }

    func testOfficialFixtureProductNameAndStringCents() {
        let json = """
        {"config":{
          "creditUsagePercent":42.5,
          "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-01T00:00:00Z","end":"2026-06-08T00:00:00Z"},
          "prepaidBalance":{"val":"1250"},
          "onDemandCap":{"val":"5000"},
          "productUsage":[{"product":"PRODUCT_GROK_BUILD","usagePercent":61.2}]
        }}
        """
        let reading = GrokBillingParser.parse(Data(json.utf8))
        XCTAssertEqual(reading.usedPercent, 42.5 as Double?)
        XCTAssertEqual(reading.extraCreditsCents, 1250 as Int64?)
        XCTAssertEqual(reading.onDemandCapCents, 5000 as Int64?)
        XCTAssertEqual(reading.products.first?.displayName, "Grok Build" as String?)
        XCTAssertEqual(reading.products.first?.usagePercent, 61.2 as Double?)
    }

    func testEmptyCentObjectIsZero() {
        let json = """
        {"config":{"creditUsagePercent":1,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-01T00:00:00Z","end":"2026-06-08T00:00:00Z"},"prepaidBalance":{}}}
        """
        let reading = GrokBillingParser.parse(Data(json.utf8))
        XCTAssertEqual(reading.extraCreditsCents, 0 as Int64?)
    }

    func testOmittedPercentOnConfirmedWeeklyWindowIsNotAPool() {
        let json = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-01T00:00:00Z","end":"2026-06-08T00:00:00Z"},
          "productUsage":[{"product":"GrokChat"}],"prepaidBalance":{"val":0}}}
        """
        let reading = GrokBillingParser.parse(Data(json.utf8))
        XCTAssertNil(reading.usedPercent)
        XCTAssertFalse(reading.hasWeeklyPool)
        XCTAssertNil(reading.unavailableReason)
    }

    func testOwnerCreditsShapeHasNoSuperGrokPool() {
        let json = """
        {"config":{
          "billingPeriodStart":"2026-09-29T00:00:00Z",
          "billingPeriodEnd":"2026-10-06T00:00:00Z",
          "currentPeriod":{"start":"2026-09-29T00:00:00Z","end":"2026-10-06T00:00:00Z","type":"USAGE_PERIOD_TYPE_WEEKLY"},
          "isUnifiedBillingUser":true,
          "onDemandCap":{"val":0},
          "onDemandUsed":{"val":0},
          "prepaidBalance":{"val":0},
          "topUpMethod":"TOP_UP_METHOD_UNSPECIFIED"
        }}
        """
        let reading = GrokBillingParser.parse(Data(json.utf8))
        XCTAssertFalse(reading.hasWeeklyPool)
        XCTAssertNil(reading.usedPercent)
        XCTAssertNil(reading.unavailableReason)
        XCTAssertEqual(reading.extraCreditsCents, 0 as Int64?)
        XCTAssertEqual(reading.onDemandCapCents, 0 as Int64?)
        XCTAssertEqual(reading.isUnifiedBillingUser, true as Bool?)
        XCTAssertNotNil(reading.resetsAt)
    }

    func testExplicitZeroIsARealPool() {
        let json = """
        {"config":{"creditUsagePercent":0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-01T00:00:00Z","end":"2026-06-08T00:00:00Z"}}}
        """
        let reading = GrokBillingParser.parse(Data(json.utf8))
        XCTAssertEqual(reading.usedPercent, 0.0 as Double?)
        XCTAssertTrue(reading.hasWeeklyPool)
        XCTAssertNil(reading.unavailableReason)
    }

    func testProductUsageWithoutOverallDoesNotInventAPercent() {
        let json = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-01T00:00:00Z","end":"2026-06-08T00:00:00Z"},
          "productUsage":[{"product":"PRODUCT_GROK_BUILD","usagePercent":61.2}]}}
        """
        let reading = GrokBillingParser.parse(Data(json.utf8))
        XCTAssertNil(reading.usedPercent)
        XCTAssertTrue(reading.hasWeeklyPool)
        XCTAssertEqual(reading.products.first?.usagePercent, 61.2 as Double?)
        XCTAssertNotNil(reading.unavailableReason)
    }

    func testMonthlyPeriodIsNotTheWeeklyBar() {
        let json = """
        {"config":{"creditUsagePercent":40,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","start":"2026-06-01T00:00:00Z","end":"2026-07-01T00:00:00Z"}}}
        """
        let reading = GrokBillingParser.parse(Data(json.utf8))
        XCTAssertNil(reading.usedPercent)
        XCTAssertFalse(reading.hasWeeklyPool)
        XCTAssertNil(reading.resetsAt)
        XCTAssertTrue(reading.unavailableReason?.contains("USAGE_PERIOD_TYPE_MONTHLY") == true)
    }

    func testMissingConfigIsUnavailable() {
        let reading = GrokBillingParser.parse(Data("{}".utf8))
        XCTAssertNil(reading.usedPercent)
        XCTAssertNotNil(reading.unavailableReason)
    }

    func testNonJSONDoesNotCrash() {
        let reading = GrokBillingParser.parse(Data("nope".utf8))
        XCTAssertNil(reading.usedPercent)
        XCTAssertNotNil(reading.unavailableReason)
    }

    func testNegativePercentIsRejected() {
        let json = """
        {"config":{"creditUsagePercent":-5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-01T00:00:00Z","end":"2026-06-08T00:00:00Z"}}}
        """
        let reading = GrokBillingParser.parse(Data(json.utf8))
        XCTAssertNil(reading.usedPercent)
    }

    func testKnownProductNames() {
        XCTAssertEqual(GrokBillingParser.displayName(for: "GrokImagine"), "Imagine")
        XCTAssertEqual(GrokBillingParser.displayName(for: "PRODUCT_GROK_VOICE"), "Voice")
        XCTAssertEqual(GrokBillingParser.displayName(for: "API"), "API")
        XCTAssertEqual(GrokBillingParser.displayName(for: "GrokAppBuilder"), "App Builder")
        XCTAssertEqual(GrokBillingParser.displayName(for: "GrokPlugins"), "Grok Plugins")
        XCTAssertEqual(GrokBillingParser.displayName(for: "ThirdParty"), "3rd Party")
        XCTAssertEqual(GrokBillingParser.displayName(for: "Chat"), "Chat")
    }

    func testBalanceParsesNegativeStringCents() throws {
        let json = #"{"total":{"val":"-1000"},"changes":[]}"#
        let cents = try XCTUnwrap(try ManagementAPIParser.parseBalance(Data(json.utf8)).get())
        XCTAssertEqual(cents, Int64(-1000))
    }

    func testSpendSumsDocumentedDollarValues() throws {
        let json = """
        {"timeSeries":[{"group":["Chat"],"dataPoints":[
          {"timestamp":"2025-10-01T00:00:00Z","values":[0.75]},
          {"timestamp":"2025-10-02T00:00:00Z","values":[0.25]}
        ]}],"limitReached":false}
        """
        let spend = try ManagementAPIParser.parseSpend(Data(json.utf8)).get()
        XCTAssertEqual(spend, 1.0, accuracy: 0.0001)
    }

    func testSixDigitFractionalTimestampParses() {
        let date = DateParsing.parseISO8601("2026-08-08T01:53:09.930537+00:00")
        XCTAssertNotNil(date)
    }
}
