import XCTest
@testable import GrokUsageBar

final class UsageServiceTests: XCTestCase {
    func testBackoffIntervalCapsAtSixtyMinutes() {
        XCTAssertEqual(
            UsageService.backoffInterval(retryAfter: nil, currentInterval: 30 * 60),
            60 * 60
        )
        XCTAssertEqual(
            UsageService.backoffInterval(retryAfter: 10, currentInterval: 30 * 60),
            60 * 60
        )
    }

    func testBackoffIntervalNeverReducesSixtyMinutePolling() {
        XCTAssertEqual(
            UsageService.backoffInterval(retryAfter: 1, currentInterval: 60 * 60),
            60 * 60
        )
    }

    func testTeamIDRejectsPathCharacters() {
        XCTAssertTrue(XAIManagementProvider.isValidTeamID("65c1e471-205f-4566-9c5a-07198bcdf4ce"))
        XCTAssertFalse(XAIManagementProvider.isValidTeamID("../etc"))
        XCTAssertFalse(XAIManagementProvider.isValidTeamID("team/id"))
        XCTAssertFalse(XAIManagementProvider.isValidTeamID(""))
    }

    func testRedirectStaysOnTheSameOrigin() {
        let billing = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        XCTAssertTrue(RedirectPolicy.allows(
            from: billing,
            to: URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
        ))
        XCTAssertFalse(RedirectPolicy.allows(
            from: billing,
            to: URL(string: "https://evil.example/collect")!
        ))
        XCTAssertFalse(RedirectPolicy.allows(
            from: billing,
            to: URL(string: "http://cli-chat-proxy.grok.com/v1/billing")!
        ))
        XCTAssertFalse(RedirectPolicy.allows(
            from: URL(string: "http://127.0.0.1:8080/v1/billing")!,
            to: URL(string: "http://127.0.0.1:9/v1/billing")!
        ))
    }

    func testHeaderValuesRejectControlCharacters() {
        XCTAssertTrue(HeaderSafety.isSafe("plain-token"))
        XCTAssertFalse(HeaderSafety.isSafe("token\r\nX-Injected: 1"))
        XCTAssertFalse(HeaderSafety.isSafe(""))
    }
}
