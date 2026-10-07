import AppKit
import SwiftUI
import XCTest
@testable import Jollybar

/// Renders the companion popover and the menu-bar item. Headless ImageRenderer
/// can fail without a window server; the test then tries an offscreen window
/// and skips only if both produce nothing, so CI stays green. The workflow
/// uploads whatever PNGs were written.
@MainActor
final class CompanionPetSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_396_000) // 2026-10-07 18:00:00 UTC
    private let periodStart = Date(timeIntervalSince1970: 1_791_190_800) // 2026-10-05 09:00:00 UTC
    private let reset = Date(timeIntervalSince1970: 1_791_795_600) // 2026-10-12 09:00:00 UTC

    func testWritesPetStateSnapshots() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/pet-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let moods: [(CompanionMood, Double, String)] = [
            (.playful, 28, "playful"),
            (.steady, 62, "steady"),
            (.tired, 78, "tired"),
            (.worried, 93, "worried"),
            (.asleep, 100, "asleep"),
        ]
        var wrote = 0
        for (mood, percent, name) in moods {
            let dark = popover(mood: mood, usedPercent: percent, scheme: .dark)
            if let png = png(of: dark, width: 320) {
                try png.write(to: directory.appendingPathComponent("popover-\(name)-dark.png"))
                wrote += 1
            }
        }
        let light = popover(mood: .playful, usedPercent: 28, scheme: .light)
        if let png = png(of: light, width: 320) {
            try png.write(to: directory.appendingPathComponent("popover-playful-light.png"))
            wrote += 1
        }

        let samples: [(Double, CompanionMood, String)] = [
            (20, .playful, "menubar-20"),
            (70, .steady, "menubar-70"),
            (92, .worried, "menubar-92"),
            (100, .asleep, "menubar-100"),
        ]
        var menuImages: [(String, NSImage)] = []
        for (percent, mood, name) in samples {
            let tint = JollyTheme.menuTint(mood: mood, usedPercent: percent)?.nsColor
            let image = renderCompanionStatusIcon(
                mood: mood,
                percentText: UsageNumber.menuText(usedPercent: percent),
                tint: tint
            )
            if let png = menuPNG(image) {
                try png.write(to: directory.appendingPathComponent("\(name).png"))
                wrote += 1
            }
            menuImages.append((name, image))
        }
        if let strip = menuStrip(menuImages), let png = menuPNG(strip, pad: 8) {
            try png.write(to: directory.appendingPathComponent("menubar-samples.png"))
            wrote += 1
        }

        let popovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("popover-") && $0.pathExtension == "png" }
        if wrote == 0 {
            throw XCTSkip("ImageRenderer did not produce an image in this environment")
        }
        XCTAssertEqual(popovers.count, 6, "Expected a dark popover for each mood and one light popover")
    }

    private func popover(mood: CompanionMood, usedPercent: Double, scheme: ColorScheme) -> some View {
        let popover = CompanionPopover(
            model: model(mood: mood, usedPercent: usedPercent),
            frozenNow: now,
            locale: Locale(identifier: "en_US"),
            calendar: utcCalendar,
            motionEnabled: false,
            celebrate: false,
            onCelebrationFinished: {},
            onChartMode: { _ in },
            onRefresh: {},
            historyChart: { EmptyView() }
        )
        .environment(\.colorScheme, scheme)
        .environment(\.locale, Locale(identifier: "en_US"))
        return popover
    }

    private func model(mood: CompanionMood, usedPercent: Double) -> CompanionPopoverModel {
        CompanionPopoverModel(
            mood: mood,
            planTitle: "Weekly",
            heroTitle: "Grok Bot",
            usedPercent: usedPercent,
            percentStyle: .used,
            periodStart: periodStart,
            resetsAt: reset,
            assumedMonthlyNote: nil,
            heroStatus: nil,
            heroStatusIsError: false,
            cursorModelsPercent: 18,
            otherModelsPercent: 4,
            superGrokPercent: nil,
            modelsStatus: nil,
            modelsStatusIsError: false,
            onDemandText: "$12.40 / $50",
            sprouts: sampleSprouts,
            sproutReady: true,
            chartMode: .sprout,
            syncedAt: now,
            updaterError: nil,
            details: [],
            detailNote: nil
        )
    }

    private var sampleSprouts: [SproutWeek.Day] {
        let gains = [4.0, 9, 3, 14, 6, 2, 8]
        let today = utcCalendar.startOfDay(for: now)
        return (0..<7).compactMap { offset in
            guard let day = utcCalendar.date(byAdding: .day, value: offset - 6, to: today) else { return nil }
            return SproutWeek.Day(start: day, usagePoints: gains[offset], isToday: offset == 6)
        }
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func png<V: View>(of view: V, width: CGFloat) -> Data? {
        let content = view
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        if let image = renderer.nsImage,
           image.size.width > 100,
           image.size.height > 200,
           image.size.height < 900,
           let data = pngData(from: image, scale: 2),
           data.count > 800 {
            return data
        }
        return pngFromWindow(content, width: width)
    }

    private func pngFromWindow<V: View>(_ view: V, width: CGFloat) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 20)
        var fitted = hosting.fittingSize
        if fitted.height < 80 { fitted.height = 640 }
        fitted.width = width
        hosting.frame = CGRect(origin: .zero, size: fitted)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func menuStrip(_ items: [(String, NSImage)]) -> NSImage? {
        guard let first = items.first else { return nil }
        let gap: CGFloat = 16
        let width = items.reduce(0) { $0 + $1.1.size.width } + gap * CGFloat(items.count - 1)
        let height = first.1.size.height
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for item in items {
                item.1.draw(in: CGRect(x: x, y: 0, width: item.1.size.width, height: height))
                x += item.1.size.width + gap
            }
            return true
        }
    }

    private func menuPNG(_ image: NSImage, pad: CGFloat = 6) -> Data? {
        let size = NSSize(width: image.size.width + pad * 2, height: image.size.height + pad * 2)
        let canvas = NSImage(size: size, flipped: false) { bounds in
            NSColor(srgbRed: 0.93, green: 0.94, blue: 0.93, alpha: 1).setFill()
            bounds.fill()
            image.draw(in: CGRect(
                x: pad,
                y: pad,
                width: image.size.width,
                height: image.size.height
            ))
            return true
        }
        guard let data = pngData(from: canvas, scale: 3), data.count > 40 else { return nil }
        return data
    }

    private func pngData(from image: NSImage, scale: CGFloat = 1) -> Data? {
        let pixelsWide = max(1, Int((image.size.width * scale).rounded()))
        let pixelsHigh = max(1, Int((image.size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
