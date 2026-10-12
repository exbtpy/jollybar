import AppKit
import XCTest
@testable import Jollybar

final class BudMomentTests: XCTestCase {
    private let morning = Date(timeIntervalSince1970: 1_791_396_000) // 2026-10-07 18:00:00 UTC

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testClipsStayUnderTwoSecondsAtTenFrames() {
        XCTAssertEqual(BudMoments.frameInterval, 0.1)
        XCTAssertEqual(BudMoments.hoverThrottle, 10)
        for kind in BudMomentKind.allCases {
            let duration = BudMoments.duration(kind)
            XCTAssertGreaterThan(duration, 0)
            XCTAssertLessThan(duration, 2)
            let frames = BudMoments.frames(kind)
            XCTAssertEqual(frames.count, BudMoments.frameCount(kind))
            XCTAssertGreaterThan(frames.count, 1)
            XCTAssertLessThanOrEqual(Double(frames.count) * BudMoments.frameInterval, duration)
            XCTAssertFalse(frames.allSatisfy { $0 == frames[0] })
            XCTAssertEqual(frames, BudMoments.frames(kind))
            let (_, over) = BudMoments.pose(kind: kind, elapsed: duration)
            XCTAssertFalse(over)
            XCTAssertEqual(BudMoments.pose(kind: kind, elapsed: duration).0, .rest)
            XCTAssertEqual(BudMoments.pose(kind: kind, elapsed: -0.1).0, .rest)
        }
    }

    func testMorningHelloBlinksAwakeAndStretches() {
        let closed = BudMoments.pose(kind: .morningHello, elapsed: 0).0
        XCTAssertEqual(closed.eyeOpen, 0)
        XCTAssertEqual(closed.scaleY, 1)

        let stretch = BudMoments.pose(kind: .morningHello, elapsed: 0.8).0
        XCTAssertEqual(stretch.eyeOpen, 1)
        XCTAssertGreaterThan(stretch.scaleY, 1.05)
        XCTAssertLessThan(stretch.scaleX, 1)

        let (_, still) = BudMoments.pose(kind: .morningHello, elapsed: 1.5)
        XCTAssertTrue(still)
    }

    func testWorriedSweatFallsAndTiredYawnsOnce() {
        let early = BudMoments.pose(kind: .worried, elapsed: 0.4).0
        let later = BudMoments.pose(kind: .worried, elapsed: 0.9).0
        XCTAssertGreaterThan(early.sweat, 0)
        XCTAssertGreaterThan(later.sweat, early.sweat)

        let opening = BudMoments.pose(kind: .tired, elapsed: 0.2).0
        let peak = BudMoments.pose(kind: .tired, elapsed: 0.7).0
        XCTAssertEqual(peak.yawn, CGFloat(1), accuracy: 0.001)
        XCTAssertGreaterThan(peak.yawn, opening.yawn)
        XCTAssertLessThan(peak.eyeOpen, opening.eyeOpen)

        let settled = BudMoments.pose(kind: .tired, elapsed: 1.35).0
        XCTAssertEqual(settled.yawn, 0)
    }

    func testResetHopIsASingleParabola() {
        let crouch = BudMoments.pose(kind: .resetDay, elapsed: 0.05).0
        XCTAssertGreaterThan(crouch.scaleX, 1)
        XCTAssertLessThan(crouch.scaleY, 1)
        XCTAssertEqual(crouch.hop, 0)

        let peak = BudMoments.pose(kind: .resetDay, elapsed: 0.35).0
        XCTAssertEqual(peak.hop, CGFloat(0.10), accuracy: 0.001)

        let landed = BudMoments.pose(kind: .resetDay, elapsed: 0.85).0
        XCTAssertEqual(landed.hop, 0)
    }

    func testHoverPeekBlinksOnceAndGlances() {
        let peek = BudMoments.pose(kind: .hoverPeek, elapsed: 0.12).0
        XCTAssertLessThan(peek.eyeOpen, 0.25)
        XCTAssertGreaterThan(peek.glance, 0.4)

        let back = BudMoments.pose(kind: .hoverPeek, elapsed: 0.48).0
        XCTAssertEqual(back.eyeOpen, 1)
        XCTAssertLessThan(back.glance, 0.15)
    }

    func testAdvanceDoesNotLoopAndPlaysAQueuedClipOnce() {
        let start = Date(timeIntervalSince1970: 1_000)
        var state = BudMomentState()
        state.playing = .hoverPeek
        state.startedAt = start
        state.pending = .morningHello

        let (next, pose) = BudMomentMachine.advance(state: state, now: start.addingTimeInterval(0.5))
        XCTAssertEqual(next.playing, .morningHello)
        XCTAssertNil(next.pending)
        XCTAssertEqual(pose.eyeOpen, 0)

        let (done, rest) = BudMomentMachine.advance(
            state: next,
            now: start.addingTimeInterval(0.5 + BudMoments.duration(.morningHello) + 0.001)
        )
        XCTAssertNil(done.playing)
        XCTAssertNil(done.pending)
        XCTAssertEqual(rest, .rest)

        let (still, restAgain) = BudMomentMachine.advance(state: done, now: start.addingTimeInterval(20))
        XCTAssertNil(still.playing)
        XCTAssertEqual(restAgain, .rest)
    }

    func testMorningHelloIsOncePerCalendarDay() {
        let key = BudMomentGate.dayKey(for: morning, calendar: utc)
        XCTAssertEqual(key, "2026-10-07")
        let claim = BudMomentGate.claimOncePerDay(now: morning, calendar: utc, storedDayKey: nil)
        XCTAssertTrue(claim.due)
        XCTAssertEqual(claim.dayKey, key)
        XCTAssertFalse(BudMomentGate.claimOncePerDay(now: morning.addingTimeInterval(60), calendar: utc, storedDayKey: key).due)

        let tomorrow = morning.addingTimeInterval(24 * 60 * 60)
        XCTAssertTrue(BudMomentGate.claimOncePerDay(now: tomorrow, calendar: utc, storedDayKey: key).due)
        XCTAssertEqual(BudMomentGate.dayKey(for: tomorrow, calendar: utc), "2026-10-08")

        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let afterMidnightUTC = morning.addingTimeInterval(8 * 60 * 60) // 2026-10-08 02:00 UTC
        XCTAssertEqual(BudMomentGate.dayKey(for: afterMidnightUTC, calendar: utc), "2026-10-08")
        XCTAssertEqual(BudMomentGate.dayKey(for: afterMidnightUTC, calendar: losAngeles), "2026-10-07")

        var state = BudMomentState()
        state = reduce(state, .dayMark(now: morning), now: morning)
        XCTAssertEqual(state.playing, .morningHello)
        XCTAssertEqual(state.morningDayKey, "2026-10-07")
        let started = state.startedAt
        state = reduce(state, .dayMark(now: morning.addingTimeInterval(30)), now: morning.addingTimeInterval(30))
        XCTAssertEqual(state.playing, .morningHello)
        XCTAssertEqual(state.startedAt, started)

        var skipped = BudMomentState()
        skipped = reduce(skipped, .dayMark(now: morning), allows: false, now: morning)
        XCTAssertNil(skipped.playing)
        XCTAssertEqual(skipped.morningDayKey, "2026-10-07")
        skipped = reduce(skipped, .dayMark(now: morning.addingTimeInterval(60)), allows: true, now: morning.addingTimeInterval(60))
        XCTAssertNil(skipped.playing)
    }

    func testMoodReactsOnlyOnTheTransition() {
        XCTAssertNil(BudMomentGate.moodReaction(from: nil, to: .worried))
        XCTAssertNil(BudMomentGate.moodReaction(from: .worried, to: .worried))
        XCTAssertNil(BudMomentGate.moodReaction(from: .playful, to: .steady))
        XCTAssertNil(BudMomentGate.moodReaction(from: .tired, to: .asleep))
        XCTAssertNil(BudMomentGate.moodReaction(from: .worried, to: .playful))
        XCTAssertEqual(BudMomentGate.moodReaction(from: .playful, to: .worried), .worried)
        XCTAssertEqual(BudMomentGate.moodReaction(from: .steady, to: .tired), .tired)
        XCTAssertEqual(BudMomentGate.moodReaction(from: .tired, to: .worried), .worried)
        XCTAssertEqual(BudMomentGate.moodReaction(from: .worried, to: .tired), .tired)

        var state = BudMomentState()
        state = reduce(state, .mood(.worried), now: morning)
        XCTAssertNil(state.playing)
        XCTAssertEqual(state.mood, .worried)
        state = reduce(state, .mood(.worried), now: morning.addingTimeInterval(1))
        XCTAssertNil(state.playing)

        state = reduce(state, .mood(.tired), now: morning.addingTimeInterval(2))
        XCTAssertEqual(state.playing, .tired)
        let started = state.startedAt
        state = reduce(state, .mood(.tired), now: morning.addingTimeInterval(3))
        XCTAssertEqual(state.startedAt, started)
        state = reduce(state, .mood(.worried), now: morning.addingTimeInterval(4))
        XCTAssertEqual(state.playing, .tired)
        XCTAssertEqual(state.pending, .worried)
        XCTAssertEqual(state.startedAt, started)
    }

    func testHoverIsThrottledToOncePerTenSeconds() {
        let start = morning
        XCTAssertTrue(BudMomentGate.claimThrottle(now: start, last: nil, interval: 10))
        XCTAssertFalse(BudMomentGate.claimThrottle(now: start.addingTimeInterval(9.9), last: start, interval: 10))
        XCTAssertTrue(BudMomentGate.claimThrottle(now: start.addingTimeInterval(10), last: start, interval: 10))

        var state = BudMomentState()
        state = reduce(state, .hover(now: start), now: start)
        XCTAssertEqual(state.playing, .hoverPeek)
        state = reduce(state, .hover(now: start.addingTimeInterval(9)), now: start.addingTimeInterval(9))
        XCTAssertEqual(state.playing, .hoverPeek)
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.startedAt, start)

        let (done, _) = BudMomentMachine.advance(state: state, now: start.addingTimeInterval(0.5))
        state = done
        XCTAssertNil(state.playing)
        state = reduce(state, .hover(now: start.addingTimeInterval(9)), now: start.addingTimeInterval(9))
        XCTAssertNil(state.playing)
        state = reduce(state, .hover(now: start.addingTimeInterval(10)), now: start.addingTimeInterval(10))
        XCTAssertEqual(state.playing, .hoverPeek)
        XCTAssertEqual(state.startedAt, start.addingTimeInterval(10))
    }

    func testResetPlaysOnASharpDropOrANewWindowAndNotOnRefresh() {
        XCTAssertFalse(BudMomentGate.sharpDrop(from: nil, to: 10, threshold: BudMoments.sharpDrop))
        XCTAssertFalse(BudMomentGate.sharpDrop(from: 80, to: 60.1, threshold: BudMoments.sharpDrop))
        XCTAssertFalse(BudMomentGate.sharpDrop(from: 10, to: 40, threshold: BudMoments.sharpDrop))
        XCTAssertFalse(BudMomentGate.sharpDrop(from: .nan, to: 0, threshold: BudMoments.sharpDrop))
        XCTAssertTrue(BudMomentGate.sharpDrop(from: 80, to: 60, threshold: BudMoments.sharpDrop))

        var state = BudMomentState()
        state = reduce(state, .usage(percent: 80, windowStart: nil), now: morning)
        XCTAssertNil(state.playing)
        state = reduce(state, .usage(percent: 78, windowStart: nil), now: morning.addingTimeInterval(1))
        XCTAssertNil(state.playing)
        state = reduce(state, .usage(percent: 50, windowStart: nil), now: morning.addingTimeInterval(2))
        XCTAssertEqual(state.playing, .resetDay)
        XCTAssertNil(state.pending)

        let previous = Date(timeIntervalSince1970: 1_700_000_000)
        let current = previous.addingTimeInterval(7 * 24 * 60 * 60)
        var window = BudMomentState()
        window = reduce(window, .usage(percent: 90, windowStart: previous), now: morning)
        XCTAssertNil(window.playing)
        window = reduce(window, .usage(percent: 91, windowStart: previous), now: morning.addingTimeInterval(1))
        XCTAssertNil(window.playing)
        window = reduce(window, .usage(percent: 12, windowStart: current), now: morning.addingTimeInterval(2))
        XCTAssertEqual(window.playing, .resetDay)
        XCTAssertNil(window.pending)
        let (done, _) = BudMomentMachine.advance(
            state: window,
            now: morning.addingTimeInterval(2 + BudMoments.duration(.resetDay) + 0.001)
        )
        window = done
        window = reduce(window, .usage(percent: 13, windowStart: current), now: morning.addingTimeInterval(4))
        XCTAssertNil(window.playing)

        var quiet = BudMomentState()
        quiet = reduce(quiet, .usage(percent: nil, windowStart: nil), now: morning)
        XCTAssertNil(quiet.playing)
        XCTAssertNil(quiet.lastPercent)
    }

    func testPlayerPersistsTheDayMoodAndPercentWithoutReplaying() {
        let name = "moments-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let player = makePlayer(defaults: defaults)
        player.setAllowsMoments(true)
        player.noteDayMark(now: morning)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.pose.eyeOpen, 0)
        XCTAssertEqual(defaults.string(forKey: BudMomentStore.morningDay), "2026-10-07")

        player.noteMood(.steady, now: morning)
        player.noteUsage(percent: 88, windowStart: nil, now: morning)
        XCTAssertEqual(player.pose.eyeOpen, 0, "A mood sample and a usage sample must not cancel the hello")
        player.noteMood(.worried, now: morning.addingTimeInterval(0.2))
        XCTAssertEqual(defaults.string(forKey: BudMomentStore.mood), CompanionMood.worried.rawValue)
        XCTAssertEqual(defaults.double(forKey: BudMomentStore.percent), 88, accuracy: 0.001)

        let helloEnd = morning.addingTimeInterval(BudMoments.duration(.morningHello) + 0.05)
        player.advance(to: helloEnd)
        XCTAssertEqual(player.isPlaying, true, "The worried reaction waits until the hello finishes")
        player.advance(to: helloEnd.addingTimeInterval(BudMoments.duration(.worried) + 0.05))
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.pose, .rest)

        let reloaded = makePlayer(defaults: defaults)
        reloaded.setAllowsMoments(true)
        reloaded.noteDayMark(now: morning.addingTimeInterval(60))
        reloaded.noteMood(.worried, now: morning.addingTimeInterval(60))
        XCTAssertFalse(reloaded.isPlaying)
        reloaded.noteUsage(percent: 15, windowStart: nil, now: morning.addingTimeInterval(61))
        XCTAssertTrue(reloaded.isPlaying)

        let held = makePlayer(defaults: defaults)
        held.setAllowsMoments(false)
        held.noteHover(now: morning.addingTimeInterval(120))
        XCTAssertFalse(held.isPlaying)
        held.setAllowsMoments(true)
        held.noteHover(now: morning.addingTimeInterval(121))
        XCTAssertFalse(held.isPlaying, "A hover inside the throttle window stays quiet after motion returns")
        held.noteHover(now: morning.addingTimeInterval(131))
        XCTAssertTrue(held.isPlaying)
    }

    func testSkippingMotionStillConsumesTheMorningHello() {
        let name = "moments-skip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let player = makePlayer(defaults: defaults)
        player.setAllowsMoments(false)
        player.noteDayMark(now: morning)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.pose, .rest)
        XCTAssertEqual(defaults.string(forKey: BudMomentStore.morningDay), "2026-10-07")
        player.setAllowsMoments(true)
        player.noteDayMark(now: morning.addingTimeInterval(30))
        XCTAssertFalse(player.isPlaying)
    }

    func testMomentPoseKeepsEveryMenuBarSlotTheSameSize() {
        let stretch = BudMoments.pose(kind: .morningHello, elapsed: 0.8).0
        let sweat = BudMoments.pose(kind: .worried, elapsed: 0.7).0
        let hop = BudMoments.pose(kind: .resetDay, elapsed: 0.35).0

        let percent = renderCompanionStatusIcon(mood: .playful, percentText: "20%", tint: nil)
        let percentMoment = renderCompanionStatusIcon(mood: .playful, percentText: "20%", tint: nil, moment: stretch)
        XCTAssertEqual(percent.size, percentMoment.size)
        XCTAssertTrue(percent.isTemplate)
        XCTAssertTrue(percentMoment.isTemplate)

        let bars = renderIcon(
            topFraction: 0.4,
            topLabel: "GB",
            bottomFraction: 0.2,
            bottomLabel: "CM",
            mouthFraction: 0.4,
            tint: nil
        )
        let barsMoment = renderIcon(
            topFraction: 0.4,
            topLabel: "GB",
            bottomFraction: 0.2,
            bottomLabel: "CM",
            mouthFraction: 0.4,
            tint: nil,
            moment: sweat
        )
        XCTAssertEqual(bars.size, barsMoment.size)
        XCTAssertEqual(bars.isTemplate, barsMoment.isTemplate)

        let bud = renderCompanionMenuIcon(mood: .playful, mouthFraction: 0.2, frame: .rest)
        let budMoment = renderCompanionMenuIcon(mood: .playful, mouthFraction: 0.2, frame: .rest, moment: hop)
        XCTAssertEqual(bud.size, budMoment.size)
        XCTAssertFalse(bud.isTemplate)
        XCTAssertFalse(budMoment.isTemplate)
    }

    func testBudMomentsCopyIsTranslated() {
        XCTAssertEqual(
            L10n.text("settings.budMoments", "Bud moments", locale: Locale(identifier: "en_US")),
            "Bud moments"
        )
        XCTAssertEqual(
            L10n.text("settings.budMoments", "Bud moments", locale: Locale(identifier: "es_MX")),
            "Momentos de Bud"
        )
        let spanish = L10n.text(
            "settings.budMomentsHelp",
            "missing",
            locale: Locale(identifier: "es")
        )
        XCTAssertTrue(spanish.contains("Reducir movimiento"), spanish)
        XCTAssertFalse(spanish.contains("missing"))
    }

    private func reduce(
        _ state: BudMomentState,
        _ event: BudMomentEvent,
        allows: Bool = true,
        now: Date
    ) -> BudMomentState {
        BudMomentMachine.reduce(state: state, event: event, allows: allows, now: now, calendar: utc)
    }

    private func makePlayer(defaults: UserDefaults) -> BudMomentPlayer {
        BudMomentPlayer(defaults: defaults, calendar: utc, watchWorkspace: false, schedulesTimers: false)
    }
}
