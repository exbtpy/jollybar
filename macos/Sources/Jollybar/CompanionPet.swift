import AppKit
import SwiftUI

/// Original menu-bar companion. It is a pebble with one leaf, not a cup and
/// not a product logo. The pose follows Grok Bot weekly usage. The accent
/// moves from calm teal, to amber, to red.
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
        case .playful: return "Energetic"
        case .steady: return "Steady"
        case .tired: return "Tired"
        case .worried: return "Near the limit"
        case .asleep: return "Asleep"
        case .unknown: return "Waiting for Grok Bot"
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

    var accent: Color {
        switch self {
        case .playful, .steady, .unknown:
            return Color(red: 0.20, green: 0.62, blue: 0.64)
        case .tired:
            return Color(red: 0.86, green: 0.56, blue: 0.16)
        case .worried, .asleep:
            return Color(red: 0.78, green: 0.28, blue: 0.30)
        }
    }
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
}

/// SwiftUI companion. The timeline runs only while `animating` is true.
struct CompanionPetView: View {
    let mood: CompanionMood
    var animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !animating)) { timeline in
            let phase = animating ? timeline.date.timeIntervalSinceReferenceDate : 0
            CompanionPetPose(mood: mood, phase: phase)
        }
        .accessibilityLabel(mood.accessibilityLabel)
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

struct CompanionPetPose: View {
    let mood: CompanionMood
    var phase: TimeInterval

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(mood.accent.opacity(mood == .asleep ? 0.16 : 0.28))
                    .frame(width: 78, height: 78)
                    .offset(y: 4)
                pebble
                    .offset(x: shake, y: bob)
            }
            .frame(width: 96, height: 88)
            Text(AppIdentity.companionName)
                .font(.caption.weight(.semibold))
            Text(mood.caption)
                .font(.caption2)
                .foregroundStyle(mood.accent)
        }
    }

    private var pebble: some View {
        ZStack {
            leaf
                .offset(x: 16, y: -30)
            Capsule(style: .continuous)
                .fill(bodyColor)
                .frame(width: 54, height: 46)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(mood.accent.opacity(0.9), lineWidth: 1.5)
                )
            eyes
                .offset(y: -4)
            mouth
                .offset(y: 10)
            HStack(spacing: 16) {
                Capsule().fill(mood.accent.opacity(0.85)).frame(width: 8, height: 6)
                Capsule().fill(mood.accent.opacity(0.85)).frame(width: 8, height: 6)
            }
            .offset(y: 26)
            if mood == .asleep {
                sleepMarks
                    .offset(x: 28, y: -24 + sleepDrift)
            }
        }
    }

    private var leaf: some View {
        Ellipse()
            .fill(Color(red: 0.35, green: 0.62, blue: 0.38))
            .frame(width: 14, height: 18)
            .rotationEffect(.degrees(-28))
            .overlay(
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 1.5, height: 10)
                    .rotationEffect(.degrees(-28))
            )
    }

    private var bodyColor: Color {
        mood == .asleep ? mood.accent.opacity(0.35) : mood.accent.opacity(0.55)
    }

    @ViewBuilder
    private var eyes: some View {
        switch mood {
        case .playful:
            HStack(spacing: 12) {
                eyeDot(size: 8, highlight: true)
                eyeDot(size: 8, highlight: true)
            }
        case .steady, .unknown:
            HStack(spacing: 12) {
                eyeDot(size: 6, highlight: false)
                eyeDot(size: 6, highlight: false)
            }
        case .tired:
            HStack(spacing: 12) {
                Capsule().fill(Color.black.opacity(0.75)).frame(width: 10, height: 3)
                Capsule().fill(Color.black.opacity(0.75)).frame(width: 10, height: 3)
            }
            .offset(y: 2)
        case .worried:
            HStack(spacing: 10) {
                eyeDot(size: 11, highlight: true)
                eyeDot(size: 11, highlight: true)
            }
        case .asleep:
            HStack(spacing: 12) {
                Capsule().fill(Color.black.opacity(0.7)).frame(width: 10, height: 2)
                Capsule().fill(Color.black.opacity(0.7)).frame(width: 10, height: 2)
            }
        }
    }

    private func eyeDot(size: CGFloat, highlight: Bool) -> some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.8)).frame(width: size, height: size)
            if highlight {
                Circle().fill(Color.white.opacity(0.9)).frame(width: size * 0.28, height: size * 0.28)
                    .offset(x: -size * 0.15, y: -size * 0.15)
            }
        }
    }

    private var mouth: some View {
        CompanionMouth(curve: mood.mouth)
            .stroke(Color.black.opacity(0.75), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: mood == .playful ? 16 : 12, height: mood.mouth == .flat ? 4 : 8)
    }

    private var sleepMarks: some View {
        HStack(spacing: 2) {
            Text("z")
            Text("z").font(.caption2)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(mood.accent)
    }

    private var bob: CGFloat {
        switch mood {
        case .playful:
            return CGFloat(sin(phase * 4)) * 4
        case .steady:
            return CGFloat(sin(phase * 1.2)) * 1.5
        case .tired:
            return 3
        case .worried:
            return 0
        case .asleep:
            return CGFloat(sin(phase * 0.8)) * 1
        case .unknown:
            return 0
        }
    }

    private var shake: CGFloat {
        mood == .worried ? CGFloat(sin(phase * 9)) * 1.4 : 0
    }

    private var sleepDrift: CGFloat {
        CGFloat(sin(phase * 1.4)) * 2
    }
}
