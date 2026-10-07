import AppKit
import XCTest
@testable import Jollybar

final class UsagePaceTests: XCTestCase {
    private let hour: TimeInterval = 3600

    func testMissingResetDoesNotInventAForecast() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(UsagePace.forecast(usedPercent: 40, periodStart: now, reset: nil, now: now))
        XCTAssertNil(UsagePace.forecast(usedPercent: nil, periodStart: now, reset: now.addingTimeInterval(hour), now: now))
        XCTAssertNil(UsagePace.forecast(usedPercent: .nan, periodStart: nil, reset: now.addingTimeInterval(hour), now: now))
    }

    func testMissingStartAssumesASevenDayWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(3 * 24 * hour)
        let forecast = UsagePace.forecast(usedPercent: 10, periodStart: nil, reset: reset, now: now)
        XCTAssertEqual(forecast?.elapsedFraction ?? -1, 4.0 / 7.0, accuracy: 0.000_001)
        XCTAssertNil(forecast?.runsOutAt)
    }

    func testPeriodStartWinsOverTheSevenDayAssumption() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-1 * 24 * hour)
        let reset = now.addingTimeInterval(1 * 24 * hour)
        let forecast = UsagePace.forecast(usedPercent: 40, periodStart: start, reset: reset, now: now)
        XCTAssertEqual(forecast?.elapsedFraction ?? -1, 0.5, accuracy: 0.000_001)
        XCTAssertNil(forecast?.runsOutAt)
        XCTAssertEqual(forecast?.aheadPoints, -10)
    }

    func testAheadOfPaceRunsOutBeforeReset() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(40 * hour)
        let reset = start.addingTimeInterval(100 * hour)
        let forecast = try XCTUnwrap(UsagePace.forecast(
            usedPercent: 50,
            periodStart: start,
            reset: reset,
            now: now
        ))
        XCTAssertEqual(forecast.aheadPoints, 10)
        XCTAssertEqual(forecast.elapsedFraction, 0.4, accuracy: 0.000_001)
        let expected = now.addingTimeInterval(40 * hour)
        XCTAssertEqual(forecast.runsOutAt?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 1)
        XCTAssertLessThan(forecast.runsOutAt ?? .distantFuture, reset)
    }

    func testExactPaceLastsUntilReset() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(40 * hour)
        let reset = start.addingTimeInterval(100 * hour)
        let forecast = UsagePace.forecast(usedPercent: 40, periodStart: start, reset: reset, now: now)
        XCTAssertEqual(forecast?.aheadPoints, 0)
        XCTAssertNil(forecast?.runsOutAt)
        XCTAssertEqual(forecast?.lastsUntilReset, true)
    }

    func testBehindPaceLastsUntilReset() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(50 * hour)
        let reset = start.addingTimeInterval(100 * hour)
        let forecast = UsagePace.forecast(usedPercent: 30, periodStart: start, reset: reset, now: now)
        XCTAssertEqual(forecast?.aheadPoints, -20)
        XCTAssertNil(forecast?.runsOutAt)
    }

    func testAlreadyAtTheLimitDoesNotForecastAFutureRunOut() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(50 * hour)
        let reset = start.addingTimeInterval(100 * hour)
        let forecast = UsagePace.forecast(usedPercent: 100, periodStart: start, reset: reset, now: now)
        XCTAssertNil(forecast?.runsOutAt)
        XCTAssertEqual(
            UsagePaceFormat.paceLine(forecast: try XCTUnwrap(forecast), usedPercent: 100),
            L10n.text("pace.atLimit", "At the limit until reset")
        )
    }

    func testAShortSampleDoesNotClaimARunOut() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-5 * 60)
        let reset = now.addingTimeInterval(7 * 24 * hour)
        let forecast = UsagePace.forecast(usedPercent: 20, periodStart: start, reset: reset, now: now)
        XCTAssertNil(forecast?.runsOutAt)
    }

    func testLeafSitsOnTheElapsedPosition() {
        let forecast = UsagePace.Forecast(elapsedFraction: 0.42, aheadPoints: 3, runsOutAt: nil)
        XCTAssertEqual(UsagePace.leafFraction(forecast), 0.42, accuracy: 0.000_001)
        let edge = UsagePace.Forecast(elapsedFraction: 0.99, aheadPoints: 1, runsOutAt: nil)
        XCTAssertEqual(UsagePace.leafFraction(edge), 0.96, accuracy: 0.000_001)
    }

    func testAheadLineNamesTheRunOutAndTheQuietLineDoesNot() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let runsOut = Date(timeIntervalSince1970: 1_700_000_000)
        let ahead = UsagePace.Forecast(elapsedFraction: 0.5, aheadPoints: 12, runsOutAt: runsOut)
        let line = UsagePaceFormat.paceLine(
            forecast: ahead,
            usedPercent: 62,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )
        XCTAssertTrue(line.contains("12%"))
        XCTAssertTrue(line.contains("ahead of pace"))
        XCTAssertTrue(line.contains("runs out"))

        let quiet = UsagePace.Forecast(elapsedFraction: 0.5, aheadPoints: -4, runsOutAt: nil)
        XCTAssertEqual(
            UsagePaceFormat.paceLine(forecast: quiet, usedPercent: 40, locale: Locale(identifier: "en_US"), calendar: calendar),
            "On pace to last until reset"
        )
    }

    func testResetLineUsesTheCompactCountdown() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_791_396_000) // 2026-10-07 18:00:00 UTC
        let reset = Date(timeIntervalSince1970: 1_791_795_600) // 2026-10-12 09:00:00 UTC
        XCTAssertEqual(UsagePaceFormat.compactRemaining(seconds: (4 * 24 + 15) * 3600), "4d 15h")
        let line = UsagePaceFormat.resetLine(reset: reset, now: now, locale: Locale(identifier: "en_US"), calendar: calendar)
        XCTAssertTrue(line.hasPrefix("Resets "))
        XCTAssertTrue(line.contains("09:00"))
        XCTAssertTrue(line.contains("4d 15h"))
    }

    func testCelebrationPlaysOncePerNewWindow() {
        let previous = Date(timeIntervalSince1970: 1_000)
        let current = previous.addingTimeInterval(7 * 24 * hour)
        XCTAssertEqual(
            ResetCelebration.windowToCelebrate(
                previousWindowStart: previous,
                currentWindowStart: current,
                alreadyCelebrated: nil
            ),
            current
        )
        XCTAssertNil(
            ResetCelebration.windowToCelebrate(
                previousWindowStart: previous,
                currentWindowStart: current,
                alreadyCelebrated: current
            )
        )
        XCTAssertNil(
            ResetCelebration.windowToCelebrate(
                previousWindowStart: nil,
                currentWindowStart: current,
                alreadyCelebrated: nil
            )
        )
    }
}

final class JollyThemeTests: XCTestCase {
    func testMoodColorsMatchThePalette() {
        assertColor(JollyTheme.moodRGB(.playful), 0x2E, 0xC4, 0xB6)
        assertColor(JollyTheme.moodRGB(.steady), 0xF2, 0xC1, 0x4E)
        assertColor(JollyTheme.moodRGB(.tired), 0xF2, 0x8C, 0x38)
        assertColor(JollyTheme.moodRGB(.worried), 0xF2, 0x54, 0x5B)
        assertColor(JollyTheme.moodRGB(.asleep), 0x8E, 0x8C, 0xD8)
    }

    func testMenuBarStaysNeutralBelowSeventyAndTintsFromThere() {
        XCTAssertFalse(JollyTheme.menuUsesMoodTint(usedPercent: 69.9))
        XCTAssertTrue(JollyTheme.menuUsesMoodTint(usedPercent: 70))
        XCTAssertNil(JollyTheme.menuTint(mood: .playful, usedPercent: 28))
        XCTAssertNil(JollyTheme.menuTint(mood: .unknown, usedPercent: 95))
        XCTAssertEqual(JollyTheme.menuTint(mood: .steady, usedPercent: 70), JollyTheme.steady)
        XCTAssertEqual(JollyTheme.menuTint(mood: .tired, usedPercent: 78), JollyTheme.tired)
        XCTAssertEqual(JollyTheme.menuTint(mood: .worried, usedPercent: 93), JollyTheme.worried)
        XCTAssertEqual(JollyTheme.menuTint(mood: .asleep, usedPercent: 100), JollyTheme.asleep)
    }

    func testHeroNumberCanShowWhatIsLeft() {
        XCTAssertEqual(UsageNumber.heroText(usedPercent: 38.2, style: .used), "38%")
        XCTAssertEqual(UsageNumber.heroText(usedPercent: 38.2, style: .left), "62%")
        XCTAssertEqual(UsageNumber.heroText(usedPercent: 100, style: .left), "0%")
        XCTAssertEqual(UsageNumber.menuText(usedPercent: 38.2), "38%")
        XCTAssertEqual(UsageNumber.menuText(usedPercent: nil), "—")
    }

    func testMenuBarPercentSlotDoesNotChangeWidth() {
        let low = renderCompanionStatusIcon(mood: .playful, percentText: "8%", tint: nil)
        let mid = renderCompanionStatusIcon(mood: .steady, percentText: "38%", tint: nil)
        let full = renderCompanionStatusIcon(mood: .worried, percentText: "100%", tint: JollyTheme.worried.nsColor)
        XCTAssertEqual(low.size, mid.size)
        XCTAssertEqual(mid.size.width, full.size.width)
        XCTAssertEqual(low.isTemplate, true)
        XCTAssertEqual(full.isTemplate, false)
        XCTAssertGreaterThanOrEqual(low.size.height, 16)
        XCTAssertLessThanOrEqual(low.size.height, 18)
    }

    private func assertColor(_ rgb: JollyTheme.RGB, _ red: Int, _ green: Int, _ blue: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rgb.red, Double(red) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rgb.green, Double(green) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rgb.blue, Double(blue) / 255, accuracy: 0.001, file: file, line: line)
    }
}

final class SproutWeekTests: XCTestCase {
    func testDailyDeltaTreatsADropAsAReset() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monday = try XCTUnwrap(DateParsing.parseISO8601("2026-10-05T10:00:00Z"))
        let mondayLater = try XCTUnwrap(DateParsing.parseISO8601("2026-10-05T20:00:00Z"))
        let tuesday = try XCTUnwrap(DateParsing.parseISO8601("2026-10-06T10:00:00Z"))
        let wednesday = try XCTUnwrap(DateParsing.parseISO8601("2026-10-07T10:00:00Z"))
        let now = try XCTUnwrap(DateParsing.parseISO8601("2026-10-07T18:00:00Z"))
        let points = [
            UsageDataPoint(timestamp: monday, pctWeekly: 0, pctBot: 0.10, includesWeekly: false),
            UsageDataPoint(timestamp: mondayLater, pctWeekly: 0, pctBot: 0.14, includesWeekly: false),
            UsageDataPoint(timestamp: tuesday, pctWeekly: 0, pctBot: 0.20, includesWeekly: false),
            UsageDataPoint(timestamp: wednesday, pctWeekly: 0, pctBot: 0.02, includesWeekly: false),
        ]
        let days = try XCTUnwrap(SproutWeek.build(points: points, now: now, calendar: calendar))
        XCTAssertEqual(days.count, 7)
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.start, $0.usagePoints) })
        XCTAssertEqual(byDay[calendar.startOfDay(for: monday)] ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(byDay[calendar.startOfDay(for: tuesday)] ?? -1, 6, accuracy: 0.001)
        XCTAssertEqual(byDay[calendar.startOfDay(for: wednesday)] ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(days.last?.isToday, true)
    }

    func testOneDayIsNotEnoughForTheSproutWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(DateParsing.parseISO8601("2026-10-07T18:00:00Z"))
        let earlier = now.addingTimeInterval(-3 * 3600)
        let points = [
            UsageDataPoint(timestamp: earlier, pctWeekly: 0, pctBot: 0.1, includesWeekly: false),
            UsageDataPoint(timestamp: now, pctWeekly: 0, pctBot: 0.2, includesWeekly: false),
        ]
        XCTAssertNil(SproutWeek.build(points: points, now: now, calendar: calendar))
    }
}

final class BudSpeechTests: XCTestCase {
    func testSpeechKindFollowsMoodAndDoesNotClaimPaceWithoutAForecast() {
        XCTAssertEqual(BudSpeech.kind(mood: .unknown, forecast: nil), .waiting)
        XCTAssertEqual(BudSpeech.kind(mood: .playful, forecast: nil), .plenty)
        XCTAssertEqual(BudSpeech.kind(mood: .steady, forecast: nil), .plenty)
        let lasting = UsagePace.Forecast(elapsedFraction: 0.5, aheadPoints: -5, runsOutAt: nil)
        XCTAssertEqual(BudSpeech.kind(mood: .steady, forecast: lasting), .easy)
        XCTAssertEqual(BudSpeech.kind(mood: .playful, forecast: lasting), .plenty)
        let burning = UsagePace.Forecast(elapsedFraction: 0.4, aheadPoints: 12, runsOutAt: Date())
        XCTAssertEqual(BudSpeech.kind(mood: .playful, forecast: burning), .fast)
        XCTAssertEqual(BudSpeech.kind(mood: .worried, forecast: burning), .worried)
        XCTAssertEqual(BudSpeech.kind(mood: .asleep, forecast: nil), .asleep)
    }

    func testWorriedLineNamesTheDayOnlyWhenWeHaveOne() {
        let locale = Locale(identifier: "en_US")
        for seed in 0..<16 {
            let quiet = BudSpeech.line(kind: .worried, weekday: nil, seed: seed, locale: locale)
            XCTAssertFalse(quiet.localizedCaseInsensitiveContains("monday"))
            XCTAssertFalse(quiet.contains("%@"))
        }
        let named = (0..<16).map {
            BudSpeech.line(kind: .worried, weekday: "Monday", seed: $0, locale: locale)
        }
        XCTAssertTrue(named.contains { $0.contains("Monday") })
    }

    func testTheSameStateKeepsTheSameLine() {
        let first = BudSpeech.line(kind: .plenty, weekday: nil, seed: 42)
        let second = BudSpeech.line(kind: .plenty, weekday: nil, seed: 42)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }

    func testWaitingNeverMentionsAReset() {
        for seed in 0..<8 {
            let line = BudSpeech.line(kind: .waiting, weekday: "Monday", seed: seed)
            XCTAssertFalse(line.localizedCaseInsensitiveContains("monday"))
            XCTAssertFalse(line.localizedCaseInsensitiveContains("reset"))
        }
    }
}
