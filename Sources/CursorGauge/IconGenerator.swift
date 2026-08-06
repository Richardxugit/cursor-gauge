import AppKit
import Foundation
import CursorGaugeCore

/// `CursorGauge --emit-iconset <dir>` renders the Finder/Settings icon.
///
/// Generating it from code keeps the app icon and the menu bar gauge visually identical,
/// and avoids checking a binary asset into the repo.
enum IconGenerator {
    static func run(directory: String) -> Never {
        let base = URL(fileURLWithPath: directory)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // The sizes `iconutil` expects in an .iconset.
            let variants: [(name: String, pixels: Int)] = [
                ("icon_16x16", 16), ("icon_16x16@2x", 32),
                ("icon_32x32", 32), ("icon_32x32@2x", 64),
                ("icon_128x128", 128), ("icon_128x128@2x", 256),
                ("icon_256x256", 256), ("icon_256x256@2x", 512),
                ("icon_512x512", 512), ("icon_512x512@2x", 1024),
            ]
            for variant in variants {
                let data = try png(size: variant.pixels)
                try data.write(to: base.appendingPathComponent("\(variant.name).png"))
            }
            print("wrote \(variants.count) images to \(base.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("icon generation failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func png(size: Int) throws -> Data {
        let dimension = CGFloat(size)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw CocoaError(.fileWriteUnknown) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

        let rect = NSRect(x: 0, y: 0, width: dimension, height: dimension)
        // macOS app icons sit inside a rounded square with a little breathing room.
        let inset = dimension * 0.08
        let plate = NSBezierPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            xRadius: dimension * 0.2, yRadius: dimension * 0.2
        )
        NSGradient(
            starting: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.21, alpha: 1),
            ending: NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.12, alpha: 1)
        )?.draw(in: plate, angle: -90)

        // Same flat-top hexagon and same pie fill as the menu bar item, so the two read
        // as one mark.
        let lineWidth = dimension * 0.055
        let radius = dimension * 0.30
        let centre = NSPoint(x: rect.midX, y: rect.midY)

        func hexagon(radius: CGFloat) -> NSBezierPath {
            GaugeIcon.hexagon(centre: centre, radius: radius)
        }

        NSGraphicsContext.current?.saveGraphicsState()
        hexagon(radius: radius - lineWidth * 1.4).addClip()
        NSColor(calibratedRed: 0.36, green: 0.71, blue: 1.0, alpha: 1).setFill()
        GaugeIcon.wedge(centre: centre, radius: radius, fraction: 0.62).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let outline = hexagon(radius: radius)
        outline.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(0.9).setStroke()
        outline.stroke()

        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
