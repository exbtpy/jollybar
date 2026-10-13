import SwiftUI

/// One painted frame of the menu-bar Bud. Values are already quantized.
struct CompanionMenuFrame: Equatable {
    var eyeOpen: CGFloat
    var breathe: CGFloat
    var wiggle: CGFloat
    var celebrate: CGFloat

    static let rest = CompanionMenuFrame(eyeOpen: 1, breathe: 0, wiggle: 0, celebrate: 0)
}

/// Pure timing for the menu-bar Bud. A breath is one short clip, then a gap
/// with no timer. Blink sits inside the breath. Wiggle and the reset hop are
/// separate clips that can overlap it.
enum CompanionMenuMotion {
    static let breatheDuration = 1.6
    static let blinkStart = 0.50
    static let blinkEnd = 0.82
    static let wiggleDuration = 0.42
    static let celebrateDuration = 0.70
    static let idleGap = 3.2
    static let frameInterval = 0.1

    static let seenWindowKey = "menuBarLastSeenUsageWindowStart"
    static let celebratedWindowKey = "menuBarLastCelebratedUsageWindowStart"

    /// Elapsed times are seconds from the start of each clip. Nil means that clip is off.
    /// The Bool is true while any clip still has time left.
    static func frame(
        breatheElapsed: TimeInterval?,
        wiggleElapsed: TimeInterval?,
        celebrateElapsed: TimeInterval?
    ) -> (CompanionMenuFrame, Bool) {
        var frame = CompanionMenuFrame.rest
        var animating = false

        if let elapsed = breatheElapsed, elapsed >= 0, elapsed < breatheDuration {
            animating = true
            let unit = elapsed / breatheDuration
            frame.breathe = CGFloat(sin(unit * .pi))
            if elapsed >= blinkStart && elapsed <= blinkEnd {
                let span = blinkEnd - blinkStart
                let mid = blinkStart + span / 2
                let closed = 1 - abs(elapsed - mid) / (span / 2)
                frame.eyeOpen = CGFloat(max(0, 1 - closed))
            }
        }

        if let elapsed = wiggleElapsed, elapsed >= 0, elapsed < wiggleDuration {
            animating = true
            let unit = elapsed / wiggleDuration
            frame.wiggle = CGFloat(sin(unit * 2 * .pi) * (1 - unit) * 8)
        }

        if let elapsed = celebrateElapsed, elapsed >= 0, elapsed < celebrateDuration {
            animating = true
            let unit = elapsed / celebrateDuration
            frame.celebrate = CGFloat(sin(unit * .pi))
        }

        return (quantize(frame), animating)
    }

    /// True when this window should play the hop. The keys are separate from the
    /// popover celebration. When motion is off the window is still recorded.
    static func claimCelebration(
        currentWindowStart: Date?,
        allowsMotion: Bool,
        defaults: UserDefaults
    ) -> Bool {
        let previous = date(defaults, key: seenWindowKey)
        let already = date(defaults, key: celebratedWindowKey)
        if let window = ResetCelebration.windowToCelebrate(
            previousWindowStart: previous,
            currentWindowStart: currentWindowStart,
            alreadyCelebrated: already
        ) {
            defaults.set(window.timeIntervalSince1970, forKey: celebratedWindowKey)
            defaults.set(window.timeIntervalSince1970, forKey: seenWindowKey)
            return allowsMotion
        }
        if let currentWindowStart {
            defaults.set(currentWindowStart.timeIntervalSince1970, forKey: seenWindowKey)
        }
        return false
    }

    private static func date(_ defaults: UserDefaults, key: String) -> Date? {
        guard let stored = defaults.object(forKey: key) as? Double, stored > 0 else { return nil }
        return Date(timeIntervalSince1970: stored)
    }

    private static func quantize(_ frame: CompanionMenuFrame) -> CompanionMenuFrame {
        CompanionMenuFrame(
            eyeOpen: step(frame.eyeOpen, 0.05),
            breathe: step(frame.breathe, 0.05),
            wiggle: step(frame.wiggle, 0.5),
            celebrate: step(frame.celebrate, 0.05)
        )
    }

    private static func step(_ value: CGFloat, _ step: CGFloat) -> CGFloat {
        (value / step).rounded() * step
    }
}

/// Timers live on the main run loop and only while a clip is playing.
/// Not isolated to the main actor: the menu-bar label calls it from the main thread.
final class MenuBarCompanionMotion: ObservableObject {
    @Published private(set) var frame: CompanionMenuFrame = .rest

    private var ticker: Timer?
    private var waiter: Timer?
    private var breatheStarted: Date?
    private var wiggleStarted: Date?
    private var celebrateStarted: Date?
    private var allowsMotion = true
    private var configured = false
    private var sawUsage = false
    private var lastPercent: Int?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        ticker?.invalidate()
        waiter?.invalidate()
    }

    func setAllowsMotion(_ allows: Bool) {
        let changed = !configured || allowsMotion != allows
        configured = true
        allowsMotion = allows
        guard changed else { return }
        if !allows {
            stopTimers()
            breatheStarted = nil
            wiggleStarted = nil
            celebrateStarted = nil
            publish(.rest)
        } else if ticker == nil && waiter == nil {
            armIdle(after: 1.2)
        }
    }

    /// The first note never wiggles. Later changes of the rounded percent do.
    func noteUsagePercent(_ percent: Int?) {
        defer {
            sawUsage = true
            lastPercent = percent
        }
        guard allowsMotion, sawUsage, let percent, percent != lastPercent else { return }
        wiggleStarted = Date()
        cancelWaiter()
        ensureTicker()
    }

    func noteResetWindow(_ start: Date?) {
        guard CompanionMenuMotion.claimCelebration(
            currentWindowStart: start,
            allowsMotion: allowsMotion,
            defaults: defaults
        ) else { return }
        celebrateStarted = Date()
        cancelWaiter()
        ensureTicker()
    }

    func stop() {
        stopTimers()
        breatheStarted = nil
        wiggleStarted = nil
        celebrateStarted = nil
        configured = false
    }

    private func armIdle(after delay: TimeInterval) {
        guard allowsMotion, ticker == nil, waiter == nil else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.waiter = nil
            self.beginBreath()
        }
        waiter = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func beginBreath() {
        guard allowsMotion else { return }
        breatheStarted = Date()
        ensureTicker()
    }

    private func ensureTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: CompanionMenuMotion.frameInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        let now = Date()
        let breathe = breatheStarted.map { now.timeIntervalSince($0) }
        let wiggle = wiggleStarted.map { now.timeIntervalSince($0) }
        let celebrate = celebrateStarted.map { now.timeIntervalSince($0) }
        let (next, _) = CompanionMenuMotion.frame(
            breatheElapsed: breathe,
            wiggleElapsed: wiggle,
            celebrateElapsed: celebrate
        )
        if let breathe, breathe >= CompanionMenuMotion.breatheDuration {
            breatheStarted = nil
        }
        if let wiggle, wiggle >= CompanionMenuMotion.wiggleDuration {
            wiggleStarted = nil
        }
        if let celebrate, celebrate >= CompanionMenuMotion.celebrateDuration {
            celebrateStarted = nil
        }
        publish(next)
        if breatheStarted == nil && wiggleStarted == nil && celebrateStarted == nil {
            stopTicker()
            publish(.rest)
            armIdle(after: CompanionMenuMotion.idleGap)
        }
    }

    private func publish(_ next: CompanionMenuFrame) {
        if next != frame {
            frame = next
        }
    }

    private func cancelWaiter() {
        waiter?.invalidate()
        waiter = nil
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func stopTimers() {
        cancelWaiter()
        stopTicker()
    }
}

struct MenuBarCompanionItem: View {
    let mood: CompanionMood
    let usedPercent: Double?
    let usageWindowStart: Date?
    var moment: BudMomentPose = .rest
    var momentActive: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var power = PowerState()
    @StateObject private var motion = MenuBarCompanionMotion()

    var body: some View {
        let text = UsageNumber.menuText(usedPercent: usedPercent)
        let fraction = MenuBarMouth.fraction(usedPercent: usedPercent)
        Image(nsImage: renderCompanionMenuIcon(
            mood: mood,
            mouthFraction: fraction,
            frame: motion.frame,
            moment: moment,
            momentActive: momentActive
        ))
            .accessibilityLabel(accessibilityText(percent: text))
            .onAppear { syncMotion() }
            .onDisappear { motion.stop() }
            .onChange(of: reduceMotion) { _, _ in syncMotion() }
            .onChange(of: power.isLowPowerMode) { _, _ in syncMotion() }
            .onChange(of: usedPercent) { _, newValue in
                motion.noteUsagePercent(UsageNumber.roundedUsed(newValue))
            }
            .onChange(of: usageWindowStart) { _, newValue in
                motion.noteResetWindow(newValue)
            }
    }

    private func syncMotion() {
        let allows = MotionPolicy.allowsMotion(
            reduceMotion: reduceMotion,
            lowPower: power.isLowPowerMode
        )
        motion.setAllowsMotion(allows)
        motion.noteUsagePercent(UsageNumber.roundedUsed(usedPercent))
        motion.noteResetWindow(usageWindowStart)
    }

    private func accessibilityText(percent: String) -> String {
        if percent == "—" {
            return "\(AppIdentity.companionName), \(mood.caption)"
        }
        return "\(AppIdentity.companionName), \(percent), \(mood.caption)"
    }
}
