import AppKit
import Foundation
import CursorGaugeCore

/// `CursorGauge --emit-preview <file.png>` draws the menu bar item at every threshold
/// level on both light and dark backgrounds.
///
/// Exists because the menu bar can't be screenshotted from a terminal without Screen
/// Recording permission, and "it compiles" is not evidence that a drawing routine
/// produces something legible.
enum PreviewRenderer {
    static func run(path: String) -> Never {
        let scale: CGFloat = 3
        let rowHeight: CGFloat = 30
        let width: CGFloat = 240

        let samples: [(label: String, fraction: Double?, level: GaugeLevel, text: String?, dimmed: Bool)] = [
            ("live", 0.0166, .normal, "$3.31", false),
            ("normal 25%", 0.25, .normal, "$50.00", false),
            ("pace warning", 0.32, .warning, "$64.00", false),
            ("warning 70%", 0.70, .warning, "$140", false),
            ("critical 92%", 0.92, .critical, "$184", false),
            ("over limit", 1.0, .critical, "$224", false),
            ("stale", 0.25, .normal, "$50.00", true),
            ("no limit", nil, .normal, "$50.00", false),
            ("percent mode", 0.0166, .normal, "1.7%", false),
            ("ring only", 0.45, .normal, nil, false),
        ]

        let size = NSSize(width: width * 2, height: rowHeight * CGFloat(samples.count))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { exit(1) }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

        for (index, sample) in samples.enumerated() {
            let y = size.height - rowHeight * CGFloat(index + 1)

            // Left half mimics a light menu bar, right half a dark one — template
            // images have to stay legible on both.
            NSColor(white: 0.92, alpha: 1).setFill()
            NSRect(x: 0, y: y, width: width, height: rowHeight).fill()
            NSColor(white: 0.14, alpha: 1).setFill()
            NSRect(x: width, y: y, width: width, height: rowHeight).fill()

            let image = GaugeIcon.menuBarImage(
                fraction: sample.fraction, level: sample.level,
                text: sample.text, dimmed: sample.dimmed
            )

            draw(image, at: NSPoint(x: 12, y: y + (rowHeight - image.size.height) / 2), tint: .black)
            draw(image, at: NSPoint(x: width + 12, y: y + (rowHeight - image.size.height) / 2), tint: .white)

            let caption = NSAttributedString(string: sample.label, attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor(white: 0.45, alpha: 1),
            ])
            caption.draw(at: NSPoint(x: width - 12 - caption.size().width, y: y + 9))
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("preview failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Template images carry only alpha, so reproduce what the menu bar does: fill the
    /// silhouette with the appropriate contrasting colour.
    ///
    /// The tint must be applied inside an isolated, transparent image. Compositing
    /// `.sourceAtop` straight onto the destination would tint every opaque pixel of the
    /// background too, turning the icon into a solid block.
    private static func draw(_ image: NSImage, at origin: NSPoint, tint: NSColor) {
        let rect = NSRect(origin: origin, size: image.size)
        guard image.isTemplate else {
            image.draw(in: rect)
            return
        }
        let tinted = NSImage(size: image.size, flipped: false) { bounds in
            image.draw(in: bounds)
            tint.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }
}
