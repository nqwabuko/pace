import AppKit

/// Draws the app icon (for the .icns, via make-app.sh) and the menu-bar glyph: a
/// figure at a desk whose posture is the movement gauge and whose head is the eye
/// gauge. No external tooling: pure AppKit drawing.
///
/// The file is in two halves and the seam is the point of it. Everything above
/// `MARK: the interpreter` is a pure derivation — state in, numbers and shapes
/// out, no AppKit, no context, nothing drawn. Below the seam there is exactly one
/// function that touches a graphics context, and it knows nothing about eyes,
/// movement or debt. Every consumer goes through the same `marks(_:)`: the bar,
/// the previews, the strips, and the pixel measurements `--selftest` gates on, so
/// a review sheet cannot quietly drift away from the glyph actually on the bar.
///
/// It used to be one `drawEye` with seven defaulted parameters copy-pasted
/// through six functions and re-spelled by hand as a cache-key string in
/// AppDelegate. Adding a second gauge to that shape cost six signatures, eight
/// call sites and a silent redraw bug if you forgot the key. One `GlyphState`
/// makes it one field.
enum IconMaker {

    // Square canvas, 18pt, drawn at 36px on a retina bar. Everything here is
    // sized against that 36 and nothing else.
    private static let glyphW: CGFloat = 18
    private static let glyphH: CGFloat = 18

    // MARK: the state

    /// The whole input to the glyph, as one value. It is also AppDelegate's
    /// redraw key: `statusImage` takes exactly the thing that is compared, so the
    /// two cannot disagree — which the hand-built key string could, and did.
    ///
    /// `eye` and `move` are both elapsed / interval: 0 just rested, 1 the break is
    /// due, above 1 overdue. `move` is optional because absence is a real third
    /// reading — movement is *not tracked* — as against tracked-and-rested (0) or
    /// tracked-and-behind (2). It is also the only place the move axis can be
    /// forgotten, which is the point of making it explicit.
    struct GlyphState: Equatable {
        var eye: CGFloat = 0
        var move: CGFloat? = nil
        var missed: Int = 0
        var onCall = false
        var paused = false
        var nudge = false

        static let rested = GlyphState()
    }

    /// Snap a raw strain to its redraw step, so a 1s tick only rebuilds the image
    /// on a change you could see. This lived inline in AppDelegate as
    /// `Int((strain * 12).rounded())` with the divide-back-by-12 three lines
    /// later — exactly the shape of bug where the key and the pixels disagree.
    /// Total on nonsense (NaN, negative, absurd) so nothing downstream guards.
    static func quantised(_ raw: Double, steps: Int, max limit: Double = 2) -> CGFloat {
        guard raw.isFinite, steps > 0 else { return 0 }
        let clamped = Swift.max(0, Swift.min(limit, raw))
        return CGFloat(((clamped * Double(steps)).rounded()) / Double(steps))
    }

    // MARK: the derivation — no AppKit below here until the interpreter

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private static func smoothstep(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t)); return x * x * (3 - 2 * x)
    }

    /// One gauge's reading, clamped once and split once. Both axes go through it,
    /// which is what makes them structurally symmetric rather than symmetric by
    /// eye — and it is why pausing rests movement as well as the eye, for free.
    struct Strain: Equatable {
        let s: CGFloat      // 0…1: filling up to the break being due
        let over: CGFloat   // 0…1: overdue by that much of another interval
        var raw: CGFloat { s + over }
    }

    static func strain(_ raw: CGFloat, paused: Bool) -> Strain {
        let r = paused ? 0 : max(0, min(2, raw))   // a paused gauge rests, whatever the counter says
        return Strain(s: min(1, r), over: max(0, r - 1))
    }

    // The seated figure, in the 18x18 glyph space. Three elements and it must stay
    // three — head, spine, leg — because a fourth is mush at the 36px the bar
    // actually renders. Measured, not asserted: see the perceptibility gate.
    private static let hipX: CGFloat = 4.4, hipY: CGFloat = 4.6
    private static let thighLen: CGFloat = 6.4
    private static let shinDrop: CGFloat = 3.5
    private static let spineLen: CGFloat = 6.0
    private static let bodyStroke: CGFloat = 1.7
    private static let spineSegments = 12       // the spine is flattened here, in the pure half,
                                                // so GlyphShape stays at four cases

    // Posture is the movement gauge. Nobody sits at exactly vertical, so rested is
    // a slight forward set rather than a flagpole — at 0° the glyph read as a
    // signpost rather than a body, which made the calmest state the most ambiguous.
    private static let baseLeanDeg: CGFloat = 9
    private static let maxLeanDeg: CGFloat = 46
    // The lower back stays near upright and the UPPER back does the bending. That
    // one split is the difference between hunching and toppling over; a spine that
    // tilts as a straight stick reads as a lollipop falling, not a person slumping.
    private static let hunch: CGFloat = 0.42
    private static let leanDrift: CGFloat = 0.40   // slide the hip back as it leans, or the head walks out of the box

    // The head is the eye gauge. It carries eye state as COLOUR, and colour alone
    // in the range up to due: making it a solid disc rather than a ring-and-dot is
    // what bought the clean read, and the measured cost is that the first three eye
    // steps are 0px in monochrome. `differentiateWithoutColor` is the answer — see
    // `head` and `headTone`, which put the channel back when the system says colour
    // is not available. It is not a compromise on the default look.
    private static let headR: CGFloat = 2.15
    private static let overdueGrow: CGFloat = 0.13    // past 1.5 the head swells, so 1.5→2.0 is not a dead step
    private static let monoGrow: CGFloat = 0.50
    private static let monoRingW: CGFloat = 1.15, monoRestFill: CGFloat = 0.45       // …and with colour unavailable, size carries the whole axis

    // Breaks missed, however they were missed, push the head further along the ramp
    // rather than getting a mark of their own. A refusal is time you still owe, so
    // it belongs on the same axis as the time itself, not beside it.
    static let maxMissed = 3
    private static let missedPush: CGFloat = 0.30

    // On a call the breaks are held rather than refused, so the figure makes room
    // for a rule beneath it: owed, but not asked for yet.
    private static let callScale: CGFloat = 0.88, callLift: CGFloat = 1.2
    private static let barY: CGFloat = 0.7, barH: CGFloat = 1.5, barW: CGFloat = 9.0

    /// Everything outside the program that changes how the glyph should look, as
    /// one value. Read once, at the edge, by `Appearance.current`; nothing in the
    /// derivation reads AppKit, defaults or a clock. Being a value is what makes
    /// the whole appearance matrix enumerable in `--selftest` instead of something
    /// you discover is wrong on someone else's Mac.
    struct Appearance: Equatable {
        var barIsDark = false               // the BAR, which is not the system appearance
        var highlighted = false             // our menu is open, so the bar inverts under us
        var differentiateWithoutColor = false
        var increaseContrast = false

        static let standard = Appearance()
        /// Colour is a channel we are allowed to use, not one we are owed.
        var usesColour: Bool { !differentiateWithoutColor }

        /// The only impure read in the glyph. Everything downstream is a function
        /// of the value it returns, which is what lets `--selftest` walk all 16
        /// combinations instead of waiting for a bug report from a Mac with an
        /// accessibility setting we never tried.
        ///
        /// The BAR's appearance, not the system's: a light menu bar over a pale
        /// wallpaper on a dark-mode Mac is a real configuration, and the button is
        /// the only thing that knows. There is no sanctioned API for it, so
        /// `bestMatch` on the button's own appearance is as close as macOS gets.
        static func current(_ button: NSStatusBarButton?) -> Appearance {
            let w = NSWorkspace.shared
            let dark = button.map {
                $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            } ?? false
            return Appearance(
                barIsDark: dark,
                highlighted: button?.isHighlighted ?? false,
                differentiateWithoutColor: w.accessibilityDisplayShouldDifferentiateWithoutColor,
                increaseContrast: w.accessibilityDisplayShouldIncreaseContrast)
        }
    }

    /// Where the body is. Movement, and only movement, moves it.
    struct Posture: Equatable {
        let hip, knee, foot, neck: CGPoint
        let spine: [CGPoint]
        let leanDeg: CGFloat
    }

    /// The movement gauge. `nudge` is the on-call cue and sits the figure up
    /// straight: the ask is "sit up and look away", so it is the same axis run
    /// backwards rather than a fourth idiom bolted on.
    static func posture(move: Strain?, onCall: Bool, nudge: Bool) -> Posture {
        let scale = onCall ? callScale : 1
        let raw = nudge ? 0 : (move?.raw ?? 0)
        let lean = baseLeanDeg + (maxLeanDeg - baseLeanDeg) * smoothstep(raw / 2)
        let a = lean * .pi / 180
        let lowA = a * (1 - hunch)
        let drift = spineLen * sin(a) * leanDrift
        let cx = glyphW / 2 * (1 - scale)
        let hip = CGPoint(x: (hipX - drift) * scale + cx, y: hipY * scale + (onCall ? callLift : 0))
        let knee = CGPoint(x: hip.x + thighLen * scale, y: hip.y)
        let foot = CGPoint(x: knee.x, y: knee.y - shinDrop * scale)
        let L = spineLen * scale
        let ctrl = CGPoint(x: hip.x + L * 0.55 * sin(lowA), y: hip.y + L * 0.55 * cos(lowA))
        let neck = CGPoint(x: hip.x + L * sin(a), y: hip.y + L * cos(a))
        // Flattened here rather than in the interpreter: the shape is arithmetic and
        // arithmetic belongs above the seam. 12 segments is indistinguishable from a
        // true curve at 36px and keeps GlyphShape from growing a fifth case.
        let spine = (0...spineSegments).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(spineSegments), u = 1 - t
            return CGPoint(x: u * u * hip.x + 2 * u * t * ctrl.x + t * t * neck.x,
                           y: u * u * hip.y + 2 * u * t * ctrl.y + t * t * neck.y)
        }
        return Posture(hip: hip, knee: knee, foot: foot, neck: neck, spine: spine, leanDeg: lean)
    }

    /// How far along the eye ramp we are, 0…2. Time owed and breaks missed land on
    /// the same number because they are the same debt.
    static func eyeLevel(_ eye: Strain, missed: Int) -> CGFloat {
        min(2, eye.raw + missedPush * CGFloat(min(maxMissed, max(0, missed))))
    }

    struct Head: Equatable { let cx, cy, r: CGFloat }

    /// The head rides on the spine's tangent at the neck, so it tips with the hunch
    /// instead of floating level above a bent back.
    static func head(_ p: Posture, eye: Strain, missed: Int, onCall: Bool,
                     _ ap: Appearance = .standard) -> Head {
        let level = eyeLevel(eye, missed: missed)
        let scale = onCall ? callScale : 1
        // With colour available, size is a faint confirmation at the overdue end.
        // Without it, size IS the gauge and runs the whole range.
        // With colour, size is a faint confirmation at the overdue end. Without it
        // the head becomes a ring that fills — the monochrome language this glyph
        // used before colour existed, measured and proven — and grows on top.
        let grow = ap.usesColour ? 1 + overdueGrow * max(0, (level - 1.5) / 0.5)
                                 : 1 + monoGrow * (level / 2)
        let r = headR * scale * grow
        let d = CGPoint(x: p.neck.x - p.spine[spineSegments - 1].x,
                        y: p.neck.y - p.spine[spineSegments - 1].y)
        let len = max(0.001, sqrt(d.x * d.x + d.y * d.y))
        return Head(cx: p.neck.x + (r + 0.30) * d.x / len,
                    cy: p.neck.y + (r + 0.30) * d.y / len, r: r)
    }

    /// The eye ramp: rested through to long overdue. Green to red is the obvious
    /// reading and the one the sketch asked for, but it is never the only channel —
    /// `differentiateWithoutColor` drops it to the foreground tone and hands the
    /// axis to head size, which is why the ramp may be this literal.
    static func headTone(_ eye: Strain, missed: Int, _ ap: Appearance) -> Tone {
        guard ap.usesColour else { return .foreground }
        // The stops are spaced by how far apart they LOOK, not by taste. An earlier
        // ramp crowded orange through red into the overdue half and measured zero
        // visible pixels from 1.0 to 1.5 — the alarm half of the gauge, saying
        // nothing. The gate below catches exactly that.
        let stops: [(CGFloat, CGFloat, CGFloat, CGFloat)] = ap.increaseContrast
            ? [(0.0, 0.05, 0.50, 0.20), (0.7, 0.72, 0.62, 0.00),
               (1.0, 0.85, 0.40, 0.00), (2.0, 0.62, 0.02, 0.04)]
            : [(0.0, 0.25, 0.72, 0.42), (0.7, 0.90, 0.78, 0.15),
               (1.0, 0.95, 0.55, 0.10), (2.0, 0.78, 0.07, 0.10)]
        let level = eyeLevel(eye, missed: missed)
        for i in 1..<stops.count where level <= stops[i].0 {
            let a = stops[i - 1], b = stops[i]
            let t = (level - a.0) / (b.0 - a.0)
            return .rgb(r: lerp(a.1, b.1, t), g: lerp(a.2, b.2, t), b: lerp(a.3, b.3, t))
        }
        let l = stops[stops.count - 1]
        return .rgb(r: l.1, g: l.2, b: l.3)
    }

    // MARK: marks — shapes as data

    /// A colour, as a value rather than an NSColor, so the whole decision layer
    /// stays pure and comparable. `.foreground` means "whatever this bar tints
    /// text", which is the only thing a template image is allowed to be.
    enum Tone: Equatable {
        case foreground
        case rgb(r: CGFloat, g: CGFloat, b: CGFloat)
    }

    /// The glyph's whole vocabulary of shapes, in plain Foundation types so the
    /// derivation half of this file has no AppKit in it and every mark is Equatable
    /// and printable.
    ///
    /// Three cases, and it must stay three: a fourth is evidence that a mark is
    /// being invented rather than derived. The spine is a curve and still lives in
    /// `.strokes`, because it is flattened in `posture` where the arithmetic belongs.
    ///
    /// It must stay a *value* type. Put an NSBezierPath in here and `Mark` equality
    /// silently becomes reference identity: the orthogonality assertions degrade to
    /// vacuously true and the redraw key degrades to always-redraw, with nothing
    /// failing to tell you.
    enum GlyphShape: Equatable {
        case disc(cx: CGFloat, cy: CGFloat, r: CGFloat)
        case capsule(CGRect)
        case strokes([[CGPoint]])
    }

    /// One drawing instruction: a shape, how to paint it, what tone, and what to
    /// clip it to. The `id` is the whole point of the type — it lets the selftest
    /// say "the body mark did not change when the eye moved" rather than "pixel
    /// 4,112 did not change", which is the assertion the old design could not
    /// phrase at all.
    struct Mark: Equatable {
        enum ID: Equatable { case body, head, headFill, callBar, pauseHalo, pause }
        enum Paint: Equatable { case fill; case stroke(width: CGFloat, round: Bool) }
        /// `.out` knocks ink back out rather than laying it down. A template image
        /// has no background to hide behind, so it is the only way one mark can sit
        /// cleanly on top of another instead of merging into it.
        enum Ink: Equatable { case on, out }

        let id: ID
        let shape: GlyphShape
        let paint: Paint
        let tone: Tone
        let ink: Ink
        let clip: GlyphShape?

        init(id: ID, shape: GlyphShape, paint: Paint, tone: Tone = .foreground,
             ink: Ink = .on, clip: GlyphShape? = nil) {
            self.id = id; self.shape = shape; self.paint = paint
            self.tone = tone; self.ink = ink; self.clip = clip
        }
    }

    /// What a mark actually occupies, stroke width included. Pure, so `--selftest`
    /// can assert the whole glyph fits its 18pt box instead of someone noticing a
    /// flat-topped head in a review sheet — which is how the mono head's overgrowth
    /// was found, one round too late.
    static func bounds(_ m: Mark) -> CGRect {
        let pad: CGFloat = {
            if case let .stroke(w, _) = m.paint { return w / 2 }
            return 0
        }()
        var r: CGRect
        switch m.shape {
        case let .disc(cx, cy, rad):
            r = CGRect(x: cx - rad, y: cy - rad, width: 2 * rad, height: 2 * rad)
        case let .capsule(rect):
            r = rect
        case let .strokes(subpaths):
            let pts = subpaths.flatMap { $0 }
            guard let first = pts.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in pts {
                minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
                minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
            }
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return r.insetBy(dx: -pad, dy: -pad)
    }

    /// Leg and spine as one mark in two subpaths. This is the silhouette pace is
    /// findable by on the bar, and nothing on the eye axis is allowed near it —
    /// enforced by the orthogonality check in `--selftest`, not by this comment.
    static func bodyMark(_ p: Posture) -> Mark {
        Mark(id: .body,
             shape: .strokes([[p.foot, p.knee, p.hip], p.spine]),
             paint: .stroke(width: bodyStroke, round: true))
    }

    /// The eye gauge. In colour it is a solid tinted disc: solid rather than a ring
    /// with a dot inside, because the ring read as fussy at 36px and the disc reads
    /// instantly. With colour unavailable that trade is off — there is no hue to
    /// carry the axis — so the head becomes a ring that fills instead, which is the
    /// monochrome language the glyph used before colour and is proven at this size.
    static func headMarks(_ h: Head, tone: Tone, level: CGFloat, _ ap: Appearance) -> [Mark] {
        guard !ap.usesColour else {
            return [Mark(id: .head, shape: .disc(cx: h.cx, cy: h.cy, r: h.r), paint: .fill, tone: tone)]
        }
        let inner = h.r - monoRingW / 2
        let fill = monoRestFill + (inner - monoRestFill) * min(1, level / 1.2)
        return [Mark(id: .head, shape: .disc(cx: h.cx, cy: h.cy, r: h.r - monoRingW / 2),
                     paint: .stroke(width: monoRingW, round: false), tone: tone),
                Mark(id: .headFill, shape: .disc(cx: h.cx, cy: h.cy, r: fill), paint: .fill, tone: tone)]
    }

    /// Held, not refused: a solid rule under the figure. It is the one mark here
    /// that is not a gauge, so it stays a clean straight line.
    static func callBarMark(_ onCall: Bool) -> Mark? {
        guard onCall else { return nil }
        return Mark(id: .callBar,
                    shape: .capsule(CGRect(x: glyphW / 2 - barW / 2, y: barY, width: barW, height: barH)),
                    paint: .fill)
    }

    // The ordinary pause sign, centred over the figure. An earlier version was a
    // diagonal slash, which at 36px read as neither a slash nor a person.
    private static let pauseBarW: CGFloat = 2.3, pauseBarH: CGFloat = 8.0
    private static let pauseGap: CGFloat = 2.2, pauseHalo: CGFloat = 1.0

    private static func pauseBars(_ inset: CGFloat) -> [CGRect] {
        [-1, 1].map { side in
            CGRect(x: glyphW / 2 + CGFloat(side) * pauseGap / 2 - (side < 0 ? pauseBarW : 0) - inset,
                   y: (glyphH - pauseBarH) / 2 - inset,
                   width: pauseBarW + 2 * inset, height: pauseBarH + 2 * inset)
        }
    }

    /// Paused: the pause sign laid over the figure, with the figure knocked back
    /// around it so the two do not merge into one mass at menu-bar size.
    static func pauseMarks(_ paused: Bool) -> [Mark] {
        guard paused else { return [] }
        return pauseBars(pauseHalo).map {
            Mark(id: .pauseHalo, shape: .capsule($0), paint: .fill, ink: .out)
        } + pauseBars(0).map {
            Mark(id: .pause, shape: .capsule($0), paint: .fill)
        }
    }

    /// The whole glyph, derived. One state and one appearance in, a mark list out.
    /// Appearance is an input rather than something the interpreter applies later
    /// because it genuinely changes what is drawn, not just what colour it is: with
    /// colour unavailable the head has to carry the eye axis by size instead.
    static func marks(_ st: GlyphState, _ ap: Appearance = .standard) -> [Mark] {
        let eye = strain(st.eye, paused: st.paused)
        let move = st.move.map { strain($0, paused: st.paused) }
        let missed = st.paused ? 0 : st.missed
        let p = posture(move: move, onCall: st.onCall, nudge: st.nudge)

        var out = [bodyMark(p)]
        if let bar = callBarMark(st.onCall) { out.append(bar) }
        out += headMarks(head(p, eye: eye, missed: missed, onCall: st.onCall, ap),
                         tone: headTone(eye, missed: missed, ap),
                         level: eyeLevel(eye, missed: missed), ap)
        out += pauseMarks(st.paused)
        return out
    }

    // MARK: the interpreter — the only AppKit in the glyph

    /// Shapes to paths. The only arithmetic here is shape construction: the 4/3
    /// control offset traces a semicircle when the bulge equals the half-width.
    private static func path(for shape: GlyphShape) -> NSBezierPath {
        switch shape {
        case let .disc(cx, cy, r):
            return NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        case let .capsule(rect):
            return NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        case let .strokes(subpaths):
            let p = NSBezierPath()
            for sub in subpaths {
                for (i, pt) in sub.enumerated() {
                    i == 0 ? p.move(to: NSPoint(x: pt.x, y: pt.y)) : p.line(to: NSPoint(x: pt.x, y: pt.y))
                }
            }
            return p
        }
    }

    /// Draw a mark list into the current context (glyphW x glyphH space). It knows
    /// nothing about strain, eyes, movement, debt or modes — it resolves tones and
    /// paints shapes. Total: an empty list draws nothing, so the absent-figure and
    /// paused cases need no conditionals here.
    ///
    /// `foreground` is passed in rather than read, so the same mark list renders as
    /// the bar's template black, as white on a review sheet, or inverted under an
    /// open menu, with no branch in here and no second copy of the geometry.
    /// The only place a Tone becomes an NSColor.
    static func resolve(_ tone: Tone, foreground: NSColor) -> NSColor {
        switch tone {
        case .foreground:            return foreground
        case let .rgb(r, g, b):      return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }

    static func render(_ marks: [Mark], color foreground: NSColor) {
        for m in marks {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            if let clip = m.clip { path(for: clip).addClip() }
            switch m.ink {
            case .on:
                resolve(m.tone, foreground: foreground).set()
            case .out:
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSColor.black.set()
            }
            let p = path(for: m.shape)
            switch m.paint {
            case .fill:
                p.fill()
            case let .stroke(width, round):
                p.lineWidth = width
                if round { p.lineCapStyle = .round; p.lineJoinStyle = .round }
                p.stroke()
            }
        }
    }

    // MARK: edges

    /// The menu-bar image. Template when the glyph is monochrome, which is the
    /// only way macOS will tint it for free; a plain image once colour is in play,
    /// which is the moment we take on light/dark and the open-menu inversion
    /// ourselves. That trade is made here, in one place, and nowhere else.
    static func statusImage(_ st: GlyphState, _ ap: Appearance = .standard) -> NSImage {
        let ms = marks(st, ap)
        let colourful = ap.usesColour && ms.contains { $0.tone != .foreground }
        let fg: NSColor = colourful ? (ap.barIsDark != ap.highlighted ? .white : .black) : .black
        let img = NSImage(size: NSSize(width: glyphW, height: glyphH), flipped: false) { _ in
            render(ms, color: fg)
            return true
        }
        img.isTemplate = !colourful
        return img
    }

    // MARK: the invariant

    /// What the glyph puts on screen in one state.
    struct Measure {
        let state: GlyphState
        let ink: Double        // total coverage, in glyph-space units
    }

    static func measure(_ st: GlyphState, _ ap: Appearance = .standard, samples: Int = 240) -> Measure {
        Measure(state: st, ink: coverage(samples) { render(marks(st, ap), color: .black) })
    }

    /// THE gate. How many pixels actually change between two states at the size the
    /// bar renders, counting only changes a person could see.
    ///
    /// This exists because the design it replaced passed every monotonicity check
    /// while being invisible: ink rose smoothly across the movement axis and not one
    /// pixel of the 1296 changed. Monotonic and perceptible are different claims and
    /// only the second one matters to somebody glancing at a menu bar. Rasterised at
    /// 36px — 18pt at 2x — because a mark that reads at 84px and not at 36 has not
    /// been drawn.
    /// Calibrated, not guessed: `colourFloor` sits between two measured cases —
    /// one redraw quantum of the eye ramp (0.04, must NOT count) and a quarter
    /// interval of debt, green against orange (0.19, must count).
    private static let alphaFloor = 0.25, colourFloor = 0.12

    static func visibleDelta(_ a: GlyphState, _ b: GlyphState,
                             _ ap: Appearance = .standard, px: Int = 36) -> Int {
        guard let ra = raster(a, ap, px: px), let rb = raster(b, ap, px: px),
              let da = ra.bitmapData, let db = rb.bitmapData else { return 0 }
        var n = 0
        for row in 0..<px {
            for col in 0..<px {
                let ia = row * ra.bytesPerRow + col * 4, ib = row * rb.bytesPerRow + col * 4
                // alpha, and colour at equal alpha: a green head and a red head are
                // the same silhouette, and the whole eye axis lives in that difference.
                let aA = Double(da[ia + 3]) / 255.0, aB = Double(db[ib + 3]) / 255.0
                if abs(aA - aB) > alphaFloor { n += 1; continue }
                // Colour and alpha are not the same quantity and cannot share a
                // threshold. A max-channel test called green-vs-orange a 22% change
                // and scored the whole eye axis as invisible, which is plainly wrong
                // to anyone looking at it. Euclidean RGB over the unit cube, on
                // pixels that are actually opaque in both frames.
                let dr = (Double(da[ia]) - Double(db[ib])) / 255.0
                let dg = (Double(da[ia + 1]) - Double(db[ib + 1])) / 255.0
                let dbl = (Double(da[ia + 2]) - Double(db[ib + 2])) / 255.0
                let dC = (dr * dr + dg * dg + dbl * dbl).squareRoot() / 1.7320508
                if min(aA, aB) > 0.5 && dC > colourFloor { n += 1 }
            }
        }
        return n
    }

    private static func raster(_ st: GlyphState, _ ap: Appearance, px: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: CGFloat(px) / glyphW, y: CGFloat(px) / glyphH)
        render(marks(st, ap), color: ap.barIsDark ? .white : .black)
        NSGraphicsContext.restoreGraphicsState()
        return rep
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

    // MARK: review sheets

    /// One glyph, drawn at `side` points into the current context at `rect`.
    private static func glyphImage(_ st: GlyphState, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: glyphW, height: glyphH), flipped: false) { _ in
            render(marks(st), color: color)
            return true
        }
    }

    /// Render the glyph big for review, black-on-light or white-on-dark (as the
    /// bar would tint it).
    /// `pace --make-menuicon <path> [paused] [dark] [nudge] [call] [missed <0…3>] [strain <0…2>] [move <0…2>]`.
    static func writeMenuIconPreview(to path: String, state: GlyphState, dark: Bool, height: Int = 360) -> Bool {
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
        glyphImage(state, color: dark ? .white : .black)
            .draw(in: NSRect(x: inset, y: inset, width: CGFloat(w) - 2 * inset, height: CGFloat(height) - 2 * inset))
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
            let img = glyphImage(GlyphState(eye: s), color: dark ? .white : .black)
            let x = CGFloat(pad + i * (cell + pad))
            img.draw(in: NSRect(x: x, y: CGFloat(pad * 2 + small), width: CGFloat(cell), height: CGFloat(cell)))
            img.draw(in: NSRect(x: x + CGFloat(cell / 2 - small / 2), y: CGFloat(pad),
                                width: CGFloat(small), height: CGFloat(small)))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// One row of the damage grid: what the glyph is being asked to say. `move` is
    /// a strain now, not an on-off: the rows walk the movement gauge the way the
    /// columns walk the eye, because with two continuous axes the interesting cells
    /// are the corners — a rested eye with movement long overdue, and the reverse.
    private struct DamageRow {
        let label: String
        var missed = 0
        var move: CGFloat? = nil
        var onCall = false
    }

    private static let damageRows: [DamageRow] = [
        DamageRow(label: "clean, move off"),
        DamageRow(label: "1 eye rest missed", missed: 1),
        DamageRow(label: "2 missed", missed: 2),
        DamageRow(label: "3+ missed", missed: 3),
        DamageRow(label: "just moved", move: 0),
        DamageRow(label: "move due", move: 1),
        DamageRow(label: "move overdue", move: 2),
        DamageRow(label: "2 eye + move overdue", missed: 2, move: 2),
        DamageRow(label: "on a call", onCall: true),
        DamageRow(label: "on a call, both behind", missed: 2, move: 2, onCall: true),
    ]

    /// Render every damage state against every strain as one grid: each cell shows
    /// the glyph big, with the true retina bar size (18pt @2x) directly under it.
    /// The small one is the only one that counts — a posture or a tone that reads at
    /// 84px and disappears at 36px has not been drawn. The cell to look hardest at
    /// is the smallest head there is: rested, on a call, with colour switched off.
    /// `pace --make-damagestrip <path> [dark]`.
    static func writeDamageStrip(to path: String, dark: Bool, stages: [CGFloat] = [0, 0.5, 1.0, 1.5]) -> Bool {
        let big = 84, small = Int(glyphW) * 2, pad = 9, gutter = 170, header = 26
        let cellW = big + pad, cellH = big + pad / 2 + small + pad
        let w = gutter + stages.count * cellW + pad
        let h = header + damageRows.count * cellH + pad
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let fg: NSColor = dark ? .white : .black
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()

        let text: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: fg,
        ]
        for (col, stage) in stages.enumerated() {
            let x = CGFloat(gutter + col * cellW)
            NSAttributedString(string: String(format: "eye %.1f", stage), attributes: text)
                .draw(at: NSPoint(x: x, y: CGFloat(h - header + 6)))
        }

        for (row, r) in damageRows.enumerated() {
            let y = CGFloat(h - header - (row + 1) * cellH)
            NSAttributedString(string: r.label, attributes: text)
                .draw(at: NSPoint(x: CGFloat(pad), y: y + CGFloat(cellH) / 2))
            for (col, stage) in stages.enumerated() {
                let x = CGFloat(gutter + col * cellW)
                let img = glyphImage(GlyphState(eye: stage, move: r.move, missed: r.missed, onCall: r.onCall),
                                     color: fg)
                img.draw(in: NSRect(x: x, y: y + CGFloat(pad + small + pad / 2),
                                    width: CGFloat(big), height: CGFloat(big)))
                img.draw(in: NSRect(x: x + CGFloat(big / 2 - small / 2), y: y + CGFloat(pad),
                                    width: CGFloat(small), height: CGFloat(small)))
            }
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
