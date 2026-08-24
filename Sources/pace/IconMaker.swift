import AppKit

/// Draws the app icon (for the .icns, via make-app.sh) and the menu-bar glyph.
/// No external tooling: pure AppKit drawing.
enum IconMaker {

    // A round googly eye. Square canvas; template so macOS tints it.
    private static let glyphW: CGFloat = 18
    private static let glyphH: CGFloat = 18

    /// Menu-bar template image: a round googly eye — a thin rim with a bold pupil
    /// resting low, the way a loose googly pupil settles under gravity. (During a
    /// break the app shows animated googly eyes; this is the calm static one.)
    /// `strain` is elapsed / eye interval: 0 just rested, 1 the break is due, and
    /// above 1 overdue — the eye keeps getting worse, so putting a break off over
    /// and over is visible on the bar. Paused adds a bold slash and drops the pupil.
    static func statusImage(paused: Bool, nudge: Bool = false, strain: CGFloat = 0) -> NSImage {
        let img = NSImage(size: NSSize(width: glyphW, height: glyphH), flipped: false) { _ in
            drawEye(paused: paused, nudge: nudge, strain: strain, color: .black)
            return true
        }
        img.isTemplate = true
        return img
    }

    // Eye geometry, in the 18x18 glyph space.
    private static let halfW: CGFloat = 7.3        // rim half-width (unchanged from the old oval)
    private static let restPupilR: CGFloat = 3.0   // just rested: loose, small, sitting low
    private static let strainPupilR: CGFloat = 4.4 // break due: blown, but a ring of white still shows
    private static let restPupilY: CGFloat = 7.1

    // Overdue: what a break that has been put off rather than taken looks like.
    // The rule is that it must get *heavier*, never fainter. A thin hairline reads
    // as "off" at 18pt; a solid mass reads as "look at me", which is the point.
    private static let overduePupilR: CGFloat = 8.4   // past due the pupil bursts the lid and floods the eye
    private static let dueSquint: CGFloat = 0.10      // a hint of a heavy lid in the last stretch
    private static let overdueGrow: CGFloat = 0.10    // past due the whole eye swells
    private static let overdueSag: CGFloat = 0.6      // and settles lower, the way a tired eye does

    /// How wide the lid is open, 1 = fully. A hint of a heavy upper lid arrives in
    /// the last stretch before the break, and that is the *only* narrowing there is.
    /// An earlier version kept closing the lid once overdue, which shrank the glyph
    /// by a quarter — the icon getting quieter the more rest you owe, exactly
    /// backwards. Overdue swells instead; see `overdueGrow`.
    private static func openness(_ strain: CGFloat) -> CGFloat {
        strain > 0.7 ? 1 - dueSquint * ((strain - 0.7) / 0.3) : 1
    }

    /// The eye outline: a lens through (cx ± halfW, cy) bulging `top` above the
    /// centre and `bottom` below. Equal bulges of halfW give a circle; a smaller
    /// top alone is the heavy upper lid of a tired eye.
    private static func eyePath(cx: CGFloat, cy: CGFloat, halfW: CGFloat, top: CGFloat, bottom: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()   // control offset 4/3 * bulge traces a semicircle when bulge == halfW
        p.move(to: NSPoint(x: cx - halfW, y: cy))
        p.curve(to: NSPoint(x: cx + halfW, y: cy),
                controlPoint1: NSPoint(x: cx - halfW, y: cy + top * 4 / 3),
                controlPoint2: NSPoint(x: cx + halfW, y: cy + top * 4 / 3))
        p.curve(to: NSPoint(x: cx - halfW, y: cy),
                controlPoint1: NSPoint(x: cx + halfW, y: cy - bottom * 4 / 3),
                controlPoint2: NSPoint(x: cx - halfW, y: cy - bottom * 4 / 3))
        p.close()
        return p
    }

    /// The eye's shape at one strain. Pulled out so the glyph and the invariant
    /// check below are measuring the same geometry, not two copies of it.
    private struct Shape {
        let cx: CGFloat, cy: CGFloat
        let halfW: CGFloat
        let top: CGFloat, bottom: CGFloat
        let s: CGFloat        // 0…1: filling up to the break being due
        let over: CGFloat     // 0…1: overdue by that much of another interval

        var outline: NSBezierPath { eyePath(cx: cx, cy: cy, halfW: halfW, top: top, bottom: bottom) }
    }

    private static func shape(paused: Bool, strain: CGFloat) -> Shape {
        let raw = paused ? 0 : max(0, min(2, strain))   // a paused eye rests, whatever the counter says
        let s = min(1, raw)
        let over = max(0, raw - 1)
        // The upper lid does nearly all the closing; the lower one barely moves.
        let open = openness(s)
        let w = halfW * (1 + overdueGrow * over)        // overdue: the whole eye swells
        return Shape(cx: glyphW / 2,
                     cy: glyphH / 2 - overdueSag * over,   // ...and settles lower
                     halfW: w,
                     top: w * open,
                     bottom: w * (0.35 + 0.65 * open),
                     s: s, over: over)
    }

    /// Draw the googly eye into the current context (glyphW x glyphH space).
    /// `nudge` glances the pupil up and away, the on-call "look away" cue.
    static func drawEye(paused: Bool, nudge: Bool = false, strain: CGFloat = 0, color: NSColor) {
        color.set()
        let g = shape(paused: paused, strain: strain)
        let cx = g.cx, cy = g.cy, top = g.top, bottom = g.bottom, s = g.s, over = g.over

        let rim = g.outline
        rim.lineWidth = 1.5
        rim.stroke()

        if paused {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 4.0, y: 4.6)); slash.line(to: NSPoint(x: glyphW - 4.0, y: glyphH - 4.6))
            slash.lineWidth = 1.7; slash.lineCapStyle = .round; slash.stroke()
            return
        }

        if nudge {
            let r: CGFloat = 3.1                      // the glance-away cue keeps its own calm pupil
            NSBezierPath(ovalIn: NSRect(x: cx - 2.3 - r, y: 11.4 - r, width: 2 * r, height: 2 * r)).fill()
            return
        }

        // The pupil dilates with time since the last eye break: loose and low when
        // rested, blown and filling the eye when the break is due, then past due it
        // floods the whole eye solid — a light ring with a dot when you're rested,
        // a heavy filled mass when you've been putting the break off.
        let flood = min(1, over / 0.5)   // fully flooded half an interval past due, then it just sits lower
        let r = restPupilR + (strainPupilR - restPupilR) * s + (overduePupilR - strainPupilR) * flood
        let eyeMid = cy + (top - bottom) / 2          // the lens sinks as the lid drops
        let py = restPupilY + (eyeMid - restPupilY) * s
        // The white of the eye thins to nothing as it floods, so the fill and the
        // rim merge into one shape instead of leaving a hairline gap.
        let white = 1.05 * (1 - flood)
        NSGraphicsContext.saveGraphicsState()
        eyePath(cx: cx, cy: cy, halfW: g.halfW - white, top: top - white, bottom: bottom - white).addClip()
        NSBezierPath(ovalIn: NSRect(x: cx - r, y: py - r, width: 2 * r, height: 2 * r)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: the invariant

    /// What the glyph actually puts on screen at one strain: how much ink, and how
    /// much of the eye that ink fills.
    struct Measure {
        let strain: CGFloat
        let ink: Double        // total coverage, in glyph-space units
        let silhouette: Double // coverage of the eye outline filled solid
        /// 0 = an empty ring, 1 = a solid mass. The design's whole language.
        var solidity: Double { silhouette > 0 ? min(1, ink / silhouette) : 0 }
    }

    /// Measure the glyph by rendering it and adding up coverage. The design rests
    /// on two claims that are easy to break with a one-line tweak to a constant,
    /// so they're measured rather than eyeballed: solidity never falls as strain
    /// rises (hollow when rested, solid when overdue), and the ink never drops
    /// below the rested glyph (it must never thin to a hairline, which at menu-bar
    /// size reads as "off" rather than "tired").
    static func measure(strain: CGFloat, samples: Int = 240) -> Measure {
        let g = shape(paused: false, strain: strain)
        return Measure(strain: strain,
                       ink: coverage(samples) { drawEye(paused: false, strain: strain, color: .black) },
                       silhouette: coverage(samples) { NSColor.black.set(); g.outline.fill() })
    }

    /// Total alpha laid down by `draw`, scaled back into glyph-space units so the
    /// number doesn't depend on the sample count.
    private static func coverage(_ samples: Int, _ draw: () -> Void) -> Double {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: samples, pixelsHigh: samples,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let scale = CGFloat(samples) / glyphW
        ctx.cgContext.scaleBy(x: scale, y: scale)
        draw()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return 0 }
        var total = 0.0
        for row in 0..<rep.pixelsHigh {
            let base = row * rep.bytesPerRow
            for col in 0..<rep.pixelsWide {
                total += Double(data[base + col * 4 + 3]) / 255.0
            }
        }
        return total / Double(scale * scale)
    }

    /// Render the glyph big for review, black-on-light or white-on-dark (as the
    /// bar would tint it). `pace --make-menuicon <path> [paused] [dark] [nudge] [strain <0…1>]`.
    static func writeMenuIconPreview(to path: String, paused: Bool, dark: Bool, nudge: Bool = false, strain: CGFloat = 0, height: Int = 360) -> Bool {
        let w = Int(CGFloat(height) * glyphW / glyphH)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: w, height: height).fill()

        let inset = CGFloat(height) * 0.14
        let glyphImg = NSImage(size: NSSize(width: glyphW, height: glyphH), flipped: false) { _ in
            drawEye(paused: paused, nudge: nudge, strain: strain, color: dark ? .white : .black)
            return true
        }
        glyphImg.draw(in: NSRect(x: inset, y: inset, width: CGFloat(w) - 2 * inset, height: CGFloat(height) - 2 * inset))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Render the whole dilation sequence as one strip — each stage big, with the
    /// glyph at true retina bar size (18pt @2x) under it, so the progression can be
    /// judged as it will actually appear. The stages past 1.0 are the overdue ones,
    /// where a break has been put off rather than taken.
    /// `pace --make-strainstrip <path> [dark]`.
    static func writeStrainStrip(to path: String, dark: Bool, stages: [CGFloat] = [0, 0.35, 0.7, 1.0, 1.25, 1.5, 2.0]) -> Bool {
        let cell = 96, pad = 10, small = Int(glyphW) * 2   // 2x: the bar renders the 18pt glyph on a retina display
        let w = stages.count * (cell + pad) + pad
        let h = cell + pad * 3 + small
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()

        for (i, s) in stages.enumerated() {
            let img = NSImage(size: NSSize(width: glyphW, height: glyphH), flipped: false) { _ in
                drawEye(paused: false, strain: s, color: dark ? .white : .black)
                return true
            }
            let x = CGFloat(pad + i * (cell + pad))
            img.draw(in: NSRect(x: x, y: CGFloat(pad * 2 + small), width: CGFloat(cell), height: CGFloat(cell)))
            img.draw(in: NSRect(x: x + CGFloat(cell / 2 - small / 2), y: CGFloat(pad),
                                width: CGFloat(small), height: CGFloat(small)))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Render the 1024px app icon PNG to `path`. Called as `pace --make-icon`.
    static func writeAppIcon(to path: String, size: CGFloat = 1024) -> Bool {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        ctx.cgContext.clear(rect)

        // Calm teal/green squircle — the resting palette, distinct from netty/ember.
        let bgRect = rect.insetBy(dx: size * 0.085, dy: size * 0.085)
        let bg = NSBezierPath(roundedRect: bgRect, xRadius: size * 0.205, yRadius: size * 0.205)
        NSGradient(colors: [
            NSColor(srgbRed: 0.30, green: 0.72, blue: 0.66, alpha: 1),   // teal top
            NSColor(srgbRed: 0.16, green: 0.52, blue: 0.55, alpha: 1),   // deep teal bottom
        ])!.draw(in: bg, angle: -90)

        // A white walking figure — movement + rest, the whole point of the app.
        if let symbol = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
            let glyph = symbol.withSymbolConfiguration(config) ?? symbol
            let side = size * 0.5
            let target = NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)

            let tinted = NSImage(size: target.size)
            tinted.lockFocus()
            glyph.draw(in: NSRect(origin: .zero, size: target.size))
            NSColor.white.set()
            NSRect(origin: .zero, size: target.size).fill(using: .sourceAtop)
            tinted.unlockFocus()

            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = size * 0.03
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
            shadow.set()
            tinted.draw(in: target)
        }

        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
