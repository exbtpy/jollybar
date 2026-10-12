import AppKit
import Combine
import Foundation
import SwiftUI

/// One rare menu-bar clip. Each plays once, under two seconds, and does not loop.
enum BudMomentKind: String, Equatable, CaseIterable {
    case morningHello
    case worried
    case tired
    case resetDay
    case hoverPeek

    var snapshotName: String {
        switch self {
        case .morningHello: return "morning-hello"
        case .worried: return "worried"
        case .tired: return "tired"
        case .resetDay: return "reset-day"
        case .hoverPeek: return "hover-peek"
        }
    }
}

/// How the glyph poses during a moment. Rest matches the drawing the menu bar
/// already uses, so a finished clip does not leave the face mid-blink.
struct BudMomentPose: Equatable {
    var eyeOpen: CGFloat = 1
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var hop: CGFloat = 0
    var yawn: CGFloat = 0
    var sweat: CGFloat = 0
    var glance: CGFloat = 0

    static let rest = BudMomentPose()
}

enum BudMomentStore {
    /// Absent means on. `@AppStorage` reads the property default when the key is missing.
    static let enabledKey = "budMomentsEnabled"
    static let morningDay = "budMomentMorningDay"
    static let mood = "budMomentLastMood"
    static let percent = "budMomentLastPercent"
    static let seenWindow = "budMomentSeenWindow"
    static let celebratedWindow = "budMomentCelebratedWindow"
}

/// Pure gates. The player records the returned day, mood, and window even when
/// motion is off, so a skipped clip does not play later the same day.
enum BudMomentGate {
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The first mark on a calendar day is due. Later marks that day are not.
    static func claimOncePerDay(now: Date, calendar: Calendar, storedDayKey: String?) -> (due: Bool, dayKey: String) {
        let key = dayKey(for: now, calendar: calendar)
        return (key != storedDayKey, key)
    }

    /// Worried and tired react only when the tier changes into them.
    static func moodReaction(from previous: CompanionMood?, to current: CompanionMood) -> BudMomentKind? {
        guard let previous, previous != current else { return nil }
        switch current {
        case .worried: return .worried
        case .tired: return .tired
        default: return nil
        }
    }

    /// True when there is no earlier mark, or `now` is at least `interval` after it.
    static func claimThrottle(now: Date, last: Date?, interval: TimeInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// A weekly counter falling by `threshold` points or more. Nil is not a drop.
    static func sharpDrop(from previous: Double?, to current: Double?, threshold: Double) -> Bool {
        guard let previous, let current, previous.isFinite, current.isFinite else { return false }
        return previous - current >= threshold
    }
}

/// Remembered triggers. Playback fields are not persisted.
struct BudMomentState: Equatable {
    var morningDayKey: String?
    var mood: CompanionMood?
    var lastPercent: Double?
    var seenWindow: Date?
    var celebratedWindow: Date?
    var lastHover: Date?
    var playing: BudMomentKind?
    var startedAt: Date?
    var pending: BudMomentKind?

    static func load(from defaults: UserDefaults) -> BudMomentState {
        var state = BudMomentState()
        if let day = defaults.string(forKey: BudMomentStore.morningDay), !day.isEmpty {
            state.morningDayKey = day
        }
        if let raw = defaults.string(forKey: BudMomentStore.mood) {
            state.mood = CompanionMood(rawValue: raw)
        }
        if let number = defaults.object(forKey: BudMomentStore.percent) as? NSNumber {
            let value = number.doubleValue
            if value.isFinite {
                state.lastPercent = value
            }
        }
        state.seenWindow = date(defaults, key: BudMomentStore.seenWindow)
        state.celebratedWindow = date(defaults, key: BudMomentStore.celebratedWindow)
        return state
    }

    func save(to defaults: UserDefaults) {
        if let morningDayKey {
            defaults.set(morningDayKey, forKey: BudMomentStore.morningDay)
        }
        if let mood {
            defaults.set(mood.rawValue, forKey: BudMomentStore.mood)
        }
        if let lastPercent {
            defaults.set(lastPercent, forKey: BudMomentStore.percent)
        }
        if let seenWindow {
            defaults.set(seenWindow.timeIntervalSince1970, forKey: BudMomentStore.seenWindow)
        }
        if let celebratedWindow {
            defaults.set(celebratedWindow.timeIntervalSince1970, forKey: BudMomentStore.celebratedWindow)
        }
    }

    private static func date(_ defaults: UserDefaults, key: String) -> Date? {
        guard let stored = defaults.object(forKey: key) as? Double, stored > 0 else { return nil }
        return Date(timeIntervalSince1970: stored)
    }
}

enum BudMomentEvent: Equatable {
    /// First launch of the day, wake from sleep, or screen unlock.
    case dayMark(now: Date)
    case mood(CompanionMood)
    case usage(percent: Double?, windowStart: Date?)
    case hover(now: Date)
}

/// One clip at a time, plus a single queued clip. Nothing here repeats.
enum BudMomentMachine {
    static func reduce(
        state: BudMomentState,
        event: BudMomentEvent,
        allows: Bool,
        now: Date,
        calendar: Calendar
    ) -> BudMomentState {
        var state = state
        switch event {
        case .dayMark(let mark):
            let claim = BudMomentGate.claimOncePerDay(now: mark, calendar: calendar, storedDayKey: state.morningDayKey)
            guard claim.due else { return state }
            state.morningDayKey = claim.dayKey
            enqueue(.morningHello, state: &state, allows: allows, now: now)
        case .mood(let mood):
            if let kind = BudMomentGate.moodReaction(from: state.mood, to: mood) {
                enqueue(kind, state: &state, allows: allows, now: now)
            }
            state.mood = mood
        case .usage(let percent, let window):
            let newWindow = ResetCelebration.windowToCelebrate(
                previousWindowStart: state.seenWindow,
                currentWindowStart: window,
                alreadyCelebrated: state.celebratedWindow
            )
            let dropped = BudMomentGate.sharpDrop(
                from: state.lastPercent,
                to: percent,
                threshold: BudMoments.sharpDrop
            )
            if let window {
                state.seenWindow = window
            }
            if let newWindow {
                state.celebratedWindow = newWindow
            }
            if let percent, percent.isFinite {
                state.lastPercent = percent
            }
            if newWindow != nil || dropped {
                enqueue(.resetDay, state: &state, allows: allows, now: now)
            }
        case .hover(let mark):
            guard BudMomentGate.claimThrottle(now: mark, last: state.lastHover, interval: BudMoments.hoverThrottle) else {
                return state
            }
            state.lastHover = mark
            enqueue(.hoverPeek, state: &state, allows: allows, now: now)
        }
        return state
    }

    /// Steps the clip. When it ends, a queued clip starts at `now`. Otherwise the pose is rest.
    static func advance(state: BudMomentState, now: Date) -> (BudMomentState, BudMomentPose) {
        var state = state
        guard let kind = state.playing, let started = state.startedAt else {
            return (state, .rest)
        }
        let elapsed = now.timeIntervalSince(started)
        if elapsed < 0 {
            return (state, BudMoments.pose(kind: kind, elapsed: 0).0)
        }
        let (current, animating) = BudMoments.pose(kind: kind, elapsed: elapsed)
        if animating {
            return (state, current)
        }
        state.playing = state.pending
        state.pending = nil
        if let next = state.playing {
            state.startedAt = now
            return (state, BudMoments.pose(kind: next, elapsed: 0).0)
        }
        state.startedAt = nil
        return (state, .rest)
    }

    private static func enqueue(_ kind: BudMomentKind, state: inout BudMomentState, allows: Bool, now: Date) {
        guard allows else { return }
        if state.playing == nil {
            state.playing = kind
            state.startedAt = now
            return
        }
        if state.playing == kind || state.pending == kind {
            return
        }
        if let pending = state.pending, rank(kind) <= rank(pending) {
            return
        }
        state.pending = kind
    }

    private static func rank(_ kind: BudMomentKind) -> Int {
        switch kind {
        case .hoverPeek: return 1
        case .tired, .worried: return 2
        case .morningHello, .resetDay: return 3
        }
    }
}

/// Frame curves for the clips. Ten frames a second, each clip under two seconds.
///
/// The blink and the reset hop follow robot-heads (Fayaz Ahmed, MIT): a blink is
/// one half-sine about 0.17s long, and a hop is a 0.11s crouch into `4·h·t·(1−t)`.
/// The pebble drawings are original.
enum BudMoments {
    static let frameInterval: TimeInterval = 0.1
    static let hoverThrottle: TimeInterval = 10
    /// Percentage points. Ordinary use does not fall this far between polls.
    static let sharpDrop: Double = 20
    static let blinkWidth: TimeInterval = 0.17
    static let crouch: TimeInterval = 0.11

    static func frameCount(_ kind: BudMomentKind) -> Int {
        switch kind {
        case .morningHello: return 16
        case .worried: return 12
        case .tired: return 14
        case .resetDay: return 9
        case .hoverPeek: return 5
        }
    }

    static func duration(_ kind: BudMomentKind) -> TimeInterval {
        TimeInterval(frameCount(kind)) * frameInterval
    }

    /// Elapsed seconds from the start of the clip. The Bool is false once the clip is over.
    static func pose(kind: BudMomentKind, elapsed: TimeInterval) -> (BudMomentPose, Bool) {
        guard elapsed >= 0, elapsed < duration(kind) else {
            return (.rest, false)
        }
        let raw: BudMomentPose
        switch kind {
        case .morningHello: raw = morning(elapsed)
        case .worried: raw = worried(elapsed)
        case .tired: raw = tired(elapsed)
        case .resetDay: raw = reset(elapsed)
        case .hoverPeek: raw = hover(elapsed)
        }
        return (quantize(raw), true)
    }

    static func frames(_ kind: BudMomentKind) -> [BudMomentPose] {
        (0..<frameCount(kind)).map { index in
            pose(kind: kind, elapsed: TimeInterval(index) * frameInterval).0
        }
    }

    /// Eyes start shut, open, stretch, then blink once.
    private static func morning(_ t: TimeInterval) -> BudMomentPose {
        var pose = BudMomentPose.rest
        let wake = 0.25
        if t < wake {
            pose.eyeOpen = 0
        } else if t < wake + blinkWidth {
            let unit = (t - wake) / blinkWidth
            pose.eyeOpen = CGFloat(sin(unit * .pi / 2))
        } else {
            pose.eyeOpen = 1 - blinkShut(at: t, start: 1.15)
        }
        if t >= 0.45 && t <= 1.20 {
            let unit = (t - 0.45) / (1.20 - 0.45)
            let arch = CGFloat(sin(unit * .pi))
            pose.scaleY = 1 + 0.10 * arch
            pose.scaleX = 1 - 0.05 * arch
        }
        return pose
    }

    /// One blink, then a drop that falls beside the face.
    private static func worried(_ t: TimeInterval) -> BudMomentPose {
        var pose = BudMomentPose.rest
        pose.eyeOpen = 1 - blinkShut(at: t, start: 0.08)
        if t >= 0.20 && t <= 1.05 {
            pose.sweat = CGFloat((t - 0.20) / (1.05 - 0.20))
        }
        return pose
    }

    /// The mouth opens and the eyes droop, then both settle.
    private static func tired(_ t: TimeInterval) -> BudMomentPose {
        var pose = BudMomentPose.rest
        if t >= 0.15 && t <= 1.25 {
            let unit = (t - 0.15) / (1.25 - 0.15)
            pose.yawn = CGFloat(sin(unit * .pi))
        }
        pose.eyeOpen = max(0.2, 1 - 0.7 * pose.yawn)
        return pose
    }

    /// Crouch, a single parabola hop, then a short landing squash.
    private static func reset(_ t: TimeInterval) -> BudMomentPose {
        var pose = BudMomentPose.rest
        let height: CGFloat = 0.10
        let air: TimeInterval = 0.48
        if t < crouch {
            let squash = CGFloat(sin((t / crouch) * .pi))
            pose.scaleX = 1 + 0.08 * squash
            pose.scaleY = 1 - 0.06 * squash
        } else {
            let along = (t - crouch) / air
            if along < 1 {
                pose.hop = 4 * height * CGFloat(along * (1 - along))
                if along < 0.45 {
                    pose.scaleX = 0.98
                    pose.scaleY = 1.02
                }
            } else {
                let land = min(1, (t - crouch - air) / 0.22)
                let squash = CGFloat(sin(land * .pi))
                pose.scaleX = 1 + 0.06 * squash
                pose.scaleY = 1 - 0.05 * squash
            }
        }
        return pose
    }

    /// One blink and a glance out and back. The caller throttles repeats.
    private static func hover(_ t: TimeInterval) -> BudMomentPose {
        var pose = BudMomentPose.rest
        pose.eyeOpen = 1 - blinkShut(at: t, start: 0.04)
        let unit = min(1, max(0, t / 0.48))
        pose.glance = CGFloat(sin(unit * .pi)) * 0.85
        return pose
    }

    /// 1 is shut. Outside the 0.17s window the value is 0.
    private static func blinkShut(at elapsed: TimeInterval, start: TimeInterval) -> CGFloat {
        let age = elapsed - start
        guard age >= 0, age <= blinkWidth else { return 0 }
        return CGFloat(sin((age / blinkWidth) * .pi))
    }

    private static func quantize(_ pose: BudMomentPose) -> BudMomentPose {
        BudMomentPose(
            eyeOpen: clamp(step(pose.eyeOpen, 0.05), 0, 1),
            scaleX: clamp(step(pose.scaleX, 0.01), 0.8, 1.25),
            scaleY: clamp(step(pose.scaleY, 0.01), 0.8, 1.25),
            hop: clamp(step(pose.hop, 0.01), 0, 0.35),
            yawn: clamp(step(pose.yawn, 0.05), 0, 1),
            sweat: clamp(step(pose.sweat, 0.05), 0, 1),
            glance: clamp(step(pose.glance, 0.05), -1, 1)
        )
    }

    private static func step(_ value: CGFloat, _ step: CGFloat) -> CGFloat {
        (value / step).rounded() * step
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(high, max(low, value))
    }
}

/// Timers run on the main run loop only while a clip is playing.
/// Not isolated to the main actor: the menu-bar label calls it from the main thread.
final class BudMomentPlayer: ObservableObject {
    @Published private(set) var pose: BudMomentPose = .rest
    @Published private(set) var isPlaying = false

    private var state: BudMomentState
    private var allows = false
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let schedulesTimers: Bool
    private var ticker: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        watchWorkspace: Bool = true,
        schedulesTimers: Bool = true
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.schedulesTimers = schedulesTimers
        self.state = BudMomentState.load(from: defaults)
        if watchWorkspace {
            observeWorkspace()
        }
    }

    deinit {
        ticker?.invalidate()
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspace.removeObserver(observer)
        }
        let distributed = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            distributed.removeObserver(observer)
        }
    }

    func setAllowsMoments(_ allows: Bool) {
        let changed = self.allows != allows
        self.allows = allows
        guard changed, !allows else { return }
        state.playing = nil
        state.pending = nil
        state.startedAt = nil
        stopTicker()
        publish(.rest)
    }

    func noteDayMark(now: Date = Date()) {
        apply(.dayMark(now: now), now: now)
    }

    func noteMood(_ mood: CompanionMood, now: Date = Date()) {
        apply(.mood(mood), now: now)
    }

    func noteUsage(percent: Double?, windowStart: Date?, now: Date = Date()) {
        apply(.usage(percent: percent, windowStart: windowStart), now: now)
    }

    func noteHover(now: Date = Date()) {
        apply(.hover(now: now), now: now)
    }

    /// Steps the clip without waiting for the timer. Tests use this.
    func advance(to now: Date) {
        let (next, pose) = BudMomentMachine.advance(state: state, now: now)
        state = next
        publish(pose)
        if state.playing == nil {
            stopTicker()
        }
    }

    func stop() {
        state.playing = nil
        state.pending = nil
        state.startedAt = nil
        stopTicker()
        publish(.rest)
    }

    private func apply(_ event: BudMomentEvent, now: Date) {
        // Finish a clip that has already run out before accepting the new event,
        // so a later hover is not swallowed by a clip the timer has not stepped yet.
        let (caughtUp, _) = BudMomentMachine.advance(state: state, now: now)
        state = caughtUp
        state = BudMomentMachine.reduce(
            state: state,
            event: event,
            allows: allows,
            now: now,
            calendar: calendar
        )
        state.save(to: defaults)
        advance(to: now)
        if state.playing != nil {
            ensureTicker()
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ]
        for name in names {
            workspaceObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.noteDayMark()
                }
            )
        }
        distributedObservers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.noteDayMark()
            }
        )
    }

    private func ensureTicker() {
        guard schedulesTimers, ticker == nil else { return }
        let timer = Timer(timeInterval: BudMoments.frameInterval, repeats: true) { [weak self] _ in
            self?.advance(to: Date())
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func publish(_ next: BudMomentPose) {
        let playing = state.playing != nil
        if next != pose {
            pose = next
        }
        if playing != isPlaying {
            isPlaying = playing
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

/// Mouse enter on the status item. Clicks pass through to the menu-bar button.
struct MenuBarHoverCatcher: NSViewRepresentable {
    var onEnter: () -> Void

    func makeNSView(context: Context) -> HoverCatcher {
        let view = HoverCatcher()
        view.onEnter = onEnter
        return view
    }

    func updateNSView(_ nsView: HoverCatcher, context: Context) {
        nsView.onEnter = onEnter
    }

    final class HoverCatcher: NSView {
        var onEnter: (() -> Void)?

        override var isOpaque: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        override func mouseEntered(with event: NSEvent) {
            onEnter?()
        }
    }
}
