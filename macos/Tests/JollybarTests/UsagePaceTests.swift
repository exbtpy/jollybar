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
        let runsOut = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let ahead = UsagePace.Forecast(elapsedFraction: 0.5, aheadPoints: 12, runsOutAt: runsOut)
        let line = UsagePaceFormat.paceLine(
            forecast: ahead,
            usedPercent: 62,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )
        XCTAssertEqual(line, "Using 12% faster than pace · runs out ~Tue 22:13")
        XCTAssertFalse(line.contains("ahead of pace"))
        XCTAssertFalse(line.contains("PM"))

        let quiet = UsagePace.Forecast(elapsedFraction: 0.5, aheadPoints: -4, runsOutAt: nil)
        XCTAssertEqual(
            UsagePaceFormat.paceLine(forecast: quiet, usedPercent: 40, locale: Locale(identifier: "en_US"), calendar: calendar),
            "On pace to last until reset"
        )
        XCTAssertEqual(
            UsagePaceFormat.paceLine(forecast: quiet, usedPercent: 40, locale: Locale(identifier: "es_MX"), calendar: calendar),
            "A este ritmo alcanza hasta el reinicio"
        )
    }

    func testFasterPaceUsesATwentyFourHourClockInBothLanguages() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let runsOut = Date(timeIntervalSince1970: 1_791_411_420) // 2026-10-07 22:17:00 UTC
        let ahead = UsagePace.Forecast(elapsedFraction: 0.34, aheadPoints: 59, runsOutAt: runsOut)
        let english = UsagePaceFormat.paceLine(
            forecast: ahead,
            usedPercent: 93,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )
        XCTAssertEqual(english, "Using 59% faster than pace · runs out ~Wed 22:17")
        XCTAssertFalse(english.contains("10:17"))
        XCTAssertFalse(english.contains("PM"))

        let spanish = UsagePaceFormat.paceLine(
            forecast: ahead,
            usedPercent: 93,
            locale: Locale(identifier: "es_MX"),
            calendar: calendar
        )
        XCTAssertTrue(spanish.contains("Vas 59% más rápido que el ritmo · se acaba ~"), spanish)
        XCTAssertTrue(spanish.contains("22:17"), spanish)
        XCTAssertFalse(spanish.contains("PM"), spanish)
        XCTAssertFalse(spanish.contains("10:17"), spanish)
        XCTAssertFalse(spanish.contains("ahead of pace"), spanish)
    }

    func testUnderPaceNamesTheSpareInEnglishAndSpanish() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let behind = UsagePace.Forecast(elapsedFraction: 0.5, aheadPoints: -12, runsOutAt: nil)
        XCTAssertEqual(
            UsagePaceFormat.paceLine(forecast: behind, usedPercent: 38, locale: Locale(identifier: "en_US"), calendar: calendar),
            "Under pace, 12% to spare"
        )
        XCTAssertEqual(
            UsagePaceFormat.paceLine(forecast: behind, usedPercent: 38, locale: Locale(identifier: "es_MX"), calendar: calendar),
            "Por debajo del ritmo, te sobra 12%"
        )
    }

    func testASmallPaceBandStillLastsUntilReset() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let runsOut = Date(timeIntervalSince1970: 1_791_411_420)
        let band = UsagePaceFormat.onPaceBand
        let inside = UsagePace.Forecast(elapsedFraction: 0.4, aheadPoints: band, runsOutAt: runsOut)
        XCTAssertEqual(
            UsagePaceFormat.paceLine(forecast: inside, usedPercent: 45, locale: Locale(identifier: "en_US"), calendar: calendar),
            "On pace to last until reset"
        )
        let underBand = UsagePace.Forecast(elapsedFraction: 0.4, aheadPoints: -band, runsOutAt: nil)
        XCTAssertEqual(
            UsagePaceFormat.paceLine(forecast: underBand, usedPercent: 35, locale: Locale(identifier: "en_US"), calendar: calendar),
            "On pace to last until reset"
        )
        let faster = UsagePace.Forecast(elapsedFraction: 0.4, aheadPoints: band + 1, runsOutAt: runsOut)
        let fasterLine = UsagePaceFormat.paceLine(
            forecast: faster,
            usedPercent: 46,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )
        XCTAssertTrue(fasterLine.contains("Using \(band + 1)% faster than pace"))
        XCTAssertTrue(fasterLine.contains("22:17"))
        let spare = UsagePace.Forecast(elapsedFraction: 0.4, aheadPoints: -(band + 1), runsOutAt: nil)
        XCTAssertEqual(
            UsagePaceFormat.paceLine(forecast: spare, usedPercent: 34, locale: Locale(identifier: "en_US"), calendar: calendar),
            "Under pace, \(band + 1)% to spare"
        )
        let early = UsagePace.Forecast(elapsedFraction: 0.02, aheadPoints: 20, runsOutAt: nil)
        XCTAssertEqual(
            UsagePaceFormat.paceLine(forecast: early, usedPercent: 22, locale: Locale(identifier: "en_US"), calendar: calendar),
            "Using 20% faster than pace"
        )
        XCTAssertFalse(
            UsagePaceFormat.paceLine(forecast: early, usedPercent: 22, locale: Locale(identifier: "en_US"), calendar: calendar)
                .contains("runs out")
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

    func testResetLineKeepsEveningHoursOnATwentyFourHourClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_791_396_000) // 2026-10-07 18:00:00 UTC
        let reset = now.addingTimeInterval(24 * 3600)
        let line = UsagePaceFormat.resetLine(
            reset: reset,
            now: now,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )
        XCTAssertTrue(line.contains("18:00"), line)
        XCTAssertFalse(line.contains("06:00"), line)
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

    func testMenuThemeResolvesTheStoredStyle() {
        XCTAssertEqual(MenuTheme.resolve(nil), .percent)
        XCTAssertEqual(MenuTheme.resolve("percent"), .percent)
        XCTAssertEqual(MenuTheme.resolve("bars"), .bars)
        XCTAssertEqual(MenuTheme.resolve("classic"), .bars)
        XCTAssertEqual(MenuTheme.resolve("companion"), .companion)
        XCTAssertEqual(MenuTheme.resolve("nope"), .percent)
    }

    func testEveryMenuThemeShowsTheCompanionPopover() {
        XCTAssertEqual(MenuTheme.allCases.map(\.rawValue).sorted(), ["bars", "companion", "percent"])
        for theme in MenuTheme.allCases {
            XCTAssertTrue(
                PopoverContent.showsCompanionPopover(for: theme),
                "\(theme.rawValue) must open the companion popover"
            )
        }
        XCTAssertEqual(PopoverContent.width, 320)
    }

    @MainActor
    func testCompanionPopoverOmitsAccountEmail() {
        let email = "popover-reader@example.com"
        let suite = "popover-email-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = UsageService(
            session: URLSession(configuration: .ephemeral),
            proxyBaseURL: URL(string: "http://127.0.0.1:9")!,
            managementBaseURL: URL(string: "http://127.0.0.1:9")!,
            cursorBaseURL: URL(string: "http://127.0.0.1:9")!,
            dashboardBaseURL: URL(string: "http://127.0.0.1:9")!,
            sandSecretsURL: URL(fileURLWithPath: "/tmp/jollybar-missing-sand-secrets.json"),
            authFileURL: URL(fileURLWithPath: "/tmp/jollybar-missing-auth.json"),
            secretStore: MemorySecretStore(),
            defaults: defaults
        )
        service.replaceAccountEmail(email)
        service.reading = GrokBillingReading(
            usedPercent: 12,
            hasWeeklyPool: true,
            resetsAt: nil,
            periodType: "USAGE_PERIOD_TYPE_WEEKLY",
            products: [],
            extraCreditsCents: nil,
            onDemandCapCents: nil,
            onDemandUsedCents: nil,
            isUnifiedBillingUser: nil,
            subscriptionTier: "SuperGrok",
            unavailableReason: nil
        )
        service.dashboardPresence = .ready
        service.dashboardReading = CursorDashboardReading(
            grokBotPercent: 12,
            resetsAt: nil,
            periodStart: nil,
            includedLimitZero: false,
            hasAvailableUsage: true,
            accountEmail: email,
            cursorModelsPercent: 4,
            otherModelsPercent: 1,
            onDemandKnown: true,
            onDemand: nil,
            grokBotUnavailableReason: nil,
            cursorModelsUnavailableReason: nil
        )
        let model = CompanionPopoverModelBuilder.make(
            service: service,
            updaterError: nil,
            percentStyle: .used,
            chartMode: .sprout,
            sprouts: []
        )
        XCTAssertEqual(model.planTitle, "SuperGrok")
        XCTAssertFalse(PopoverContent.containsAccountEmail(model, email: email))
        XCTAssertFalse(PopoverContent.visibleCopy(model).joined(separator: "\n").contains("@"))
    }

    func testMenuBarStyleMigrationRewritesOldValuesOnce() {
        let name = "menu-style-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("classic", forKey: MenuTheme.defaultsKey)
        MenuBarStyleMigration.migrateIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: MenuTheme.defaultsKey), MenuTheme.bars.rawValue)
        XCTAssertTrue(defaults.bool(forKey: MenuBarStyleMigration.marker))

        defaults.set(MenuTheme.companion.rawValue, forKey: MenuTheme.defaultsKey)
        MenuBarStyleMigration.migrateIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: MenuTheme.defaultsKey), MenuTheme.companion.rawValue)
    }

    func testMenuBarStyleMigrationMapsTheOldCompanionItemToPercent() {
        let name = "menu-style-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(MenuTheme.companion.rawValue, forKey: MenuTheme.defaultsKey)
        MenuBarStyleMigration.migrateIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: MenuTheme.defaultsKey), MenuTheme.percent.rawValue)

        defaults.removeObject(forKey: MenuBarStyleMigration.marker)
        defaults.removeObject(forKey: MenuTheme.defaultsKey)
        MenuBarStyleMigration.migrateIfNeeded(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: MenuTheme.defaultsKey))
        XCTAssertTrue(defaults.bool(forKey: MenuBarStyleMigration.marker))
    }

    func testUsageBarsStayAFixedTemplateUntilTheMoodTint() {
        let quiet = renderIcon(
            topFraction: 0.2,
            topLabel: "GB",
            bottomFraction: nil,
            bottomLabel: "CM",
            mouthFraction: 0.2,
            tint: nil
        )
        let loud = renderIcon(
            topFraction: 1,
            topLabel: "Sp",
            bottomFraction: 0.4,
            bottomLabel: "Wk",
            mouthFraction: 1,
            tint: JollyTheme.asleep.nsColor
        )
        XCTAssertEqual(quiet.size, loud.size)
        XCTAssertEqual(quiet.size.height, 18)
        XCTAssertEqual(quiet.isTemplate, true)
        XCTAssertEqual(loud.isTemplate, false)
    }

    func testCompanionMenuIconIsNotATemplate() {
        let icon = renderCompanionMenuIcon(mood: .playful, mouthFraction: 0.2, frame: .rest)
        XCTAssertFalse(icon.isTemplate)
        XCTAssertGreaterThanOrEqual(icon.size.height, 16)
        XCTAssertLessThanOrEqual(icon.size.height, 18)
        let asleep = renderCompanionMenuIcon(mood: .asleep, mouthFraction: 1, frame: .rest)
        XCTAssertEqual(icon.size, asleep.size)
    }

    func testCompanionMenuMotionBlinksInsideABreath() {
        let (early, earlyOn) = CompanionMenuMotion.frame(
            breatheElapsed: 0.1,
            wiggleElapsed: nil,
            celebrateElapsed: nil
        )
        XCTAssertTrue(earlyOn)
        XCTAssertEqual(early.eyeOpen, 1)
        XCTAssertGreaterThan(early.breathe, 0)

        let (blink, blinkOn) = CompanionMenuMotion.frame(
            breatheElapsed: 0.66,
            wiggleElapsed: nil,
            celebrateElapsed: nil
        )
        XCTAssertTrue(blinkOn)
        XCTAssertLessThan(blink.eyeOpen, 0.2)

        let (done, doneOn) = CompanionMenuMotion.frame(
            breatheElapsed: CompanionMenuMotion.breatheDuration,
            wiggleElapsed: nil,
            celebrateElapsed: nil
        )
        XCTAssertFalse(doneOn)
        XCTAssertEqual(done, .rest)
    }

    func testCompanionMenuMotionWigglesAndCelebrates() {
        let (wiggle, wiggling) = CompanionMenuMotion.frame(
            breatheElapsed: nil,
            wiggleElapsed: 0.05,
            celebrateElapsed: nil
        )
        XCTAssertTrue(wiggling)
        XCTAssertNotEqual(wiggle.wiggle, 0)

        let (hop, hopping) = CompanionMenuMotion.frame(
            breatheElapsed: nil,
            wiggleElapsed: nil,
            celebrateElapsed: CompanionMenuMotion.celebrateDuration / 2
        )
        XCTAssertTrue(hopping)
        XCTAssertGreaterThan(hop.celebrate, 0.5)

        let (idle, idling) = CompanionMenuMotion.frame(
            breatheElapsed: nil,
            wiggleElapsed: nil,
            celebrateElapsed: nil
        )
        XCTAssertFalse(idling)
        XCTAssertEqual(idle, .rest)
    }

    func testMenuBarCelebrationUsesItsOwnKeysAndSkipsWhenStill() {
        let name = "menu-celebrate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let previous = Date(timeIntervalSince1970: 1_700_000_000)
        let current = previous.addingTimeInterval(7 * 24 * 60 * 60)
        defaults.set(previous.timeIntervalSince1970, forKey: CompanionMenuMotion.seenWindowKey)

        XCTAssertFalse(CompanionMenuMotion.claimCelebration(
            currentWindowStart: current,
            allowsMotion: false,
            defaults: defaults
        ))
        XCTAssertEqual(defaults.double(forKey: CompanionMenuMotion.celebratedWindowKey), current.timeIntervalSince1970)

        XCTAssertFalse(CompanionMenuMotion.claimCelebration(
            currentWindowStart: current,
            allowsMotion: true,
            defaults: defaults
        ))
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
