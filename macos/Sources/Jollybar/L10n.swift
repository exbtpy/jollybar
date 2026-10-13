import Foundation

/// Looks up a string in the app resource bundle and falls back to English.
/// Keys are stable; the English fallback is what tests and a missing catalog show.
///
/// An explicit locale reads that language's `.lproj` from `Bundle.module`
/// (`es_MX` uses `es` when there is no regional catalog). The system language
/// takes the same path, so a Spanish Mac does not stay on the development language.
enum L10n {
    static func text(
        _ key: String,
        _ fallback: String,
        locale: Locale? = nil,
        bundle: Bundle? = nil
    ) -> String {
        let root = bundle ?? Bundle.module
        if let found = string(key, locale: locale ?? .autoupdatingCurrent, bundle: root) {
            return found
        }
        let found = root.localizedString(forKey: key, value: fallback, table: "Localizable")
        if found.isEmpty || found == key { return fallback }
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

    private static func string(_ key: String, locale: Locale, bundle: Bundle) -> String? {
        guard let path = lprojPath(for: locale, in: bundle) else { return nil }
        guard let table = stringsTable(at: path), let value = table[key], !value.isEmpty else { return nil }
        return value
    }

    /// `es_MX` and `es-MX` try the regional folder, then the base language `es`.
    private static func lprojPath(for locale: Locale, in bundle: Bundle) -> String? {
        for code in candidateLanguages(locale) {
            let folder = "\(code).lproj"
            if let path = bundle.path(forResource: code, ofType: "lproj"),
               URL(fileURLWithPath: path).lastPathComponent == folder {
                return path
            }
            let roots = [bundle.resourceURL, bundle.bundleURL].compactMap { $0 }
            for root in roots {
                let url = root.appendingPathComponent(folder, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url.path
                }
            }
        }
        return nil
    }

    private static func candidateLanguages(_ locale: Locale) -> [String] {
        var codes: [String] = []
        func add(_ raw: String?) {
            guard var raw, !raw.isEmpty, raw != "current" else { return }
            if let at = raw.firstIndex(of: "@") {
                raw = String(raw[..<at])
            }
            if !codes.contains(raw) {
                codes.append(raw)
            }
            let base = raw.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init)
            if let base, base != raw, !codes.contains(base) {
                codes.append(base)
            }
        }

        let identifier = locale.identifier
        let followsSystem = identifier.isEmpty || identifier == "current" || identifier == Locale.autoupdatingCurrent.identifier
        if followsSystem {
            for language in Locale.preferredLanguages.prefix(3) {
                add(language)
            }
        }
        if identifier.isEmpty || identifier == "current" {
            add(Locale.current.identifier)
        } else {
            add(identifier)
        }
        add(locale.language.languageCode?.identifier)
        return codes
    }

    private static var tables: [String: [String: String]] = [:]
    private static let tablesLock = NSLock()

    private static func stringsTable(at lprojPath: String) -> [String: String]? {
        tablesLock.lock()
        if let cached = tables[lprojPath] {
            tablesLock.unlock()
            return cached
        }
        tablesLock.unlock()

        let url = URL(fileURLWithPath: lprojPath, isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        guard let data = try? Data(contentsOf: url),
              let parsed = loadTable(from: data) else {
            return nil
        }
        tablesLock.lock()
        tables[lprojPath] = parsed
        tablesLock.unlock()
        return parsed
    }

    private static func loadTable(from data: Data) -> [String: String]? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let table = stringTable(from: plist) {
            return table
        }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
           text.contains("=") {
            let parsed = parseStrings(text)
            if !parsed.isEmpty { return parsed }
        }
        return nil
    }

    private static func stringTable(from plist: Any) -> [String: String]? {
        guard let raw = plist as? [String: Any] else { return nil }
        var table: [String: String] = [:]
        for (key, value) in raw {
            if let string = value as? String, !string.isEmpty {
                table[key] = string
            }
        }
        return table.isEmpty ? nil : table
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
