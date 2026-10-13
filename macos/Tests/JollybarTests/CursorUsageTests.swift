import XCTest
@testable import Jollybar

final class CursorUsageTests: XCTestCase {
    func testGrokBotCentsIgnoreOtherApplications() {
        let events = [
            CursorUsageEvent(applicationType: "grok_bot", chargedCents: 250),
            CursorUsageEvent(applicationType: "cursor", chargedCents: 900),
            CursorUsageEvent(applicationType: "", chargedCents: 10),
        ]
        let totals = CursorUsageParser.grokBotCents(in: events)
        XCTAssertEqual(totals.cents, 250 as Double?)
        XCTAssertEqual(totals.matched, 1)
        XCTAssertEqual(totals.missingType, 0)
    }

    func testMissingApplicationTypeDoesNotCountAsGrokBot() {
        let events = [
            CursorUsageEvent(applicationType: nil, chargedCents: 250),
            CursorUsageEvent(applicationType: nil, chargedCents: 900),
        ]
        let totals = CursorUsageParser.grokBotCents(in: events)
        XCTAssertNil(totals.cents)
        XCTAssertEqual(totals.missingType, 2)
    }

    func testEmptyEventListIsZeroCents() {
        let totals = CursorUsageParser.grokBotCents(in: [])
        XCTAssertEqual(totals.cents, 0 as Double?)
        XCTAssertEqual(totals.missingType, 0)
    }

    func testSpendLimitBeatsTheMonthlyBudget() {
        let member = CursorMemberSpend(
            email: "person@example.com",
            effectivePerUserLimitDollars: 50,
            monthlyLimitDollars: nil
        )
        let limit = CursorUsageParser.limitCents(member: member, budgetDollars: 20)
        XCTAssertEqual(limit.cents, 5000 as Double?)
        XCTAssertEqual(limit.source, "spend limit" as String?)
    }

    func testBudgetIsUsedWhenTheMemberHasNoLimit() {
        let member = CursorMemberSpend(
            email: "person@example.com",
            effectivePerUserLimitDollars: 0,
            monthlyLimitDollars: nil
        )
        let limit = CursorUsageParser.limitCents(member: member, budgetDollars: 20)
        XCTAssertEqual(limit.cents, 2000 as Double?)
        XCTAssertEqual(limit.source, "monthly budget" as String?)
    }

    func testNoLimitWhenNeitherSourceHasOne() {
        let limit = CursorUsageParser.limitCents(member: nil, budgetDollars: nil)
        XCTAssertNil(limit.cents)
        XCTAssertNil(limit.source)
    }

    func testAssembleTurnsCentsIntoAPercent() {
        let reading = CursorUsageParser.assemble(
            usedCents: 250,
            missingTypeEvents: 0,
            eventsSeen: 2,
            truncated: false,
            limitCents: 5000,
            limitSource: "spend limit",
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            resetIsAssumedMonthly: true
        )
        XCTAssertEqual(reading.usedPercent, 5 as Double?)
        XCTAssertEqual(reading.limitSource, "spend limit" as String?)
        XCTAssertNil(reading.unavailableReason)
        XCTAssertTrue(reading.resetIsAssumedMonthly)
        XCTAssertFalse(reading.amountDetail?.contains("crsr_") == true)
    }

    func testAssembleExplainsAMissingApplicationType() {
        let reading = CursorUsageParser.assemble(
            usedCents: nil,
            missingTypeEvents: 3,
            eventsSeen: 3,
            truncated: false,
            limitCents: 5000,
            limitSource: "spend limit",
            resetsAt: nil,
            resetIsAssumedMonthly: false
        )
        XCTAssertNil(reading.usedPercent)
        XCTAssertTrue(reading.unavailableReason?.contains("application_type") == true)
    }

    func testAssumedMonthlyResetMovesPastNow() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(40 * 24 * 60 * 60)
        let reset = CursorUsageParser.assumedMonthlyReset(cycleStart: start, now: now)
        XCTAssertGreaterThan(reset, now)
    }

    func testEpochMillisecondsAndSeconds() {
        let seconds = CursorUsageParser.epochDate(1_700_000_000)
        let milliseconds = CursorUsageParser.epochDate(1_700_000_000_000)
        XCTAssertEqual(seconds, milliseconds as Date?)
    }

    func testParseSpendAndEventsKeepOnlyTheDocumentedFields() throws {
        let spendJSON = """
        {"teamMemberSpend":[{"email":"person@example.com","effectivePerUserLimitDollars":50,"monthlyLimitDollars":null}],"subscriptionCycleStart":1700000000000,"totalPages":1}
        """.data(using: .utf8)!
        let summary = try XCTUnwrap(CursorUsageParser.parseSpend(spendJSON))
        XCTAssertEqual(summary.members.count, 1)
        XCTAssertEqual(summary.members[0].effectivePerUserLimitDollars, 50, accuracy: 0.001)
        XCTAssertEqual(summary.subscriptionCycleStart, Date(timeIntervalSince1970: 1_700_000_000) as Date?)
        XCTAssertEqual(summary.totalPages, 1)

        let eventsJSON = """
        {"usageEvents":[{"application_type":"grok_bot","chargedCents":250},{"application_type":"cursor","chargedCents":900}],"pagination":{"hasNextPage":false}}
        """.data(using: .utf8)!
        let page = try XCTUnwrap(CursorUsageParser.parseEvents(eventsJSON))
        XCTAssertTrue(page.sawApplicationTypeKey)
        XCTAssertFalse(page.hasNextPage)
        XCTAssertEqual(CursorUsageParser.grokBotCents(in: page.events).cents, 250 as Double?)
    }

    func testParseEventsNoticesWhenTheFieldIsAbsent() throws {
        let eventsJSON = """
        {"usageEvents":[{"chargedCents":250}],"pagination":{"hasNextPage":true}}
        """.data(using: .utf8)!
        let page = try XCTUnwrap(CursorUsageParser.parseEvents(eventsJSON))
        XCTAssertFalse(page.sawApplicationTypeKey)
        XCTAssertTrue(page.hasNextPage)
        XCTAssertNil(page.events[0].applicationType)
    }

    func testContractEndParsesWithoutUsingThePoolAsAPersonalLimit() throws {
        let json = """
        {"pool":{"limitCents":100000,"usedCents":10,"remainingCents":99990,"contractEndDate":"2026-12-01T00:00:00Z"}}
        """.data(using: .utf8)!
        let end = try XCTUnwrap(CursorUsageParser.parseContractEnd(json))
        XCTAssertEqual(end, DateParsing.parseISO8601("2026-12-01T00:00:00Z") as Date?)
        let limit = CursorUsageParser.limitCents(member: nil, budgetDollars: nil)
        XCTAssertNil(limit.cents)
    }

    func testAPIKeyShape() {
        XCTAssertTrue(CursorUsageParser.isPlausibleAPIKey("crsr_test_key_123456"))
        XCTAssertFalse(CursorUsageParser.isPlausibleAPIKey("sk-test"))
        XCTAssertFalse(CursorUsageParser.isPlausibleAPIKey("crsr_short"))
        XCTAssertFalse(CursorUsageParser.isPlausibleAPIKey("crsr_bad\nkey_123456"))
    }

    func testMemberEmailMatchIsCaseInsensitive() {
        let members = [
            CursorMemberSpend(email: "Person@Example.com", effectivePerUserLimitDollars: 50, monthlyLimitDollars: nil)
        ]
        XCTAssertNotNil(CursorUsageParser.member(matching: "person@example.com", in: members))
        XCTAssertNil(CursorUsageParser.member(matching: "other@example.com", in: members))
    }
}
