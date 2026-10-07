import Foundation

/// Pace of the Grok Bot weekly window.
///
/// Elapsed percent comes from `currentPeriodStart` and `nextResetTimestampUtc`.
/// When the start is missing, the window is the seven days before reset.
/// "Ahead of pace" means used percent is higher than elapsed percent.
/// The run-out time is set only when that line reaches 100% strictly before reset.
enum UsagePace {
    static let assumedWindow: TimeInterval = 7 * 24 * 60 * 60
    /// A few minutes of samples is not a pace. Skip the run-out claim until then.
    static let minimumElapsedForForecast: TimeInterval = 15 * 60

    struct Window: Equatable {
        let start: Date
        let end: Date
    }

    struct Forecast: Equatable {
        /// 0...1, where the leaf sits.
        let elapsedFraction: Double
        /// Rounded used% minus elapsed%. Positive means burning faster than the window.
        let aheadPoints: Int
        /// When the meter is projected to hit 100%, if that is strictly before reset.
        let runsOutAt: Date?
        var lastsUntilReset: Bool { runsOutAt == nil }
    }

    static func window(periodStart: Date?, reset: Date?) -> Window? {
        guard let reset else { return nil }
        let start: Date
        if let periodStart, periodStart < reset {
            start = periodStart
        } else {
            start = reset.addingTimeInterval(-assumedWindow)
        }
        guard reset.timeIntervalSince(start) > 0 else { return nil }
        return Window(start: start, end: reset)
    }

    static func resolvedStart(periodStart: Date?, reset: Date?) -> Date? {
        window(periodStart: periodStart, reset: reset)?.start
    }

    static func forecast(
        usedPercent: Double?,
        periodStart: Date?,
        reset: Date?,
        now: Date
    ) -> Forecast? {
        guard let usedPercent, usedPercent.isFinite, usedPercent >= 0 else { return nil }
        guard let window = window(periodStart: periodStart, reset: reset) else { return nil }
        let duration = window.end.timeIntervalSince(window.start)
        guard duration > 0 else { return nil }

        let elapsedTime = now.timeIntervalSince(window.start)
        let elapsedFraction = min(max(elapsedTime / duration, 0), 1)
        let usedFraction = usedPercent / 100
        let aheadPoints = Int(round((usedFraction - elapsedFraction) * 100))

        let runsOutAt = projectedRunOut(
            usedFraction: usedFraction,
            elapsedTime: elapsedTime,
            now: now,
            windowEnd: window.end
        )
        return Forecast(
            elapsedFraction: elapsedFraction,
            aheadPoints: aheadPoints,
            runsOutAt: runsOutAt
        )
    }

    /// Leaf position clamped so the glyph stays on the capsule.
    static func leafFraction(_ forecast: Forecast) -> Double {
        min(max(forecast.elapsedFraction, 0.04), 0.96)
    }

    private static func projectedRunOut(
        usedFraction: Double,
        elapsedTime: TimeInterval,
        now: Date,
        windowEnd: Date
    ) -> Date? {
        if usedFraction >= 1 { return nil }
        guard elapsedTime >= minimumElapsedForForecast, usedFraction > 0 else { return nil }
        let ratePerSecond = usedFraction / elapsedTime
        guard ratePerSecond > 0 else { return nil }
        let secondsRemaining = (1 - usedFraction) / ratePerSecond
        guard secondsRemaining.isFinite, secondsRemaining > 0 else { return nil }
        let hit = now.addingTimeInterval(secondsRemaining)
        guard hit < windowEnd else { return nil }
        return hit
    }
}

enum UsagePaceFormat {
    static func resetLine(
        reset: Date,
        now: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) -> String {
        let seconds = Int(reset.timeIntervalSince(now))
        if seconds <= 0 {
            return L10n.text("reset.now", "Resets now")
        }
        let stamp = reset.formatted(
            JollyClock.style(locale: locale, calendar: calendar)
                .weekday(.abbreviated)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
        return L10n.format(
            "reset.line",
            "Resets %@ · in %@",
            locale: locale,
            stamp,
            compactRemaining(seconds: seconds)
        )
    }

    static func compactRemaining(seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        let hours = minutes / 60
        let days = hours / 24
        if days >= 1 {
            return "\(days)d \(hours % 24)h"
        }
        if hours >= 1 {
            return "\(hours)h \(minutes % 60)m"
        }
        return "\(max(minutes, 1))m"
    }

    static func paceLine(
        forecast: UsagePace.Forecast,
        usedPercent: Double,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) -> String {
        if usedPercent >= 100 {
            return L10n.text("pace.atLimit", "At the limit until reset")
        }
        guard let runsOut = forecast.runsOutAt else {
            return L10n.text("pace.lasts", "On pace to last until reset")
        }
        let points = max(forecast.aheadPoints, 1)
        let when = shortWhen(runsOut, locale: locale, calendar: calendar)
        return L10n.format(
            "pace.ahead",
            "%d%% ahead of pace · runs out ~%@",
            locale: locale,
            points,
            when
        )
    }

    static func shortWhen(
        _ date: Date,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        let day = date.formatted(
            JollyClock.style(locale: locale, calendar: calendar)
                .weekday(.abbreviated)
        )
        let time = date.formatted(
            JollyClock.style(locale: locale, calendar: calendar, time: .shortened)
                .hour(.defaultDigits(amPM: .abbreviated))
        )
        return "\(day) \(time)"
    }
}

/// Builds a `Date.FormatStyle` with locale and time zone set as properties.
/// Chaining `.timeZone(_:)` after weekday or hour symbols selects the format-symbol overload, which does not take a `TimeZone`.
enum JollyClock {
    static func style(
        locale: Locale,
        calendar: Calendar,
        date: Date.FormatStyle.DateStyle = .omitted,
        time: Date.FormatStyle.TimeStyle = .omitted
    ) -> Date.FormatStyle {
        var calendar = calendar
        calendar.locale = locale
        var style = Date.FormatStyle(date: date, time: time)
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return style
    }
}

enum ResetCelebration {
    /// A new weekly window after one we have already displayed.
    /// The returned date is the window start to remember so the celebration plays once.
    static func windowToCelebrate(
        previousWindowStart: Date?,
        currentWindowStart: Date?,
        alreadyCelebrated: Date?
    ) -> Date? {
        guard let previous = previousWindowStart, let current = currentWindowStart else { return nil }
        guard current.timeIntervalSince(previous) >= 60 * 60 else { return nil }
        if let alreadyCelebrated, abs(alreadyCelebrated.timeIntervalSince(current)) < 1 {
            return nil
        }
        return current
    }
}
