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
        let spanish = popover(
            mood: .worried,
            usedPercent: 93,
            scheme: .dark,
            locale: Locale(identifier: "es_MX")
        )
        if let png = png(of: spanish, width: 320) {
            try png.write(to: directory.appendingPathComponent("popover-worried-es.png"))
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
        if let styles = menuStyles(), let png = menuPNG(styles, pad: 12) {
            try png.write(to: directory.appendingPathComponent("menubar-styles.png"))
            wrote += 1
        }
        if let preview = iconPreview(), let png = pngData(from: preview, scale: 1), png.count > 1000 {
            try png.write(to: directory.appendingPathComponent("icon-preview.png"))
            wrote += 1
        }

        let popovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("popover-") && $0.pathExtension == "png" }
        if wrote == 0 {
            throw XCTSkip("ImageRenderer did not produce an image in this environment")
        }
        XCTAssertEqual(popovers.count, 7, "Expected a dark popover for each mood, one light popover, and one Spanish popover")
    }

    private func popover(
        mood: CompanionMood,
        usedPercent: Double,
        scheme: ColorScheme,
        locale: Locale = Locale(identifier: "en_US")
    ) -> some View {
        var calendar = utcCalendar
        calendar.locale = locale
        let popover = CompanionPopover(
            model: model(mood: mood, usedPercent: usedPercent, locale: locale),
            frozenNow: now,
            locale: locale,
            calendar: calendar,
            motionEnabled: false,
            celebrate: false,
            onCelebrationFinished: {},
            onChartMode: { _ in },
            onRefresh: {},
            historyChart: { EmptyView() }
        )
        .environment(\.colorScheme, scheme)
        .environment(\.locale, locale)
        return popover
    }

    private func model(mood: CompanionMood, usedPercent: Double, locale: Locale = Locale(identifier: "en_US")) -> CompanionPopoverModel {
        let spanish = locale.identifier.hasPrefix("es")
        return CompanionPopoverModel(
            mood: mood,
            planTitle: spanish ? "Semanal" : "Weekly",
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

    /// Percent, usage bars, and companion at 20 / 70 / 92 / 100.
    /// Companion uses the rest frame so the snapshot does not depend on the timer.
    private func menuStyles() -> NSImage? {
        let samples: [(Double, CompanionMood, String)] = [
            (20, .playful, "20%"),
            (70, .steady, "70%"),
            (92, .worried, "92%"),
            (100, .asleep, "100%"),
        ]
        let titles = ["Percent", "Usage bars", "Companion"]
        var rows: [(String, [NSImage])] = []
        for (percent, mood, label) in samples {
            let tint = JollyTheme.menuTint(mood: mood, usedPercent: percent)?.nsColor
            let text = UsageNumber.menuText(usedPercent: percent)
            let mouth = MenuBarMouth.fraction(usedPercent: percent)
            let bottom = min(1, (percent / 100) * 0.4)
            rows.append((label, [
                renderCompanionStatusIcon(mood: mood, percentText: text, tint: tint),
                renderIcon(
                    topFraction: percent / 100,
                    topLabel: "GB",
                    bottomFraction: bottom,
                    bottomLabel: "CM",
                    mouthFraction: mouth,
                    tint: tint
                ),
                renderCompanionMenuIcon(mood: mood, mouthFraction: mouth, frame: .rest)
            ]))
        }

        let gapX: CGFloat = 22
        let gapY: CGFloat = 16
        let headerHeight: CGFloat = 14
        let labelWidth: CGFloat = 40
        let colWidths = (0..<3).map { column in
            rows.map { $0.1[column].size.width }.max() ?? 0
        }
        let rowHeight = rows.flatMap { $0.1 }.map(\.size.height).max() ?? 18
        let width = labelWidth + colWidths.reduce(0, +) + gapX * CGFloat(max(0, colWidths.count - 1))
        let height = headerHeight + gapY + rowHeight * CGFloat(rows.count) + gapY * CGFloat(rows.count - 1)
        let headerFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let ink = NSColor(srgbRed: 0x0E / 255.0, green: 0x14 / 255.0, blue: 0x16 / 255.0, alpha: 1)

        return NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            var x = labelWidth
            for (index, title) in titles.enumerated() {
                let string = NSAttributedString(string: title, attributes: [
                    .font: headerFont,
                    .foregroundColor: ink
                ])
                string.draw(at: NSPoint(x: x, y: 0))
                x += colWidths[index] + gapX
            }
            for (rowIndex, row) in rows.enumerated() {
                let y = headerHeight + gapY + CGFloat(rowIndex) * (rowHeight + gapY)
                let label = NSAttributedString(string: row.0, attributes: [
                    .font: labelFont,
                    .foregroundColor: ink
                ])
                label.draw(at: NSPoint(x: 0, y: y + (rowHeight - label.size().height) / 2))
                var columnX = labelWidth
                for (index, image) in row.1.enumerated() {
                    let imageY = y + (rowHeight - image.size.height) / 2
                    image.draw(in: CGRect(x: columnX, y: imageY, width: image.size.width, height: image.size.height))
                    columnX += colWidths[index] + gapX
                }
            }
            return true
        }
    }

    /// 1024 asset plus a nearest-neighbor enlargement of the 32px asset, and the 32px asset itself.
    private func iconPreview() -> NSImage? {
        let iconset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("macos/Resources/Assets.xcassets/AppIcon.appiconset")
        guard
            let large = bitmap(at: iconset.appendingPathComponent("icon_512x512@2x.png")),
            let small = bitmap(at: iconset.appendingPathComponent("icon_32x32.png")),
            large.pixelsWide == 1024,
            large.pixelsHigh == 1024,
            small.pixelsWide == 32,
            small.pixelsHigh == 32
        else {
            return nil
        }

        large.size = NSSize(width: 1024, height: 1024)
        small.size = NSSize(width: 32, height: 32)
        let largeImage = NSImage(size: large.size)
        largeImage.addRepresentation(large)
        let smallImage = NSImage(size: small.size)
        smallImage.addRepresentation(small)

        let pad: CGFloat = 32
        let gap: CGFloat = 32
        let enlarged: CGFloat = 256
        let width = pad + 1024 + gap + enlarged + gap + 32 + pad
        let height = pad + 1024 + pad
        let paper = NSColor(srgbRed: 0xF3 / 255.0, green: 0xEE / 255.0, blue: 0xE4 / 255.0, alpha: 1)
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { bounds in
            paper.setFill()
            bounds.fill()
            largeImage.draw(in: CGRect(x: pad, y: pad, width: 1024, height: 1024))
            NSGraphicsContext.current?.imageInterpolation = .none
            let enlargedY = pad + (1024 - enlarged) / 2
            smallImage.draw(in: CGRect(x: pad + 1024 + gap, y: enlargedY, width: enlarged, height: enlarged))
            let nativeY = pad + (1024 - 32) / 2
            smallImage.draw(
                in: CGRect(x: pad + 1024 + gap + enlarged + gap, y: nativeY, width: 32, height: 32)
            )
            return true
        }
    }

    private func bitmap(at url: URL) -> NSBitmapImageRep? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSBitmapImageRep(data: data)
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
