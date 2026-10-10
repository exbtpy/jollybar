import AppKit
import SwiftUI

/// Jollybar color system. Dark is the primary appearance; light uses the same
/// cream, teal, and mood colors on a warm paper background.
enum JollyTheme {
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(_ redByte: Int, _ greenByte: Int, _ blueByte: Int) {
            red = Double(redByte) / 255
            green = Double(greenByte) / 255
            blue = Double(blueByte) / 255
        }

        var color: Color {
            Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
        }

        var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
    }

    static let ink = RGB(0x0E, 0x14, 0x16)
    static let card = RGB(0x17, 0x20, 0x22)
    static let cream = RGB(0xFF, 0xF4, 0xE0)
    static let teal = RGB(0x2E, 0xC4, 0xB6)
    static let deepTeal = RGB(0x13, 0x8A, 0x7E)
    /// Warm paper for light appearance. The cream stage still sits on top of it.
    static let paper = RGB(0xF3, 0xEE, 0xE4)
    static let paperCard = RGB(0xFF, 0xFB, 0xF4)

    static let steady = RGB(0xF2, 0xC1, 0x4E)
    static let tired = RGB(0xF2, 0x8C, 0x38)
    static let worried = RGB(0xF2, 0x54, 0x5B)
    static let asleep = RGB(0x8E, 0x8C, 0xD8)
    /// Waiting, not a mood. Kept out of the menu-bar tint.
    static let waiting = RGB(0x8A, 0x96, 0x94)

    /// Menu bar stays neutral below this used percent and takes the mood color from here up.
    static let menuTintThreshold: Double = 70

    static func moodRGB(_ mood: CompanionMood) -> RGB {
        switch mood {
        case .playful: return teal
        case .steady: return steady
        case .tired: return tired
        case .worried: return worried
        case .asleep: return asleep
        case .unknown: return waiting
        }
    }

    static func menuUsesMoodTint(usedPercent: Double?) -> Bool {
        guard let usedPercent, usedPercent.isFinite else { return false }
        return usedPercent >= menuTintThreshold
    }

    /// Nil keeps the menu-bar image a template so the system can grey it.
    static func menuTint(mood: CompanionMood, usedPercent: Double?) -> RGB? {
        guard mood != .unknown, menuUsesMoodTint(usedPercent: usedPercent) else { return nil }
        return moodRGB(mood)
    }

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? ink.color : paper.color
    }

    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? card.color : paperCard.color
    }

    static func primaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? cream.color : ink.color
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? cream.color.opacity(0.62) : ink.color.opacity(0.58)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    static func track(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    /// Faint wash behind the hero meter. About 6% of the current mood.
    static func moodWash(_ mood: CompanionMood) -> Color {
        moodRGB(mood).color.opacity(0.06)
    }
}

enum JollyType {
    static func rounded(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

enum MotionPolicy {
    static func allowsMotion(reduceMotion: Bool, lowPower: Bool) -> Bool {
        !reduceMotion && !lowPower
    }
}

enum UsagePercentStyle: String, CaseIterable, Identifiable {
    case used
    case left

    var id: String { rawValue }

    static let defaultsKey = "usagePercentStyle"

    var settingsTitle: String {
        switch self {
        case .used: return L10n.text("percent.used", "Used")
        case .left: return L10n.text("percent.left", "Left")
        }
    }
}

enum UsageChartMode: String, CaseIterable, Identifiable {
    case sprout
    case history

    var id: String { rawValue }

    static let defaultsKey = "usageChartMode"
}

/// How the big number and the menu-bar number are spelled.
enum UsageNumber {
    /// Menu bar always shows used percent, so a tinted "20%" cannot mean "20% left".
    static func menuText(usedPercent: Double?) -> String {
        guard let rounded = roundedUsed(usedPercent) else { return "—" }
        return "\(rounded)%"
    }

    static func heroText(usedPercent: Double?, style: UsagePercentStyle) -> String {
        guard let rounded = roundedUsed(usedPercent) else { return "—" }
        switch style {
        case .used:
            return "\(rounded)%"
        case .left:
            return "\(max(0, 100 - min(rounded, 100)))%"
        }
    }

    static func roundedUsed(_ usedPercent: Double?) -> Int? {
        guard let usedPercent, usedPercent.isFinite, usedPercent >= 0 else { return nil }
        return Int(round(min(usedPercent, 999)))
    }
}
