import Foundation

/// Looks up a string in the app resource bundle and falls back to English.
/// Keys are stable; the English fallback is what tests and a missing catalog show.
enum L10n {
    static func text(
        _ key: String,
        _ fallback: String,
        locale: Locale? = nil,
        bundle: Bundle? = nil
    ) -> String {
        if let locale, let found = string(key, locale: locale, bundle: bundle) {
            return found
        }
        guard let resolved = bundle ?? jollybarResourceBundle() else { return fallback }
        let found = resolved.localizedString(forKey: key, value: fallback, table: "Localizable")
        if found.isEmpty { return fallback }
        return found
    }

    static func format(
        _ key: String,
        _ fallback: String,
        locale: Locale = .autoupdatingCurrent,
        _ arguments: CVarArg...
    ) -> String {
        let template = text(key, fallback, locale: locale)
        return String(format: template, locale: locale, arguments: arguments)
    }

    /// `en` or `es` from `en_US` / `es_MX`. The catalogs are language, not region.
    private static func languageCode(_ locale: Locale) -> String? {
        var identifier = locale.identifier
        if identifier.isEmpty || identifier == "current" {
            identifier = Locale.current.identifier
        }
        let head = identifier.prefix { character in
            character != "_" && character != "-" && character != "@"
        }
        return head.isEmpty ? nil : String(head)
    }

    private static func string(_ key: String, locale: Locale, bundle: Bundle?) -> String? {
        guard let code = languageCode(locale) else { return nil }
        let table = stringsTable(language: code, bundle: bundle)
        guard let value = table?[key], !value.isEmpty else { return nil }
        return value
    }

    private static var tables: [String: [String: String]] = [:]
    private static let tablesLock = NSLock()

    private static func stringsTable(language: String, bundle: Bundle?) -> [String: String]? {
        tablesLock.lock()
        if let cached = tables[language] {
            tablesLock.unlock()
            return cached
        }
        tablesLock.unlock()

        guard let root = bundle ?? jollybarResourceBundle(),
              let url = root.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: language
              ),
              let data = try? Data(contentsOf: url),
              let parsed = loadTable(from: data) else {
            return nil
        }
        tablesLock.lock()
        tables[language] = parsed
        tablesLock.unlock()
        return parsed
    }

    private static func loadTable(from data: Data) -> [String: String]? {
        if let table = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: String],
           !table.isEmpty {
            return table
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf16LittleEndian)
        guard let text, !text.isEmpty else { return nil }
        let parsed = parseStrings(text)
        return parsed.isEmpty ? nil : parsed
    }

    /// `Localizable.strings` lines of the form `"key" = "value";`.
    private static func parseStrings(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #""((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { return }
            result[unescape(String(text[keyRange]))] = unescape(String(text[valueRange]))
        }
        return result
    }

    private static func unescape(_ value: String) -> String {
        var output = ""
        var escaping = false
        for character in value {
            if escaping {
                switch character {
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                case "\\", "\"": output.append(character)
                default: output.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                output.append(character)
            }
        }
        return output
    }
}
