import CoreGraphics
import Foundation

/// Seven local days of Grok Bot usage, as the daily rise in the weekly percent.
/// A drop is a window reset: that day's gain is the new level, not a negative.
enum SproutWeek {
    struct Day: Equatable, Identifiable {
        var id: Date { start }
        let start: Date
        /// Percentage points gained that day.
        let usagePoints: Double
        let isToday: Bool
    }

    static let minimumDistinctDays = 2

    /// Nil when fewer than two days in the window have a Grok Bot sample.
    static func build(
        points: [UsageDataPoint],
        now: Date,
        calendar: Calendar = .current
    ) -> [Day]? {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -6, to: today) else {
            return nil
        }

        let samples = points.compactMap { point -> (date: Date, percent: Double)? in
            guard let fraction = point.pctBot, fraction.isFinite else { return nil }
            return (point.timestamp, min(max(fraction, 0), 10) * 100)
        }.sorted { $0.date < $1.date }

        let distinct = Set(samples.map { calendar.startOfDay(for: $0.date) }.filter { $0 >= windowStart && $0 <= today })
        guard distinct.count >= minimumDistinctDays else { return nil }

        var gains: [Date: Double] = [:]
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            let day = calendar.startOfDay(for: current.date)
            guard day >= windowStart, day <= today else { continue }
            let delta: Double
            if current.percent + 0.05 < previous.percent {
                delta = max(0, current.percent)
            } else {
                delta = max(0, current.percent - previous.percent)
            }
            gains[day, default: 0] += delta
        }

        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: windowStart) else { return nil }
            return Day(start: day, usagePoints: gains[day] ?? 0, isToday: day == today)
        }
    }

    /// Stem height in points. Zero-usage days stay a short seed.
    static func stemHeight(usagePoints: Double, maxPoints: Double, maxHeight: CGFloat = 46) -> CGFloat {
        let seed: CGFloat = 8
        guard maxPoints > 0.05, usagePoints > 0 else { return seed }
        let ratio = min(usagePoints / maxPoints, 1)
        return seed + CGFloat(ratio) * (maxHeight - seed)
    }
}
