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
    /// Paused adds a bold slash and drops the pupil.
    static func statusImage(paused: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: glyphW, height: glyphH), flipped: false) { _ in
            drawEye(paused: paused, color: .black)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Draw the googly eye into the current context (glyphW x glyphH space).
    static func drawEye(paused: Bool, color: NSColor) {
        color.set()
        let rim = NSBezierPath(ovalIn: NSRect(x: 1.7, y: 1.7, width: glyphW - 3.4, height: glyphH - 3.4))
        rim.lineWidth = 1.5
        rim.stroke()

        if paused {
            let s = NSBezierPath()
            s.move(to: NSPoint(x: 4.0, y: 4.6)); s.line(to: NSPoint(x: glyphW - 4.0, y: glyphH - 4.6))
            s.lineWidth = 1.7; s.lineCapStyle = .round; s.stroke()
        } else {
            let r: CGFloat = 3.1                       // bold pupil, resting low
            NSBezierPath(ovalIn: NSRect(x: glyphW / 2 - r, y: 7.1 - r, width: 2 * r, height: 2 * r)).fill()
        }
    }

    /// Render the glyph big for review, black-on-light or white-on-dark (as the
    /// bar would tint it). `pace --make-menuicon <path> [paused] [dark]`.
    static func writeMenuIconPreview(to path: String, paused: Bool, dark: Bool, height: Int = 360) -> Bool {
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
            drawEye(paused: paused, color: dark ? .white : .black)
            return true
        }
        glyphImg.draw(in: NSRect(x: inset, y: inset, width: CGFloat(w) - 2 * inset, height: CGFloat(height) - 2 * inset))
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
