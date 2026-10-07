import Foundation

/// One short line for Bud. It changes when the mood or the pace story changes,
/// and a window seed picks from a small pool so the same state is not robotic.
/// Lines never mention a reset day, a pace, or a reading we do not have.
enum BudSpeech {
    enum Kind: Equatable {
        case waiting
        case plenty
        case easy
        case fast
        case tired
        case worried
        case asleep
    }

    static func kind(mood: CompanionMood, forecast: UsagePace.Forecast?) -> Kind {
        switch mood {
        case .unknown:
            return .waiting
        case .asleep:
            return .asleep
        case .worried:
            return .worried
        case .tired:
            return .tired
        case .playful:
            if forecast?.runsOutAt != nil { return .fast }
            return .plenty
        case .steady:
            if forecast?.runsOutAt != nil { return .fast }
            if forecast != nil { return .easy }
            return .plenty
        }
    }

    static func line(
        mood: CompanionMood,
        forecast: UsagePace.Forecast?,
        reset: Date?,
        seed: Int,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) -> String {
        let kind = kind(mood: mood, forecast: forecast)
        let weekday = reset.map { weekdayName($0, locale: locale, calendar: calendar) }
        return line(kind: kind, weekday: weekday, seed: seed, locale: locale)
    }

    static func line(
        kind: Kind,
        weekday: String?,
        seed: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let pool = pool(kind: kind, weekday: weekday)
        let index = stableIndex(seed: seed, count: pool.count)
        let entry = pool[index]
        if let weekday, entry.usesWeekday {
            return String(format: L10n.text(entry.key, entry.fallback), locale: locale, weekday)
        }
        return L10n.text(entry.key, entry.fallback)
    }

    /// Stable for a weekly window, and different when the kind changes.
    static func seed(periodStart: Date?, reset: Date?, kind: Kind) -> Int {
        let anchor = periodStart ?? reset ?? Date(timeIntervalSince1970: 0)
        let hours = Int(anchor.timeIntervalSince1970 / 3600)
        return hours ^ (kindToken(kind) &* 97)
    }

    static func stableIndex(seed: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let mixed = seed &* 1_664_525 &+ 1_013_904_223
        let positive = mixed == Int.min ? 0 : abs(mixed)
        return positive % count
    }

    private struct Entry {
        let key: String
        let fallback: String
        var usesWeekday: Bool = false
    }

    private static func pool(kind: Kind, weekday: String?) -> [Entry] {
        switch kind {
        case .waiting:
            return [
                Entry(key: "speech.waiting.1", fallback: "Waiting on a reading."),
                Entry(key: "speech.waiting.2", fallback: "No number yet."),
                Entry(key: "speech.waiting.3", fallback: "I'll know more after a sync."),
            ]
        case .plenty:
            return [
                Entry(key: "speech.plenty.1", fallback: "Plenty of room this week."),
                Entry(key: "speech.plenty.2", fallback: "We're in good shape."),
                Entry(key: "speech.plenty.3", fallback: "Lots of week left."),
            ]
        case .easy:
            return [
                Entry(key: "speech.easy.1", fallback: "Easy, we're ahead of pace."),
                Entry(key: "speech.easy.2", fallback: "Comfortable for the rest of the week."),
                Entry(key: "speech.easy.3", fallback: "This pace lasts until reset."),
            ]
        case .fast:
            return [
                Entry(key: "speech.fast.1", fallback: "We're using it faster than the week."),
                Entry(key: "speech.fast.2", fallback: "This pace runs out before reset."),
                Entry(key: "speech.fast.3", fallback: "Might want to ease up."),
            ]
        case .tired:
            return [
                Entry(key: "speech.tired.1", fallback: "Getting a little tired."),
                Entry(key: "speech.tired.2", fallback: "The week's filling up."),
                Entry(key: "speech.tired.3", fallback: "Let's take it easier."),
            ]
        case .worried:
            var lines = [
                Entry(key: "speech.worried.1", fallback: "Almost at the limit."),
                Entry(key: "speech.worried.2", fallback: "Not much left this week."),
            ]
            if weekday != nil {
                lines.insert(
                    Entry(key: "speech.worried.reset", fallback: "Running low, resets %@.", usesWeekday: true),
                    at: 0
                )
            }
            return lines
        case .asleep:
            var lines = [
                Entry(key: "speech.asleep.1", fallback: "I'll nap until the next window."),
                Entry(key: "speech.asleep.2", fallback: "Paused at the limit."),
            ]
            if weekday != nil {
                lines.insert(
                    Entry(key: "speech.asleep.reset", fallback: "Out until %@.", usesWeekday: true),
                    at: 0
                )
            }
            return lines
        }
    }

    private static func weekdayName(_ date: Date, locale: Locale, calendar: Calendar) -> String {
        return date.formatted(
            JollyClock.style(locale: locale, calendar: calendar)
                .weekday(.wide)
        )
    }

    private static func kindToken(_ kind: Kind) -> Int {
        switch kind {
        case .waiting: return 1
        case .plenty: return 2
        case .easy: return 3
        case .fast: return 4
        case .tired: return 5
        case .worried: return 6
        case .asleep: return 7
        }
    }
}
