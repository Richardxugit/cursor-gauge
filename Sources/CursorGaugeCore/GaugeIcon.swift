import AppKit

/// Draws the menu bar gauge: a flat-top hexagon that fills from the base.
///
/// While healthy the image is a *template*, so macOS tints it for light/dark mode,
/// menu bar transparency and Reduce Transparency automatically. It only opts out of
/// template rendering when it has something to warn about, because colour in the menu
/// bar should mean something.
public enum GaugeIcon {
    public static let defaultSize: CGFloat = 18

    /// Flat-top hexagon — vertices at 0°, 60°, … put flat edges at top and bottom, so a
    /// bottom-up fill sits on a flat base. A pointy-bottom hexagon tapers to a vertex
    /// and low fills read as a stray triangle.
    static func hexagon(centre: NSPoint, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        for index in 0..<6 {
            let angle = Double(index) * 60 * .pi / 180
            let point = NSPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.close()
        return path
    }

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
            let centre = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2 - 1
            // A flat-top hexagon spans less vertically than horizontally.
            let halfHeight = radius * CGFloat(sin(60 * Double.pi / 180))
            let outline = hexagon(centre: centre, radius: radius)

            if let fraction {
                let level = min(max(fraction, 0), 1)
                if level > 0 {
                    NSGraphicsContext.current?.saveGraphicsState()
                    hexagon(centre: centre, radius: radius - 1.9).addClip()
                    // Guarantee a visible sliver: any spend at all should show, and on a
                    // large limit a true-to-scale fill would round away to nothing.
                    let height = max(halfHeight * 2 * level, 1.8)
                    tint.setFill()
                    NSRect(
                        x: rect.minX, y: centre.y - halfHeight,
                        width: rect.width, height: height
                    ).fill()
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
            } else {
                // No published limit: a centre dot keeps the icon reading as live rather
                // than as an empty, broken shape.
                tint.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: centre.x - 1.6, y: centre.y - 1.6, width: 3.2, height: 3.2
                )).fill()
            }

            outline.lineWidth = 1.6
            tint.withAlphaComponent(0.9).setStroke()
            outline.stroke()
            return true
        }

        image.isTemplate = isTemplate
        image.accessibilityDescription = accessibilityDescription(fraction: fraction, level: level)
        return image
    }

    /// Gauge plus optional trailing text, composited into a single image.
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
        let gauge = image(fraction: fraction, level: level, size: size)
        guard let text, !text.isEmpty else {
            if dimmed { return dim(gauge) }
            return gauge
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
            gauge.draw(
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

    /// Shown when there's no reading at all — a stale gauge would imply data we don't have.
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
