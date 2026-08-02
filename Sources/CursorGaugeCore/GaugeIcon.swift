import AppKit

/// Draws the menu bar ring.
///
/// While healthy the image is a *template*, so macOS tints it for light/dark mode,
/// menu bar transparency and Reduce Transparency automatically. It only opts out of
/// template rendering when it has something to warn about, because colour in the menu
/// bar should mean something.
public enum GaugeIcon {
    public static let defaultSize: CGFloat = 18

    public static func image(
        fraction: Double?,
        level: GaugeLevel,
        size: CGFloat = defaultSize
    ) -> NSImage {
        let isTemplate = (level == .normal)
        let tint: NSColor
        switch level {
        case .normal: tint = .black          // ignored once template rendering kicks in
        case .warning: tint = .systemOrange
        case .critical: tint = .systemRed
        }

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let lineWidth: CGFloat = 2
            let radius = (min(rect.width, rect.height) - lineWidth) / 2 - 0.5
            let center = NSPoint(x: rect.midX, y: rect.midY)

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            tint.withAlphaComponent(0.25).setStroke()
            track.stroke()

            guard let fraction else {
                // No published limit: show a centre dot so the icon still reads as live
                // rather than as an empty, broken ring.
                let dot = NSBezierPath(ovalIn: NSRect(
                    x: center.x - lineWidth, y: center.y - lineWidth,
                    width: lineWidth * 2, height: lineWidth * 2
                ))
                tint.setFill()
                dot.fill()
                return true
            }

            let swept = min(max(fraction, 0), 1)
            guard swept > 0 else { return true }

            // Start at 12 o'clock and fill clockwise, the way a dial reads.
            let progress = NSBezierPath()
            progress.appendArc(
                withCenter: center, radius: radius,
                startAngle: 90, endAngle: 90 - 360 * swept,
                clockwise: true
            )
            progress.lineWidth = lineWidth
            progress.lineCapStyle = .round
            tint.setStroke()
            progress.stroke()
            return true
        }

        image.isTemplate = isTemplate
        image.accessibilityDescription = accessibilityDescription(fraction: fraction, level: level)
        return image
    }

    /// Ring plus optional trailing text, composited into a single image.
    ///
    /// SwiftUI's `MenuBarExtra` label renders an image and a text view inconsistently
    /// when both are present, so the whole thing is drawn once here instead. It also
    /// lets the digits use a monospaced face, which stops the menu bar shuffling every
    /// time a figure ticks over.
    public static func menuBarImage(
        fraction: Double?,
        level: GaugeLevel,
        text: String?,
        dimmed: Bool = false,
        size: CGFloat = defaultSize
    ) -> NSImage {
        let ring = image(fraction: fraction, level: level, size: size)
        guard let text, !text.isEmpty else {
            if dimmed { return dim(ring) }
            return ring
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let colour: NSColor
        switch level {
        case .normal: colour = .black          // template rendering recolours this
        case .warning: colour = .systemOrange
        case .critical: colour = .systemRed
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()

        let gap: CGFloat = 4
        let total = NSSize(width: size + gap + ceil(textSize.width), height: size)

        let composite = NSImage(size: total, flipped: false) { _ in
            ring.draw(
                in: NSRect(x: 0, y: 0, width: size, height: size),
                from: .zero, operation: .sourceOver, fraction: 1
            )
            attributed.draw(at: NSPoint(x: size + gap, y: (size - textSize.height) / 2))
            return true
        }
        composite.isTemplate = (level == .normal)
        composite.accessibilityDescription = accessibilityDescription(fraction: fraction, level: level)
        return dimmed ? dim(composite) : composite
    }

    /// Fades the whole item when the reading is stale, so old numbers don't read as live.
    private static func dim(_ source: NSImage) -> NSImage {
        let faded = NSImage(size: source.size, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.4)
            return true
        }
        faded.isTemplate = source.isTemplate
        faded.accessibilityDescription = source.accessibilityDescription
        return faded
    }

    /// Shown when there's no reading at all — a stale ring would imply data we don't have.
    public static func problemImage(size: CGFloat = defaultSize) -> NSImage {
        let symbol = NSImage(
            systemSymbolName: "exclamationmark.triangle",
            accessibilityDescription: "Cursor usage unavailable"
        )
        let image = symbol ?? image(fraction: nil, level: .normal, size: size)
        image.isTemplate = true
        return image
    }

    public static func accessibilityDescription(fraction: Double?, level: GaugeLevel) -> String {
        guard let fraction else { return "Cursor usage, no limit set" }
        let suffix: String
        switch level {
        case .normal: suffix = ""
        case .warning: suffix = ", approaching limit"
        case .critical: suffix = ", near limit"
        }
        return "Cursor usage \(Format.percent(fraction)) of limit" + suffix
    }
}
