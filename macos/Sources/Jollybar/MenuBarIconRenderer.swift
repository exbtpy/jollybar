import AppKit

private let labelWidth: CGFloat = 14
private let barWidth: CGFloat = 24
private let barHeight: CGFloat = 5
private let rowGap: CGFloat = 3
private let labelGap: CGFloat = 2
private let cornerRadius: CGFloat = 2
private let logoSize: CGFloat = 12
private let logoGap: CGFloat = 2
private let barsWidth: CGFloat = labelWidth + labelGap + barWidth + 2
private let iconWidth: CGFloat = logoSize + logoGap + barsWidth
private let iconHeight: CGFloat = 18
private let fontSize: CGFloat = 8

private let botLabel = "GB"
private let spendLabel = "Sp"
private let weeklyLabel = "Wk"
private let modelsLabel = "CM"

private struct CachedLabel {
    let string: NSAttributedString
    let size: NSSize
}

private let cachedLabels: [String: CachedLabel] = {
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    var result = [String: CachedLabel]()
    for label in [botLabel, spendLabel, weeklyLabel, modelsLabel] {
        let str = NSAttributedString(string: label, attributes: attrs)
        result[label] = CachedLabel(string: str, size: str.size())
    }
    return result
}()

private func drawRow(label: String, barX: CGFloat, barY: CGFloat, labelX: CGFloat, drawBarFill: (CGFloat, CGFloat) -> Void) {
    if let cached = cachedLabels[label] {
        let labelY = barY + (barHeight - cached.size.height) / 2
        cached.string.draw(at: NSPoint(x: labelX + labelWidth - cached.size.width, y: labelY))
    }
    drawBarFill(barX, barY)
}

/// Two menu-bar meters in the original stacked layout.
/// Top is Grok Bot weekly (`GB`) or Admin spend (`Sp`).
/// Bottom is SuperGrok (`Wk`) or Cursor Models (`CM`).
/// A nil fraction draws a dashed track so the other source can stand alone.
/// Classic draws a bar glyph. Companion draws a small pet face for the same mood.
/// Neither mark is a Claude, xAI, or Cursor logo.
func renderIcon(
    topFraction: Double?,
    topLabel: String,
    bottomFraction: Double?,
    bottomLabel: String,
    theme: MenuTheme = .classic,
    mood: CompanionMood = .unknown
) -> NSImage {
    let image = NSImage(size: NSSize(width: iconWidth, height: iconHeight), flipped: true) { _ in
        let offset = logoSize + logoGap
        let barX = offset + labelWidth + labelGap
        let topY = (iconHeight - barHeight * 2 - rowGap) / 2
        let bottomY = topY + barHeight + rowGap

        if theme == .companion {
            drawCompanionGlyph(mood: mood, x: 0, y: (iconHeight - logoSize) / 2, size: logoSize)
        } else {
            drawGlyph(x: 0, y: (iconHeight - logoSize) / 2, size: logoSize)
        }
        drawMeter(label: topLabel, fraction: topFraction, barX: barX, barY: topY, labelX: offset)
        drawMeter(label: bottomLabel, fraction: bottomFraction, barX: barX, barY: bottomY, labelX: offset)
        return true
    }
    image.isTemplate = true
    return image
}

func renderUnauthenticatedIcon() -> NSImage {
    renderIcon(topFraction: nil, topLabel: botLabel, bottomFraction: nil, bottomLabel: weeklyLabel)
}

private func drawCompanionGlyph(mood: CompanionMood, x: CGFloat, y: CGFloat, size: CGFloat) {
    let rect = NSRect(x: x + 0.5, y: y + 1, width: size - 1, height: size - 2)
    let body = NSBezierPath(ovalIn: rect)
    NSColor.black.setStroke()
    body.lineWidth = 1
    body.stroke()

    let eyeY = y + size * 0.38
    let leftX = x + size * 0.28
    let rightX = x + size * 0.62
    switch mood {
    case .asleep:
        strokeEyeLine(x: leftX, y: eyeY, width: size * 0.22)
        strokeEyeLine(x: rightX, y: eyeY, width: size * 0.22)
    case .tired:
        strokeEyeLine(x: leftX, y: eyeY, width: size * 0.24)
        strokeEyeLine(x: rightX, y: eyeY, width: size * 0.24)
    case .worried:
        fillEye(x: leftX, y: eyeY, diameter: size * 0.22)
        fillEye(x: rightX, y: eyeY, diameter: size * 0.22)
    case .playful:
        fillEye(x: leftX, y: eyeY, diameter: size * 0.16)
        fillEye(x: rightX, y: eyeY, diameter: size * 0.16)
    case .steady, .unknown:
        fillEye(x: leftX, y: eyeY, diameter: size * 0.12)
        fillEye(x: rightX, y: eyeY, diameter: size * 0.12)
    }
}

private func fillEye(x: CGFloat, y: CGFloat, diameter: CGFloat) {
    let rect = NSRect(x: x, y: y, width: diameter, height: diameter)
    NSColor.black.setFill()
    NSBezierPath(ovalIn: rect).fill()
}

private func strokeEyeLine(x: CGFloat, y: CGFloat, width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x, y: y + 1))
    path.line(to: NSPoint(x: x + width, y: y + 1))
    NSColor.black.setStroke()
    path.lineWidth = 1
    path.stroke()
}

private func drawMeter(label: String, fraction: Double?, barX: CGFloat, barY: CGFloat, labelX: CGFloat) {
    drawRow(label: label, barX: barX, barY: barY, labelX: labelX) { x, y in
        if let fraction {
            drawBar(x: x, y: y, width: barWidth, height: barHeight, pct: fraction)
        } else {
            drawDashedBar(x: x, y: y, width: barWidth, height: barHeight)
        }
    }
}

private func drawGlyph(x: CGFloat, y: CGFloat, size: CGFloat) {
    let rect = NSRect(x: x, y: y, width: size, height: size)
    let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
    NSColor.black.setStroke()
    outline.lineWidth = 1
    outline.stroke()

    let bars: [CGFloat] = [0.45, 0.75, 0.3]
    let inset = size * 0.22
    let usable = size - inset * 2
    let barW = usable / CGFloat(bars.count * 2 - 1)
    for (index, height) in bars.enumerated() {
        let barRect = NSRect(
            x: x + inset + CGFloat(index) * barW * 2,
            y: y + size - inset - usable * height,
            width: barW,
            height: usable * height
        )
        NSColor.black.setFill()
        NSBezierPath(rect: barRect).fill()
    }
}

private func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, pct: Double) {
    let bgRect = NSRect(x: x, y: y, width: width, height: height)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.black.withAlphaComponent(0.25).setFill()
    bgPath.fill()

    let clamped = max(0, min(1, pct))
    if clamped > 0 {
        let fillRect = NSRect(x: x, y: y, width: width * clamped, height: height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.black.setFill()
        fillPath.fill()
    }
}

private func drawDashedBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
    let rect = NSRect(x: x, y: y, width: width, height: height)
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.black.withAlphaComponent(0.25).setStroke()
    path.lineWidth = 1
    let dashPattern: [CGFloat] = [2, 2]
    path.setLineDash(dashPattern, count: 2, phase: 0)
    path.stroke()
}
