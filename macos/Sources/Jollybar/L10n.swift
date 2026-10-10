import Foundation

/// Looks up a string in the app resource bundle and falls back to English.
/// Keys are stable; the English fallback is what tests and a missing catalog show.
enum L10n {
    static func text(
        _ key: String,
        _ fallback: String,
        bundle: Bundle? = jollybarResourceBundle()
    ) -> String {
        guard let bundle else { return fallback }
        let found = bundle.localizedString(forKey: key, value: fallback, table: "Localizable")
        if found.isEmpty { return fallback }
        return found
    }

    static func format(
        _ key: String,
        _ fallback: String,
        locale: Locale = .autoupdatingCurrent,
        _ arguments: CVarArg...
    ) -> String {
        let template = text(key, fallback)
        return String(format: template, locale: locale, arguments: arguments)
    }
}
