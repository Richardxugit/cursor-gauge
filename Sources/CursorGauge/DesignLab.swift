import AppKit
import Foundation
import CursorGaugeCore

/// `CursorGauge --design-lab <file.png>` renders candidate menu bar shapes side by side.
///
/// Menu bar icons live or die at 18pt, so each candidate is drawn at true size and then
/// magnified with interpolation switched off — what you see is the actual pixels, not a
/// flattering large-scale redraw.
enum DesignLab {
    /// A candidate is just a drawing routine over (spend, pace) in 0...1.
    private struct Candidate {
        let name: String
        let note: String
        let draw: (NSRect, Double, Double) -> Void
    }

    private static let candidates: [Candidate] = [
        Candidate(name: "F1 · pointy-bottom", note: "as shown before — fill reads as a triangle", draw: drawCube2),
        Candidate(name: "F2 · flat-bottom", note: "vessel fills against a flat base", draw: drawCubeFlat),
        Candidate(name: "F3 · flat + pace line", note: "flat-bottom plus calendar waterline", draw: drawCubeFlatPace),
        Candidate(name: "F4 · nested hexagon", note: "concentric, area-proportional", draw: drawCubeNested),
    ]

    private static let fills: [(spend: Double, pace: Double, caption: String)] = [
        (0.018, 0.046, "1.8% (today)"),
        (0.35, 0.30, "35%"),
        (0.78, 0.55, "78%"),
    ]

    static func run(path: String) -> Never {
        let iconPoints: CGFloat = 18
        let magnification: CGFloat = 7
        let cellW = iconPoints * magnification + 26
        let cellH = iconPoints * magnification + 34
        let labelW: CGFloat = 210
        let actualStripW: CGFloat = 150

        let width = labelW + cellW * CGFloat(fills.count) + actualStripW
        let height = cellH * CGFloat(candidates.count) + 46

        guard let sheet = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { exit(1) }
        sheet.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)

        // Dark background: the menu bar is dark far more often than not.
        NSColor(white: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // Column headings
        for (index, fill) in fills.enumerated() {
            caption(fill.caption, at: NSPoint(x: labelW + cellW * CGFloat(index) + 8, y: height - 26), size: 11)
        }
        caption("actual size", at: NSPoint(x: labelW + cellW * CGFloat(fills.count) + 8, y: height - 26), size: 11)

        for (row, candidate) in candidates.enumerated() {
            let top = height - 46 - cellH * CGFloat(row)

            caption(candidate.name, at: NSPoint(x: 14, y: top - 34), size: 13, white: 0.95)
            caption(candidate.note, at: NSPoint(x: 14, y: top - 52), size: 10, white: 0.5)

            for (column, fill) in fills.enumerated() {
                let icon = render(candidate, spend: fill.spend, pace: fill.pace, points: iconPoints)
                let origin = NSPoint(x: labelW + cellW * CGFloat(column) + 8, y: top - cellH + 20)
                magnified(icon, at: origin, points: iconPoints, factor: magnification)
            }

            // True-size row, on dark and on light, to check legibility both ways.
            var x = labelW + cellW * CGFloat(fills.count) + 12
            let y = top - cellH / 2 - iconPoints / 2 + 10
            for fill in fills {
                let icon = render(candidate, spend: fill.spend, pace: fill.pace, points: iconPoints)
                NSColor(white: 0.13, alpha: 1).setFill()
                NSRect(x: x - 2, y: y - 3, width: iconPoints + 4, height: iconPoints + 6).fill()
                tinted(icon, white: true).draw(in: NSRect(x: x, y: y, width: iconPoints, height: iconPoints))

                NSColor(white: 0.88, alpha: 1).setFill()
                NSRect(x: x - 2, y: y - iconPoints - 12, width: iconPoints + 4, height: iconPoints + 6).fill()
                tinted(icon, white: false).draw(in: NSRect(x: x, y: y - iconPoints - 9, width: iconPoints, height: iconPoints))

                x += iconPoints + 12
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let data = sheet.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("design lab failed: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Drawing helpers

    private static func render(_ candidate: Candidate, spend: Double, pace: Double, points: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: points, height: points), flipped: false) { rect in
            candidate.draw(rect, spend, pace)
            return true
        }
    }

    /// Magnify with interpolation off so individual pixels stay square and honest.
    private static func magnified(_ image: NSImage, at origin: NSPoint, points: CGFloat, factor: CGFloat) {
        let target = NSRect(x: origin.x, y: origin.y, width: points * factor, height: points * factor)
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        tinted(image, white: true).draw(in: target)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private static func tinted(_ image: NSImage, white: Bool) -> NSImage {
        NSImage(size: image.size, flipped: false) { bounds in
            image.draw(in: bounds)
            (white ? NSColor.white : NSColor.black).set()
            bounds.fill(using: .sourceAtop)
            return true
        }
    }

    private static func caption(_ text: String, at point: NSPoint, size: CGFloat, white: CGFloat = 0.6) {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor(white: white, alpha: 1),
        ]).draw(at: point)
    }

    // MARK: - Candidates
    //
    // All draw in black; the sheet tints them the way the menu bar tints a template.

    private static func drawRing(_ rect: NSRect, _ spend: Double, _ pace: Double) {
        let line: CGFloat = 2
        let radius = (min(rect.width, rect.height) - line) / 2 - 0.5
        let centre = NSPoint(x: rect.midX, y: rect.midY)

        let track = NSBezierPath()
        track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = line
        NSColor.black.withAlphaComponent(0.25).setStroke()
        track.stroke()

        guard spend > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: radius, startAngle: 90, endAngle: 90 - 360 * spend, clockwise: true)
        arc.lineWidth = line
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        arc.stroke()
    }

    private static func drawBoldRing(_ rect: NSRect, _ spend: Double, _ pace: Double) {
        let line: CGFloat = 2.75
        let radius = (min(rect.width, rect.height) - line) / 2 - 0.5
        let centre = NSPoint(x: rect.midX, y: rect.midY)

        let track = NSBezierPath()
        track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = line
        NSColor.black.withAlphaComponent(0.3).setStroke()
        track.stroke()

        if spend > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: centre, radius: radius, startAngle: 90, endAngle: 90 - 360 * spend, clockwise: true)
            arc.lineWidth = line
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
        }

        // Notch cut through the ring at the calendar position.
        let angle = (90 - 360 * pace) * .pi / 180
        let inner = radius - line / 2 - 0.5
        let outer = radius + line / 2 + 1.5
        let notch = NSBezierPath()
        notch.move(to: NSPoint(x: centre.x + cos(angle) * inner, y: centre.y + sin(angle) * inner))
        notch.line(to: NSPoint(x: centre.x + cos(angle) * outer, y: centre.y + sin(angle) * outer))
        notch.lineWidth = 1.5
        NSColor.black.setStroke()
        notch.stroke()
    }

    // MARK: Refined candidates

    /// Speedometer, v2: bigger dial, finer needle, pace shown as a tick outside the arc
    /// so it never collides with the fill.
    private static func drawSpeedometer2(_ rect: NSRect, _ spend: Double, _ pace: Double) {
        let line: CGFloat = 2.4
        let radius = (min(rect.width, rect.height) - line) / 2 - 0.5
        let centre = NSPoint(x: rect.midX, y: rect.midY - 1.5)
        let sweep: Double = 252
        let start: Double = 216

        let track = NSBezierPath()
        track.appendArc(withCenter: centre, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
        track.lineWidth = line
        track.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.26).setStroke()
        track.stroke()

        if spend > 0.004 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: centre, radius: radius, startAngle: start, endAngle: start - sweep * spend, clockwise: true)
            arc.lineWidth = line
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
        }

        // Calendar tick, sitting just inside the dial.
        if pace > 0.01 {
            let angle = (start - sweep * pace) * .pi / 180
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: centre.x + cos(angle) * (radius - line / 2 - 0.6),
                                  y: centre.y + sin(angle) * (radius - line / 2 - 0.6)))
            tick.line(to: NSPoint(x: centre.x + cos(angle) * (radius - line / 2 - 3),
                                  y: centre.y + sin(angle) * (radius - line / 2 - 3)))
            tick.lineWidth = 1.2
            NSColor.black.withAlphaComponent(0.6).setStroke()
            tick.stroke()
        }

        let angle = (start - sweep * spend) * .pi / 180
        let needle = NSBezierPath()
        needle.move(to: NSPoint(x: centre.x - cos(angle) * 1.5, y: centre.y - sin(angle) * 1.5))
        needle.line(to: NSPoint(x: centre.x + cos(angle) * (radius - 3.2), y: centre.y + sin(angle) * (radius - 3.2)))
        needle.lineWidth = 1.4
        needle.lineCapStyle = .round
        NSColor.black.setStroke()
        needle.stroke()

        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - 1.3, y: centre.y - 1.3, width: 2.6, height: 2.6)).fill()
    }

    /// Pill, v2: the pace marker becomes a small notch under the body instead of a bar
    /// slicing through it.
    private static func drawPill2(_ rect: NSRect, _ spend: Double, _ pace: Double) {
        // Must be clearly wider than tall, or the fill degenerates into a blob and the
        // shape stops reading as a meter at all.
        let height: CGFloat = 8.5
        let body = NSRect(x: rect.minX + 0.25, y: rect.midY - height / 2, width: rect.width - 3.25, height: height)
        let radius = height / 2

        let outline = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        outline.lineWidth = 1.4
        NSColor.black.withAlphaComponent(0.5).setStroke()
        outline.stroke()

        let nub = NSBezierPath(roundedRect: NSRect(x: body.maxX + 1.4, y: rect.midY - 2.6, width: 1.9, height: 5.2), xRadius: 0.9, yRadius: 0.9)
        NSColor.black.withAlphaComponent(0.5).setFill()
        nub.fill()

        let inset = body.insetBy(dx: 1.9, dy: 1.9)
        if spend > 0 {
            let fill = NSRect(x: inset.minX, y: inset.minY,
                              width: max(inset.height, inset.width * spend), height: inset.height)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: fill, xRadius: inset.height / 2, yRadius: inset.height / 2).fill()
        }

        // Pace notch: a stub below the body, out of the fill's way.
        let markX = inset.minX + inset.width * pace
        let notch = NSBezierPath()
        notch.move(to: NSPoint(x: markX, y: body.minY - 0.4))
        notch.line(to: NSPoint(x: markX, y: body.minY - 3))
        notch.lineWidth = 1.3
        notch.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.75).setStroke()
        notch.stroke()
    }

    /// Cube, v2: fill is clipped to an inset hexagon so the outline stays crisp and the
    /// waterline never merges with the stroke.
    private static func drawCube2(_ rect: NSRect, _ spend: Double, _ pace: Double) {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        func hexagon(radius: CGFloat) -> NSBezierPath {
            let path = NSBezierPath()
            for index in 0..<6 {
                let angle = (90 + Double(index) * 60) * .pi / 180
                let point = NSPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
                index == 0 ? path.move(to: point) : path.line(to: point)
            }
            path.close()
            return path
        }

        let outerRadius = min(rect.width, rect.height) / 2 - 1
        let outline = hexagon(radius: outerRadius)

        NSGraphicsContext.current?.saveGraphicsState()
        hexagon(radius: outerRadius - 2.1).addClip()
        let bottom = centre.y - outerRadius
        NSColor.black.setFill()
        NSRect(x: rect.minX, y: bottom, width: rect.width, height: outerRadius * 2 * spend).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        outline.lineWidth = 1.6
        NSColor.black.withAlphaComponent(0.9).setStroke()
        outline.stroke()
    }

    // MARK: Cube variants

    /// Flat-top orientation: vertices at 0°, 60°… put edges at top and bottom, so a
    /// bottom-up fill sits on a flat base instead of tapering into a point.
    private static func hexagon(centre: NSPoint, radius: CGFloat, flatBottom: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        let offset: Double = flatBottom ? 0 : 90
        for index in 0..<6 {
            let angle = (offset + Double(index) * 60) * .pi / 180
            let point = NSPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.close()
        return path
    }

    private static func drawCubeFlat(_ rect: NSRect, _ spend: Double, _ pace: Double) {
        drawVessel(rect, spend: spend, pace: nil)
    }

    private static func drawCubeFlatPace(_ rect: NSRect, _ spend: Double, _ pace: Double) {
        drawVessel(rect, spend: spend, pace: pace)
    }

    private static func drawVessel(_ rect: NSRect, spend: Double, pace: Double?) {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        // Flat-top hexagons are wider than tall, so size from the width.
        let radius = rect.width / 2 - 1
        let outline = hexagon(centre: centre, radius: radius, flatBottom: true)

        // A flat-top hexagon only spans radius * sin(60°) vertically.
        let halfHeight = radius * CGFloat(sin(60 * Double.pi / 180))
        let bottom = centre.y - halfHeight

        NSGraphicsContext.current?.saveGraphicsState()
        hexagon(centre: centre, radius: radius - 1.9, flatBottom: true).addClip()
        NSColor.black.setFill()
        NSRect(x: rect.minX, y: bottom, width: rect.width, height: halfHeight * 2 * CGFloat(spend)).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        if let pace, pace > 0.02, pace < 0.99 {
            // Calendar level, drawn as a short dash on the fill's own axis.
            NSGraphicsContext.current?.saveGraphicsState()
            hexagon(centre: centre, radius: radius - 1.9, flatBottom: true).addClip()
            let y = bottom + halfHeight * 2 * CGFloat(pace)
            let dash = NSBezierPath()
            dash.move(to: NSPoint(x: rect.minX, y: y))
            dash.line(to: NSPoint(x: rect.maxX, y: y))
            dash.lineWidth = 1.2
            NSColor.black.withAlphaComponent(0.55).setStroke()
            dash.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        outline.lineWidth = 1.6
        NSColor.black.withAlphaComponent(0.9).setStroke()
        outline.stroke()
    }

    /// Concentric fill: the inner hexagon's *area* tracks spend, so it grows evenly
    /// rather than sweeping past a waterline.
    private static func drawCubeNested(_ rect: NSRect, _ spend: Double, _ pace: Double) {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 - 1

        if spend > 0 {
            // Area scales with radius², so take the square root to keep growth linear.
            let innerRadius = (radius - 2.2) * CGFloat(sqrt(spend))
            NSColor.black.setFill()
            hexagon(centre: centre, radius: max(innerRadius, 1.2), flatBottom: true).fill()
        }

        let outline = hexagon(centre: centre, radius: radius, flatBottom: true)
        outline.lineWidth = 1.6
        NSColor.black.withAlphaComponent(0.9).setStroke()
        outline.stroke()
    }

    private static func drawSpeedometer(_ rect: NSRect, _ spend: Double, _ pace: Double) {
        let line: CGFloat = 2.25
        let radius = (min(rect.width, rect.height) - line) / 2 - 1
        let centre = NSPoint(x: rect.midX, y: rect.midY - 1)
        let sweep: Double = 250
        let start: Double = 215                       // lower-left, sweeping clockwise

        let track = NSBezierPath()
        track.appendArc(withCenter: centre, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
        track.lineWidth = line
        track.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.28).setStroke()
        track.stroke()

        if spend > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: centre, radius: radius, startAngle: start, endAngle: start - sweep * spend, clockwise: true)
            arc.lineWidth = line
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
        }

        // Needle: gives the icon something to read even when the arc is empty.
        let angle = (start - sweep * spend) * .pi / 180
        let needle = NSBezierPath()
        needle.move(to: centre)
        needle.line(to: NSPoint(x: centre.x + cos(angle) * (radius - 2.5), y: centre.y + sin(angle) * (radius - 2.5)))
        needle.lineWidth = 1.5
        needle.lineCapStyle = .round
        NSColor.black.setStroke()
        needle.stroke()

        NSBezierPath(ovalIn: NSRect(x: centre.x - 1.5, y: centre.y - 1.5, width: 3, height: 3)).fill()
    }

    private static func drawPill(_ rect: NSRect, _ spend: Double, _ pace: Double) {
        let width = rect.width - 1
        let height: CGFloat = 10
        let body = NSRect(x: rect.minX + 0.5, y: rect.midY - height / 2, width: width - 2.5, height: height)
        let radius = height / 2

        let outline = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        outline.lineWidth = 1.25
        NSColor.black.withAlphaComponent(0.55).setStroke()
        outline.stroke()

        // Terminal nub, like the battery icon's cap.
        let nub = NSBezierPath(roundedRect: NSRect(x: body.maxX + 1.25, y: rect.midY - 2.5, width: 1.75, height: 5), xRadius: 0.8, yRadius: 0.8)
        NSColor.black.withAlphaComponent(0.55).setFill()
        nub.fill()

        let inset = body.insetBy(dx: 2, dy: 2)
        if spend > 0 {
            let fill = NSRect(x: inset.minX, y: inset.minY, width: max(1.5, inset.width * spend), height: inset.height)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: fill, xRadius: inset.height / 2, yRadius: inset.height / 2).fill()
        }

        let markX = inset.minX + inset.width * pace
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: markX, y: body.minY - 1.5))
        mark.line(to: NSPoint(x: markX, y: body.maxY + 1.5))
        mark.lineWidth = 1.25
        NSColor.black.setStroke()
        mark.stroke()
    }

    private static func drawSegmented(_ rect: NSRect, _ spend: Double, _ pace: Double) {
        let segments = 16
        let radius = min(rect.width, rect.height) / 2 - 2
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let lit = Int((Double(segments) * spend).rounded(.up))

        for index in 0..<segments {
            let angle = (90 - Double(index) * 360 / Double(segments)) * .pi / 180
            let isLit = index < lit
            let inner = radius - (isLit ? 5.0 : 3.5)
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: centre.x + cos(angle) * inner, y: centre.y + sin(angle) * inner))
            tick.line(to: NSPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius))
            tick.lineWidth = 2
            tick.lineCapStyle = .round
            NSColor.black.withAlphaComponent(isLit ? 1 : 0.28).setStroke()
            tick.stroke()
        }
    }

    private static func drawCube(_ rect: NSRect, _ spend: Double, _ pace: Double) {
        // Flat-top hexagon, echoing Cursor's mark.
        let radius = min(rect.width, rect.height) / 2 - 1.25
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let hexagon = NSBezierPath()
        for index in 0..<6 {
            let angle = (90 + Double(index) * 60) * .pi / 180
            let point = NSPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            index == 0 ? hexagon.move(to: point) : hexagon.line(to: point)
        }
        hexagon.close()

        // Fill from the bottom up, clipped to the silhouette.
        NSGraphicsContext.current?.saveGraphicsState()
        hexagon.addClip()
        let level = rect.minY + rect.height * spend
        NSColor.black.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: level - rect.minY).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        hexagon.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.85).setStroke()
        hexagon.stroke()
    }
}
