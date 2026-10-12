import AppKit

private let labelWidth: CGFloat = 14
private let barWidth: CGFloat = 24
private let barHeight: CGFloat = 5
private let rowGap: CGFloat = 3
private let labelGap: CGFloat = 2
private let cornerRadius: CGFloat = 2
private let logoSize: CGFloat = 15
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

/// Headline used-percent as a 0...1 mouth fill. Nil is an empty track.
enum MenuBarMouth {
    static func fraction(usedPercent: Double?) -> Double? {
        guard let rounded = UsageNumber.roundedUsed(usedPercent) else { return nil }
        return min(1, Double(rounded) / 100)
    }

    static func fraction(percentText: String) -> Double? {
        guard percentText.hasSuffix("%") else { return nil }
        guard let value = Double(percentText.dropLast()) else { return nil }
        return min(1, max(0, value / 100))
    }
}

/// Logo 1 face plus the two stacked meters.
/// Top is Grok Bot weekly (`GB`) or Admin spend (`Sp`).
/// Bottom is SuperGrok (`Wk`) or Cursor Models (`CM`).
/// A nil meter fraction draws a dashed track. The mouth uses `mouthFraction`,
/// which is the headline used percent, not either meter.
/// A nil tint is a template image. From 70% used, pass the mood color.
func renderIcon(
    topFraction: Double?,
    topLabel: String,
    bottomFraction: Double?,
    bottomLabel: String,
    mouthFraction: Double? = nil,
    tint: NSColor? = nil,
    moment: BudMomentPose = .rest
) -> NSImage {
    let color = tint ?? NSColor.black
    let image = NSImage(size: NSSize(width: iconWidth, height: iconHeight), flipped: true) { _ in
        let offset = logoSize + logoGap
        let barX = offset + labelWidth + labelGap
        let topY = (iconHeight - barHeight * 2 - rowGap) / 2
        let bottomY = topY + barHeight + rowGap
        let faceY = (iconHeight - logoSize) / 2
        let faceRect = CGRect(x: 0, y: faceY, width: logoSize, height: logoSize)
        NSGraphicsContext.saveGraphicsState()
        if moment != .rest {
            momentTransform(pose: moment, around: faceRect).concat()
        }
        drawLogoFace(
            in: faceRect,
            color: color,
            mouthFraction: mouthFraction,
            moment: moment
        )
        NSGraphicsContext.restoreGraphicsState()
        drawMeter(label: topLabel, fraction: topFraction, barX: barX, barY: topY, labelX: offset, color: color, cacheLabel: tint == nil)
        drawMeter(label: bottomLabel, fraction: bottomFraction, barX: barX, barY: bottomY, labelX: offset, color: color, cacheLabel: tint == nil)
        return true
    }
    image.isTemplate = tint == nil
    return image
}

func renderUnauthenticatedIcon() -> NSImage {
    renderIcon(topFraction: nil, topLabel: botLabel, bottomFraction: nil, bottomLabel: weeklyLabel)
}

/// Logo 1 face plus the used percent. The face is closed-eye arcs and a bar
/// mouth filled to the same percent as the text. The percent uses SF Pro Rounded
/// with monospaced digits in a slot the width of "100%", so 8% and 100% take
/// the same menu-bar width.
/// A nil tint is a template image. From 70% used, pass the mood color.
func renderCompanionStatusIcon(
    mood: CompanionMood,
    percentText: String,
    tint: NSColor?,
    moment: BudMomentPose = .rest
) -> NSImage {
    _ = mood
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
    let mouth = MenuBarMouth.fraction(percentText: percentText)
    let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
        let faceY = (height - face) / 2
        let faceRect = CGRect(x: 1, y: faceY, width: face, height: face)
        NSGraphicsContext.saveGraphicsState()
        if moment != .rest {
            momentTransform(pose: moment, around: faceRect).concat()
        }
        drawLogoFace(
            in: faceRect,
            color: color,
            mouthFraction: mouth,
            moment: moment
        )
        NSGraphicsContext.restoreGraphicsState()
        let textSize = percent.size()
        let textX = 1 + face + gap + percentWidth - textSize.width
        let textY = (height - textSize.height) / 2
        percent.draw(at: NSPoint(x: textX, y: textY))
        return true
    }
    image.isTemplate = tint == nil
    return image
}

/// Mini Bud in the mood color, plus a tiny bar filled to the headline percent.
/// The image bounds stay fixed. `frame` only moves the bud, not the bar.
/// A playing moment moves the bud instead, and the bar stays put.
/// This image is never a template: the body is the mood color.
func renderCompanionMenuIcon(
    mood: CompanionMood,
    mouthFraction: Double?,
    frame: CompanionMenuFrame,
    moment: BudMomentPose = .rest,
    momentActive: Bool = false
) -> NSImage {
    let bud: CGFloat = 15
    let gap: CGFloat = 3
    let meterWidth: CGFloat = 13
    let height: CGFloat = 18
    let width = 1 + bud + gap + meterWidth + 2
    let posing = momentActive || moment != .rest
    let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
        let budRect = CGRect(x: 1, y: (height - bud) / 2, width: bud, height: bud)
        NSGraphicsContext.saveGraphicsState()
        if posing {
            momentTransform(pose: moment, around: budRect).concat()
        } else {
            companionTransform(frame: frame, around: budRect).concat()
        }
        drawMiniBud(
            mood: mood,
            in: budRect,
            eyeOpen: posing ? moment.eyeOpen : frame.eyeOpen,
            moment: posing ? moment : .rest
        )
        NSGraphicsContext.restoreGraphicsState()

        let meter = CGRect(
            x: budRect.maxX + gap,
            y: (height - 3) / 2,
            width: meterWidth,
            height: 3
        )
        drawTinyMeter(in: meter, fraction: mouthFraction, color: JollyTheme.moodRGB(mood).nsColor)
        return true
    }
    image.isTemplate = false
    return image
}

/// Bud alone, padded so a hop or a stretch stays in the bitmap. Filmstrips use this.
/// The menu bar applies the same pose to the glyph and leaves the meters still.
func renderMomentGlyph(mood: CompanionMood, pose: BudMomentPose, side: CGFloat = 48) -> NSImage {
    let pad = side * 0.45
    let canvas = side + pad * 2
    let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: true) { _ in
        let rect = CGRect(x: pad, y: pad, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        if pose != .rest {
            momentTransform(pose: pose, around: rect).concat()
        }
        drawMiniBud(mood: mood, in: rect, eyeOpen: pose == .rest ? 1 : pose.eyeOpen, moment: pose)
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    image.isTemplate = false
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

/// Closed-eye arcs and a horizontal bar mouth, in one color so the image can be a template.
/// Fractions are relative to the face box, matching the icon SVG on the squircle.
private func drawLogoFace(in rect: CGRect, color: NSColor, mouthFraction: Double?, moment: BudMomentPose = .rest) {
    let weight = max(1.2, rect.width * 0.10)
    let shift = moment.glance * rect.width * 0.08
    if moment != .rest && moment.eyeOpen >= 0.25 {
        fillLogoEye(center: 0.32, in: rect, color: color, open: moment.eyeOpen, xShift: shift)
        fillLogoEye(center: 0.68, in: rect, color: color, open: moment.eyeOpen, xShift: shift)
    } else {
        strokeLogoEye(center: 0.32, in: rect, color: color, weight: weight, xShift: shift)
        strokeLogoEye(center: 0.68, in: rect, color: color, weight: weight, xShift: shift)
    }

    let yawnExtra = moment.yawn * rect.height * 0.16
    let mouth = CGRect(
        x: rect.minX + rect.width * 0.13,
        y: rect.minY + rect.height * 0.62,
        width: rect.width * 0.74,
        height: max(2, rect.height * 0.117) + yawnExtra
    )
    let radius = mouth.height / 2
    color.withAlphaComponent(0.22).setFill()
    NSBezierPath(roundedRect: mouth, xRadius: radius, yRadius: radius).fill()

    if let mouthFraction, mouthFraction > 0 {
        let clamped = min(1, max(0, mouthFraction))
        let fillWidth = mouth.width * CGFloat(clamped)
        if fillWidth > 0.4 {
            color.setFill()
            NSBezierPath(
                roundedRect: CGRect(x: mouth.minX, y: mouth.minY, width: fillWidth, height: mouth.height),
                xRadius: radius,
                yRadius: radius
            ).fill()
        }
    }

    guard moment.sweat > 0.04 else { return }
    let drop = max(1.2, rect.width * 0.13)
    let x = rect.maxX - drop * 1.7
    let y = rect.minY + rect.height * 0.10 + rect.height * 0.46 * moment.sweat
    color.setFill()
    NSBezierPath(ovalIn: CGRect(x: x, y: y, width: drop * 0.62, height: drop)).fill()
}

private func strokeLogoEye(center: CGFloat, in rect: CGRect, color: NSColor, weight: CGFloat, xShift: CGFloat = 0) {
    let half = rect.width * 0.11
    let midX = rect.minX + rect.width * center + xShift
    let baseY = rect.minY + rect.height * 0.47
    let peakY = rect.minY + rect.height * 0.35
    let path = NSBezierPath()
    path.move(to: NSPoint(x: midX - half, y: baseY))
    addQuadCurve(
        path,
        to: NSPoint(x: midX + half, y: baseY),
        control: NSPoint(x: midX, y: peakY)
    )
    color.setStroke()
    path.lineWidth = weight
    path.lineCapStyle = .round
    path.stroke()
}

private func fillLogoEye(center: CGFloat, in rect: CGRect, color: NSColor, open: CGFloat, xShift: CGFloat) {
    let diameter = max(1.3, rect.width * 0.14)
    let height = max(0.7, diameter * min(1, max(0.25, open)))
    let midX = rect.minX + rect.width * center + xShift
    let y = rect.minY + rect.height * 0.36
    color.setFill()
    NSBezierPath(ovalIn: CGRect(x: midX - diameter / 2, y: y, width: diameter, height: height)).fill()
}

private func addQuadCurve(_ path: NSBezierPath, to end: NSPoint, control: NSPoint) {
    let start = path.currentPoint
    path.curve(
        to: end,
        controlPoint1: NSPoint(
            x: start.x + (control.x - start.x) * (2.0 / 3.0),
            y: start.y + (control.y - start.y) * (2.0 / 3.0)
        ),
        controlPoint2: NSPoint(
            x: end.x + (control.x - end.x) * (2.0 / 3.0),
            y: end.y + (control.y - end.y) * (2.0 / 3.0)
        )
    )
}

private func drawMeter(
    label: String,
    fraction: Double?,
    barX: CGFloat,
    barY: CGFloat,
    labelX: CGFloat,
    color: NSColor,
    cacheLabel: Bool
) {
    if cacheLabel, let cached = cachedLabels[label] {
        let labelY = barY + (barHeight - cached.size.height) / 2
        cached.string.draw(at: NSPoint(x: labelX + labelWidth - cached.size.width, y: labelY))
    } else {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let string = NSAttributedString(
            string: label,
            attributes: [.font: font, .foregroundColor: color]
        )
        let size = string.size()
        let labelY = barY + (barHeight - size.height) / 2
        string.draw(at: NSPoint(x: labelX + labelWidth - size.width, y: labelY))
    }
    if let fraction {
        drawBar(x: barX, y: barY, width: barWidth, height: barHeight, pct: fraction, color: color)
    } else {
        drawDashedBar(x: barX, y: barY, width: barWidth, height: barHeight, color: color)
    }
}

private func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, pct: Double, color: NSColor) {
    let bgRect = NSRect(x: x, y: y, width: width, height: height)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
    color.withAlphaComponent(0.25).setFill()
    bgPath.fill()

    let clamped = max(0, min(1, pct))
    if clamped > 0 {
        let fillRect = NSRect(x: x, y: y, width: width * clamped, height: height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius)
        color.setFill()
        fillPath.fill()
    }
}

private func drawDashedBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, color: NSColor) {
    let rect = NSRect(x: x, y: y, width: width, height: height)
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    color.withAlphaComponent(0.25).setStroke()
    path.lineWidth = 1
    let dashPattern: [CGFloat] = [2, 2]
    path.setLineDash(dashPattern, count: 2, phase: 0)
    path.stroke()
}

/// Scale about the visual bottom, then hop up. In a flipped image, up is negative y.
private func momentTransform(pose: BudMomentPose, around rect: CGRect) -> NSAffineTransform {
    let transform = NSAffineTransform()
    let hop = -pose.hop * rect.height
    let anchorY = rect.maxY
    transform.translateX(by: rect.midX, yBy: anchorY + hop)
    transform.scaleX(by: pose.scaleX, yBy: pose.scaleY)
    transform.translateX(by: -rect.midX, yBy: -anchorY)
    return transform
}

/// Translate to the bud center, hop, rotate, scale, then move back.
/// Hop is negative in the flipped menu-bar image, so the bud rises.
private func companionTransform(frame: CompanionMenuFrame, around rect: CGRect) -> NSAffineTransform {
    let transform = NSAffineTransform()
    let hop = -frame.celebrate * 2.4
    transform.translateX(by: rect.midX, yBy: rect.midY + hop)
    transform.rotate(byDegrees: frame.wiggle)
    let scale = 1 + frame.breathe * 0.06
    transform.scaleX(by: scale, yBy: scale)
    transform.translateX(by: -rect.midX, yBy: -rect.midY)
    return transform
}

private func drawMiniBud(mood: CompanionMood, in rect: CGRect, eyeOpen: CGFloat, moment: BudMomentPose = .rest) {
    let ink = JollyTheme.ink.nsColor
    let fill = JollyTheme.moodRGB(mood).nsColor
    let cream = JollyTheme.cream.nsColor

    cream.setFill()
    NSBezierPath(ovalIn: CGRect(
        x: rect.midX + rect.width * 0.02,
        y: rect.minY + rect.height * 0.02,
        width: rect.width * 0.26,
        height: rect.height * 0.20
    )).fill()

    let body = CGRect(
        x: rect.minX + rect.width * 0.08,
        y: rect.minY + rect.height * 0.20,
        width: rect.width * 0.84,
        height: rect.height * 0.74
    )
    let bodyPath = NSBezierPath(ovalIn: body)
    fill.setFill()
    bodyPath.fill()
    ink.setStroke()
    bodyPath.lineWidth = max(0.7, rect.width * 0.06)
    bodyPath.stroke()

    let open = (moment == .rest && mood == .asleep) ? CGFloat(0) : eyeOpen
    let shift = moment.glance * body.width * 0.10
    let left = body.minX + body.width * 0.22 + shift
    let right = body.minX + body.width * 0.58 + shift
    let eyeY = body.minY + body.height * 0.34
    if open < 0.25 {
        strokeMiniArc(x: left, y: eyeY, width: body.width * 0.20, color: ink)
        strokeMiniArc(x: right, y: eyeY, width: body.width * 0.20, color: ink)
    } else {
        let diameter = max(1.4, body.width * 0.16)
        ink.setFill()
        NSBezierPath(ovalIn: CGRect(x: left, y: eyeY, width: diameter, height: diameter * open)).fill()
        NSBezierPath(ovalIn: CGRect(x: right, y: eyeY, width: diameter, height: diameter * open)).fill()
    }

    let mouthWidth = mood == .playful ? body.width * 0.46 : body.width * 0.34
    let mouthRect = CGRect(
        x: body.midX - mouthWidth / 2,
        y: body.minY + body.height * 0.62,
        width: mouthWidth,
        height: body.height * 0.18
    )
    if moment.yawn > 0.08 {
        let oval = CGRect(
            x: mouthRect.minX,
            y: mouthRect.minY,
            width: mouthRect.width,
            height: mouthRect.height * (0.7 + moment.yawn * 1.6)
        )
        let path = NSBezierPath(ovalIn: oval)
        ink.setStroke()
        path.lineWidth = max(0.8, rect.width * 0.045)
        path.stroke()
    } else {
        strokeMiniMouth(mood.mouth, in: mouthRect, color: ink)
    }

    guard moment.sweat > 0.04 else { return }
    let drop = max(1.3, rect.width * 0.10)
    let x = rect.maxX - drop * 1.55
    let y = rect.minY + rect.height * 0.16 + rect.height * 0.42 * moment.sweat
    ink.setFill()
    NSBezierPath(ovalIn: CGRect(x: x, y: y, width: drop * 0.62, height: drop)).fill()
}

private func strokeMiniArc(x: CGFloat, y: CGFloat, width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    let baseY = y + width * 0.35
    path.move(to: NSPoint(x: x, y: baseY))
    addQuadCurve(
        path,
        to: NSPoint(x: x + width, y: baseY),
        control: NSPoint(x: x + width / 2, y: y)
    )
    color.setStroke()
    path.lineWidth = max(0.8, width * 0.18)
    path.lineCapStyle = .round
    path.stroke()
}

private func strokeMiniMouth(_ curve: MouthCurve, in rect: CGRect, color: NSColor) {
    let path = NSBezierPath()
    if curve == .flat {
        path.move(to: NSPoint(x: rect.minX, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
    } else {
        let smiling = curve.depth > 0.5
        let cornerY = smiling ? rect.minY : rect.maxY
        let controlY = rect.minY + rect.height * curve.depth
        path.move(to: NSPoint(x: rect.minX, y: cornerY))
        addQuadCurve(path, to: NSPoint(x: rect.maxX, y: cornerY), control: NSPoint(x: rect.midX, y: controlY))
    }
    color.setStroke()
    path.lineWidth = max(0.8, rect.height * 0.22)
    path.lineCapStyle = .round
    path.stroke()
}

private func drawTinyMeter(in rect: CGRect, fraction: Double?, color: NSColor) {
    let radius = rect.height / 2
    color.withAlphaComponent(0.28).setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    guard let fraction, fraction > 0 else { return }
    let width = rect.width * CGFloat(min(1, max(0, fraction)))
    guard width > 0.4 else { return }
    color.setFill()
    NSBezierPath(
        roundedRect: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
        xRadius: radius,
        yRadius: radius
    ).fill()
}
