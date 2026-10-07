import Foundation

/// ISO-8601 parsing shared by the billing response and `~/.grok/auth.json`.
///
/// The credits endpoint emits timestamps like `2026-08-08T01:53:09.930537+00:00`
/// (six fractional digits). `ISO8601DateFormatter` is inconsistent past three
/// digits, so those are trimmed before a second attempt.
enum DateParsing {
    static func parseISO8601(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = parseWithFormatters(trimmed) {
            return date
        }
        if let normalized = normalizingFractionalSeconds(trimmed) {
            return parseWithFormatters(normalized)
        }
        return nil
    }

    static func formatISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// `yyyy-MM-dd HH:mm:ss` in UTC, the shape the Management API usage example uses.
    static func formatAnalyticsTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func parseWithFormatters(_ value: String) -> Date? {
        let options: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime]
        ]
        for option in options {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = option
            if let date = formatter.date(from: value) {
                return date
            }
        }

        let patterns = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        ]
        for pattern in patterns {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    /// `2026-08-08T01:53:09.930537+00:00` → `2026-08-08T01:53:09.930+00:00`.
    static func normalizingFractionalSeconds(_ value: String) -> String? {
        guard let dot = value.firstIndex(of: ".") else { return nil }
        var end = value.index(after: dot)
        while end < value.endIndex, value[end].isNumber {
            end = value.index(after: end)
        }
        let digits = value[value.index(after: dot)..<end]
        guard digits.count > 3 else { return nil }
        return String(value[...dot]) + digits.prefix(3) + value[end...]
    }
}
