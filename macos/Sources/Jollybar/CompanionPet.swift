import AppKit
import SwiftUI

/// Original menu-bar companion. It is a pebble with one leaf, not a cup and
/// not a product logo. The pose follows Grok Bot weekly usage.
enum CompanionMood: String {
    case playful
    case steady
    case tired
    case worried
    case asleep
    case unknown

    static func resolve(usedPercent: Double?, pausedAtLimit: Bool) -> CompanionMood {
        if pausedAtLimit { return .asleep }
        guard let usedPercent, usedPercent.isFinite, usedPercent >= 0 else { return .unknown }
        if usedPercent >= 100 { return .asleep }
        if usedPercent >= 90 { return .worried }
        if usedPercent >= 75 { return .tired }
        if usedPercent >= 50 { return .steady }
        return .playful
    }

    var caption: String {
        switch self {
        case .playful: return L10n.text("mood.playful", "Energetic")
        case .steady: return L10n.text("mood.steady", "Steady")
        case .tired: return L10n.text("mood.tired", "Tired")
        case .worried: return L10n.text("mood.worried", "Near the limit")
        case .asleep: return L10n.text("mood.asleep", "Asleep")
        case .unknown: return L10n.text("mood.unknown", "Waiting for Grok Bot")
        }
    }

    var accessibilityLabel: String {
        "\(AppIdentity.companionName), \(caption)"
    }

    /// The mouth that belongs with this label. A smile bows downward.
    var mouth: MouthCurve {
        switch self {
        case .playful: return .smile
        case .steady: return .softSmile
        case .tired, .unknown, .asleep: return .flat
        case .worried: return .frown
        }
    }

    var accent: Color { JollyTheme.moodRGB(self).color }
}

/// Worried brows only. Positive degrees are clockwise, which drops the left
/// brow's inner end and looks angry. The left brow turns the other way so both
/// inner ends lift. No other mood draws brows.
enum BudBrows {
    static func degrees(mirrored: Bool) -> Double {
        mirrored ? 18 : -18
    }

    /// How far above the eye the brow sits. Higher than the old scowl.
    static let lift: CGFloat = 12
}

/// How far the mouth bows, as a fraction of its box.
/// Above 0.5 the control point is below the corners: a smile.
/// Below 0.5 it is above the corners: a frown. 0.5 is a flat line.
enum MouthCurve: Equatable {
    case smile
    case softSmile
    case flat
    case frown

    var depth: CGFloat {
        switch self {
        case .smile: return 1
        case .softSmile: return 0.72
        case .flat: return 0.5
        case .frown: return 0
        }
    }
}

struct CompanionMouth: Shape {
    var curve: MouthCurve

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if curve == .flat {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
        let smiling = curve.depth > 0.5
        let cornerY = smiling ? rect.minY : rect.maxY
        let controlY = rect.minY + rect.height * curve.depth
        path.move(to: CGPoint(x: rect.minX, y: cornerY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: cornerY),
            control: CGPoint(x: rect.midX, y: controlY)
        )
        return path
    }
}

enum MenuTheme: String {
    case classic
    case companion

    static let defaultsKey = "menuTheme"
    static let defaultTheme = MenuTheme.companion
}

/// Pointed leaf from the sprout on Bud's head. Also the pace marker.
struct BudLeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.midY * 0.85 + rect.minY * 0.15)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.midY)
        )
        path.closeSubpath()
        return path
    }
}

struct BudHeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.minY + rect.height * 0.28
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: top),
            control1: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY * 0.62 + rect.minY * 0.38),
            control2: CGPoint(x: rect.minX, y: rect.midY)
        )
        path.addArc(
            center: CGPoint(x: rect.minX + rect.width * 0.28, y: top),
            radius: rect.width * 0.24,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addArc(
            center: CGPoint(x: rect.minX + rect.width * 0.72, y: top),
            radius: rect.width * 0.24,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.midY),
            control2: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.maxY * 0.62 + rect.minY * 0.38)
        )
        path.closeSubpath()
        return path
    }
}

/// Bud at popover size. `eyeOpen` is 1 awake and near 0 in a blink.
/// Tired keeps a heavy lid. Asleep stays closed and shows a z.
struct BudFigure: View {
    var mood: CompanionMood
    var eyeOpen: CGFloat = 1

    private var ink: Color { JollyTheme.ink.color }
    private var moodColor: Color { mood.accent }

    var body: some View {
        ZStack {
            Ellipse()
                .fill(ink.opacity(0.10))
                .frame(width: 46, height: 8)
                .offset(y: 36)
            sprout
                .offset(y: -34)
            bodyShape
            cheeks
            eyes
                .offset(y: -6)
            mouth
                .offset(y: 12)
            if mood == .asleep {
                sleepMarks
                    .offset(x: 28, y: -30)
            }
        }
        .frame(width: 88, height: 88)
        .accessibilityLabel(mood.accessibilityLabel)
    }

    private var sprout: some View {
        ZStack {
            Capsule()
                .fill(JollyTheme.deepTeal.color)
                .frame(width: 3, height: 12)
                .offset(y: 8)
            BudLeafShape()
                .fill(JollyTheme.teal.color)
                .frame(width: 16, height: 22)
                .rotationEffect(.degrees(-28))
                .overlay(
                    Capsule()
                        .fill(JollyTheme.cream.color.opacity(0.7))
                        .frame(width: 1.4, height: 10)
                        .rotationEffect(.degrees(-28))
                )
                .offset(x: 5, y: -2)
        }
        .frame(width: 28, height: 28)
    }

    private var bodyShape: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(JollyTheme.cream.color)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(moodColor.opacity(mood == .asleep ? 0.22 : 0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(moodColor, lineWidth: 2.4)
            )
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 22, height: 7)
                    .offset(y: 8)
            }
            .frame(width: 64, height: 54)
    }

    @ViewBuilder
    private var cheeks: some View {
        if mood == .playful || mood == .steady {
            HStack(spacing: 22) {
                cheek
                cheek
            }
            .offset(y: 4)
        }
    }

    private var cheek: some View {
        Ellipse()
            .fill(moodColor.opacity(0.38))
            .frame(width: 8, height: 5)
    }

    @ViewBuilder
    private var eyes: some View {
        switch mood {
        case .asleep:
            HStack(spacing: 12) {
                closedEye
                closedEye
            }
        case .tired:
            HStack(spacing: 12) {
                tiredEye
                tiredEye
            }
            .scaleEffect(x: 1, y: max(0.35, eyeOpen), anchor: .center)
        case .worried:
            HStack(spacing: 12) {
                worriedEye(mirrored: false)
                worriedEye(mirrored: true)
            }
            .scaleEffect(x: 1, y: max(0.12, eyeOpen), anchor: .center)
        case .playful:
            HStack(spacing: 14) {
                openEye(diameter: 9)
                openEye(diameter: 9)
            }
            .scaleEffect(x: 1, y: max(0.12, eyeOpen), anchor: .center)
        case .steady, .unknown:
            HStack(spacing: 14) {
                openEye(diameter: 7)
                openEye(diameter: 7)
            }
            .scaleEffect(x: 1, y: max(0.12, eyeOpen), anchor: .center)
        }
    }

    private func openEye(diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(ink)
                .frame(width: diameter, height: diameter)
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: diameter * 0.28, height: diameter * 0.28)
                .offset(x: -diameter * 0.16, y: -diameter * 0.16)
        }
    }

    private func worriedEye(mirrored: Bool) -> some View {
        ZStack(alignment: .top) {
            openEye(diameter: 11)
            Capsule()
                .fill(ink.opacity(0.8))
                .frame(width: 9, height: 1.6)
                .rotationEffect(.degrees(BudBrows.degrees(mirrored: mirrored)))
                .offset(x: mirrored ? 2 : -2, y: -BudBrows.lift)
        }
    }

    private var tiredEye: some View {
        ZStack {
            Capsule()
                .fill(ink.opacity(0.85))
                .frame(width: 12, height: 5.5)
            Capsule()
                .fill(ink)
                .frame(width: 12, height: 2.2)
                .offset(y: -1.6)
        }
    }

    private var closedEye: some View {
        CompanionMouth(curve: .softSmile)
            .stroke(ink.opacity(0.85), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: 11, height: 6)
    }

    private var mouth: some View {
        let wide = mood == .playful
        return CompanionMouth(curve: mood.mouth)
            .stroke(ink.opacity(0.88), style: StrokeStyle(lineWidth: wide ? 2.2 : 1.8, lineCap: .round))
            .frame(width: wide ? 20 : 13, height: mood.mouth == .flat ? 4 : 9)
    }

    private var sleepMarks: some View {
        HStack(alignment: .bottom, spacing: 1) {
            Text("z")
                .font(.system(size: 8, weight: .bold, design: .rounded))
            Text("z")
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(JollyTheme.asleep.color)
    }
}

/// A 12pt face so the sprout chart can mark today without a second drawing style.
struct BudMarker: View {
    var mood: CompanionMood

    var body: some View {
        BudFigure(mood: mood, eyeOpen: 1)
            .scaleEffect(14 / 88)
            .frame(width: 14, height: 14)
            .clipped()
    }
}

/// Reports whether the hosting menu-bar window is on screen. The pet timeline
/// stops when the popover closes.
struct PopoverWindowVisible: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> WindowWatchView {
        let view = WindowWatchView()
        view.onChange = { isVisible = $0 }
        return view
    }

    func updateNSView(_ nsView: WindowWatchView, context: Context) {
        nsView.onChange = { isVisible = $0 }
    }

    final class WindowWatchView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else {
                onChange?(false)
                return
            }
            let refresh = { [weak self] in
                guard let self, let window = self.window else { return }
                let showing = window.isVisible && window.occlusionState.contains(NSWindow.OcclusionState.visible)
                self.onChange?(showing)
            }
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
            ]
            for name in names {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                        refresh()
                    }
                )
            }
            DispatchQueue.main.async(execute: refresh)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
