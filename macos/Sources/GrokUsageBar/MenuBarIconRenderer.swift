import AppKit

private let glyphSize: CGFloat = 13
private let barWidth: CGFloat = 28
private let barHeight: CGFloat = 6
private let gap: CGFloat = 3
private let iconWidth: CGFloat = glyphSize + gap + barWidth
private let iconHeight: CGFloat = 18
private let cornerRadius: CGFloat = 2

/// Neutral menu-bar glyph: a small bar mark plus one weekly usage bar.
/// Drawn as a template image. Not an xAI or Grok logo.
func renderIcon(weeklyFraction: Double?) -> NSImage {
    let image = NSImage(size: NSSize(width: iconWidth, height: iconHeight), flipped: true) { _ in
        drawGlyph(x: 0, y: (iconHeight - glyphSize) / 2, size: glyphSize)
        let barX = glyphSize + gap
        let barY = (iconHeight - barHeight) / 2
        if let weeklyFraction {
            drawBar(x: barX, y: barY, width: barWidth, height: barHeight, pct: weeklyFraction)
        } else {
            drawDashedBar(x: barX, y: barY, width: barWidth, height: barHeight)
        }
        return true
    }
    image.isTemplate = true
    return image
}

func renderUnauthenticatedIcon() -> NSImage {
    renderIcon(weeklyFraction: nil)
}

private func drawGlyph(x: CGFloat, y: CGFloat, size: CGFloat) {
    let rect = NSRect(x: x, y: y, width: size, height: size)
    let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
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
