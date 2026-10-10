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

/// Bud's face plus the Grok Bot percent. The face is a still frame: it changes
/// only when the mood (or a reset that changes the mood) changes. The percent
/// uses SF Pro Rounded with monospaced digits in a slot the width of "100%",
/// so 8% and 100% take the same menu-bar width.
/// A nil tint is a template image. From 70% used, pass the mood color.
func renderCompanionStatusIcon(
    mood: CompanionMood,
    percentText: String,
    tint: NSColor?
) -> NSImage {
    let font = menuPercentFont(size: 12)
    let color = tint ?? NSColor.black
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color
    ]
    let slot = ceil(NSAttributedString(string: "100%", attributes: attributes).size().width)
    let percent = NSAttributedString(string: percentText, attributes: attributes)
    let percentWidth = max(slot, ceil(percent.size().width))
    let face: CGFloat = 16
    let gap: CGFloat = 3
    let height: CGFloat = 18
    let width = 1 + face + gap + percentWidth + 2
    let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
        let faceY = (height - face) / 2
        drawMenuBud(mood: mood, in: CGRect(x: 1, y: faceY, width: face, height: face), color: color)
        let textSize = percent.size()
        let textX = 1 + face + gap + percentWidth - textSize.width
        let textY = (height - textSize.height) / 2
        percent.draw(at: NSPoint(x: textX, y: textY))
        return true
    }
    image.isTemplate = tint == nil
    return image
}

private func menuPercentFont(size: CGFloat) -> NSFont {
    let tabular = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    guard let rounded = tabular.fontDescriptor.withDesign(.rounded),
          let font = NSFont(descriptor: rounded, size: size) else {
        return tabular
    }
    return font
}

/// Monochrome face that still reads at 16pt. Filled marks stay visible as a template.
private func drawMenuBud(mood: CompanionMood, in rect: CGRect, color: NSColor) {
    color.setStroke()
    color.setFill()
    let weight = max(1.1, rect.width * 0.075)

    let leaf = NSBezierPath(ovalIn: CGRect(
        x: rect.midX + rect.width * 0.02,
        y: rect.minY,
        width: rect.width * 0.28,
        height: rect.height * 0.24
    ))
    leaf.fill()

    let head = NSBezierPath(ovalIn: CGRect(
        x: rect.minX + rect.width * 0.08,
        y: rect.minY + rect.height * 0.20,
        width: rect.width * 0.84,
        height: rect.height * 0.76
    ))
    head.lineWidth = weight
    head.stroke()

    let eyeY = rect.minY + rect.height * 0.46
    let leftX = rect.minX + rect.width * 0.30
    let rightX = rect.minX + rect.width * 0.58
    switch mood {
    case .asleep:
        strokeMenuArc(x: leftX, y: eyeY, width: rect.width * 0.18, smiling: true, color: color)
        strokeMenuArc(x: rightX, y: eyeY, width: rect.width * 0.18, smiling: true, color: color)
        let z = NSAttributedString(
            string: "z",
            attributes: [
                .font: NSFont.systemFont(ofSize: max(6, rect.width * 0.28), weight: .bold),
                .foregroundColor: color
            ]
        )
        z.draw(at: NSPoint(x: rect.maxX - rect.width * 0.28, y: rect.minY + 0.5))
    case .tired:
        fillMenuCapsule(x: leftX, y: eyeY, width: rect.width * 0.22, height: max(2, rect.height * 0.11), color: color)
        fillMenuCapsule(x: rightX, y: eyeY, width: rect.width * 0.22, height: max(2, rect.height * 0.11), color: color)
    case .worried:
        fillMenuEye(x: leftX, y: eyeY, diameter: rect.width * 0.16, color: color)
        fillMenuEye(x: rightX, y: eyeY, diameter: rect.width * 0.16, color: color)
    case .playful:
        fillMenuEye(x: leftX, y: eyeY - 0.4, diameter: rect.width * 0.13, color: color)
        fillMenuEye(x: rightX, y: eyeY - 0.4, diameter: rect.width * 0.13, color: color)
    case .steady, .unknown:
        fillMenuEye(x: leftX, y: eyeY, diameter: rect.width * 0.11, color: color)
        fillMenuEye(x: rightX, y: eyeY, diameter: rect.width * 0.11, color: color)
    }

    let mouthWidth = mood == .playful ? rect.width * 0.42 : rect.width * 0.30
    let mouthRect = CGRect(
        x: rect.midX - mouthWidth / 2,
        y: rect.minY + rect.height * 0.64,
        width: mouthWidth,
        height: rect.height * 0.16
    )
    strokeMenuMouth(mood.mouth, in: mouthRect, color: color, weight: weight)
}

private func fillMenuEye(x: CGFloat, y: CGFloat, diameter: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: CGRect(x: x, y: y, width: diameter, height: diameter)).fill()
}

private func fillMenuCapsule(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
}

private func strokeMenuArc(x: CGFloat, y: CGFloat, width: CGFloat, smiling: Bool, color: NSColor) {
    let path = NSBezierPath()
    let cornerY = smiling ? y : y + width * 0.35
    let controlY = smiling ? y + width * 0.45 : y
    path.move(to: NSPoint(x: x, y: cornerY))
    path.curve(
        to: NSPoint(x: x + width, y: cornerY),
        controlPoint1: NSPoint(x: x + width * 0.35, y: controlY),
        controlPoint2: NSPoint(x: x + width * 0.65, y: controlY)
    )
    color.setStroke()
    path.lineWidth = 1.1
    path.lineCapStyle = .round
    path.stroke()
}

private func strokeMenuMouth(_ curve: MouthCurve, in rect: CGRect, color: NSColor, weight: CGFloat) {
    let path = NSBezierPath()
    if curve == .flat {
        path.move(to: NSPoint(x: rect.minX, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
    } else {
        let smiling = curve.depth > 0.5
        let cornerY = smiling ? rect.minY : rect.maxY
        let controlY = rect.minY + rect.height * curve.depth
        path.move(to: NSPoint(x: rect.minX, y: cornerY))
        path.curve(
            to: NSPoint(x: rect.maxX, y: cornerY),
            controlPoint1: NSPoint(x: rect.midX, y: controlY),
            controlPoint2: NSPoint(x: rect.midX, y: controlY)
        )
    }
    color.setStroke()
    path.lineWidth = weight
    path.lineCapStyle = .round
    path.stroke()
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
