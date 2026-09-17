import Foundation

/// The rules of the feedback loop, with the clock taken out of them.
///
/// `Scheduler` used to be both the rules and the machinery that drives them: it
/// read the wall clock, the idle sensor and the preferences at eight points
/// inside one tick, so the only way to ask "what does this loop do" was to run
/// it. Everything here is a function of its arguments. The world arrives as a
/// `Tick` value, the preferences as a `Config` value, and the answer comes back
/// as a new `State` plus a list of `Effect`s for the shell to perform.
///
/// The one thing that could not be flattened is the re-entrant tick: a call
/// starting while a break is on screen runs a whole nested tick in the middle of
/// the outer one. Rather than pretend otherwise, the reducer suspends there and
/// says so — see `Effect.resumeTick`.
enum Loop {

    /// One thing that happened to a break that was owed and didn't happen, in the
    /// order it happened. The card draws this trail, so what you see is the actual
    /// sequence rather than a tally: two extensions then a skip reads differently
    /// from a skip then two extensions, and the counts alone can't tell you which.
    enum Mark: String {
        case snoozed        // "+5 min"
        case skipped        // "Skip", Esc, or a click off the card
        case interrupted    // a call started while the card was up
        case held           // came due during a call and was nudged instead of shown

        /// Did you choose this? A call getting in the way isn't a refusal.
        var isRefusal: Bool { self == .snoozed || self == .skipped }
    }

    /// One break type's state. Keeping the counter and its deferral together in
    /// one value is what stops the pair drifting apart when only half of it gets
    /// updated — the bug that used to hand you a free eye rest for snoozing a
    /// movement break.
    struct Track {
        var elapsed: Double = 0     // seconds of screen work since a real rest
        var deferUntil: Date?       // put off: quiet until then, debt still climbing
        var trail: [Mark] = []      // what's happened to this break since the last real rest
        var lastNudge: Date?        // last on-call nudge; its own gap, not the break's
        var callHeld: Double = 0    // seconds on a call since the last real rest

        /// Read off the trail rather than counted alongside it. They used to be two
        /// `Int`s kept in step by hand, which is the same drift hazard `Track` exists
        /// to close — and now the card's story and the menu's count are one fact.
        var refusals: Int { trail.filter(\.isRefusal).count }
        var nudges: Int { trail.filter { $0 == .held }.count }

        /// A rested track is a new one: nothing survives a real rest, which is the
        /// whole of the rule and is easier to see as a value than as five
        /// assignments that have to stay in step.
        var rested: Track { Track() }

        /// A nudge has its own quiet gap so a long call doesn't buzz every second.
        /// Deliberately separate from `deferUntil`: the break is still owed, so
        /// when the call ends it comes up at once rather than waiting out a gap it
        /// never asked for.
        ///
        /// The gap doubles with each nudge, up to a cap. A break can't be rested
        /// during a call, so the condition that fired the first nudge is still true
        /// for every one after it — a fixed gap would repeat the same unactionable
        /// banner every five minutes for the length of the call. The first nudge is
        /// the one worth having, so it still lands on time; the tenth is not, so it
        /// doesn't come. Nothing here resets on call end: `deferUntil` was never
        /// touched, so the overlay fires as soon as the call drops and rests it.
        func canNudge(now: Date) -> Bool {
            let gap = min(Deferral.nudgeSec * pow(2, Double(nudges)), Deferral.nudgeCapSec)
            return lastNudge.map { now.timeIntervalSince($0) >= gap } ?? true
        }

        /// Put off: quiet until then, and a mark on the trail saying why. Returns a
        /// new track rather than editing this one, so a caller can't half-apply it.
        func putting(off seconds: TimeInterval, now: Date, mark: Mark?) -> Track {
            var t = self
            t.deferUntil = now.addingTimeInterval(seconds)
            if let mark { t.trail.append(mark) }
            return t
        }

        /// Quiet for at least this long, with nothing marked. Putting one break off
        /// buys the other one the same quiet, and that isn't its refusal to carry.
        func quiet(untilAtLeast floor: Date) -> Track {
            var t = self
            if (t.deferUntil ?? .distantPast) < floor { t.deferUntil = floor }
            return t
        }

        /// Nudged during a call: the break is still owed, so only the nudge clock
        /// and the trail move.
        func nudged(at now: Date) -> Track {
            var t = self
            t.lastNudge = now
            t.trail.append(.held)
            return t
        }

        func isDue(interval: Double, now: Date) -> Bool {
            elapsed >= interval && (deferUntil.map { now >= $0 } ?? true)
        }

        /// 0 just rested, 1 due, above 1 overdue by that fraction of an interval.
        func strain(interval: Double) -> Double {
            interval > 0 ? elapsed / interval : 0
        }
    }

    /// Everything the loop remembers between ticks, and nothing else. What is
    /// absent matters as much: no clock, no preferences, no callbacks, and no
    /// per-tick scratch — those all belong to the shell or to one reducer run.
    struct State {
        var eye = Track()
        var move = Track()
        var pausedUntil: Date?
        var pending: (date: Date, kind: BreakKind)?   // a one-off typed/scheduled break

        // Away tracking, driven by screen lock (not idle time, so reading never
        // counts as away). While locked we keep counting but hold the overlay; on
        // unlock we credit a rest only if the lock lasted long enough to be one.
        var screenLocked = false

        /// What each track owed the last time there was demonstrably a human here.
        /// The counters deliberately keep climbing while you're away, so that the break
        /// you're owed is waiting when you get back — which makes *now* the wrong
        /// reading to record when something finally rests you. An hour at lunch is not
        /// an hour of eye strain. One field for all three away paths (locked, no input,
        /// asleep), because "the debt you walked away with" is the same fact in each.
        var presentDebt: [Gauge] = []

        /// When a human was last demonstrably at the machine. The one source for "have
        /// I been away, and for how long".
        var lastPresence: Date?

        /// When the call now in progress started, or nil if there isn't one. The loop
        /// has always known *that* you're on a call and never *how long for*, so a
        /// break coming due two minutes into a meeting was indistinguishable from one
        /// coming due at the end of a long one. It is the call's own clock, not the
        /// break's: it resets at every call, so back-to-back meetings each get their
        /// own quiet opening.
        var callSince: Date?

        /// Is the break on screen one you asked for? A break that turns up by itself
        /// gets out of the way when a call starts. One you chose from the menu does
        /// not, because you picked it knowing what you were in.
        var askedFor = false
    }

    /// One break type's public reading. A value rather than a handful of loose
    /// `eye*`/`move*` fields: `Track` exists so the two halves can't drift, and
    /// flattening it back out here would hand that same hazard straight to the UI.
    struct Gauge {
        let kind: BreakKind
        var enabled: Bool
        var remaining: Int    // seconds to go; 0 once due or overdue
        var overdue: Int      // seconds past due; 0 until then
        var strain: Double    // elapsed / interval, uncapped: above 1 means overdue
        var refusals: Int     // times put off since the last real rest
        var nudges: Int       // times it came due on a call and was held, not asked
        var callHeldSec: Int  // of the time since the last rest, how much was on a call

        var name: String { kind.shortName }

        /// Times this break was owed and didn't happen, however it didn't happen —
        /// put off by you, or held back by a call. The bar draws damage off this
        /// one number, because from the eye's point of view the two are the same
        /// thing: a rest that was due and wasn't taken.
        var missed: Int { refusals + nudges }
    }

    struct Status {
        var paused: Bool
        var pausedUntil: Date?
        var meeting: Bool
        var away: Bool
        var scheduledAt: Date?   // a one-off typed break, if any
        var eye: Gauge
        var move: Gauge

        var enabled: [Gauge] { [eye, move].filter(\.enabled) }

        /// The gauge worth talking about: whichever is furthest past due, with the
        /// eye winning a tie because it comes round more often. The one place that
        /// decides "which is worse" — spelled out rather than sorted, so there's no
        /// question about tie order.
        var worst: Gauge? {
            switch (eye.enabled, move.enabled) {
            case (true, true):   return eye.overdue >= move.overdue ? eye : move
            case (true, false):  return eye
            case (false, true):  return move
            case (false, false): return nil
            }
        }

        /// Any break owed past its due time? What the worsening glyph and the
        /// "you keep extending" copy both hang off.
        var inDebt: Bool { enabled.contains { $0.overdue > 0 } }

        /// Seconds until the next recurring break, if any is enabled.
        var nextIn: Int? { enabled.map(\.remaining).min() }

        /// One kind's reading. The `Track` pair is private, so this is how a caller
        /// asks "what did the eye break owe just now" without keeping its own copy.
        func gauge(_ kind: BreakKind) -> Gauge { kind == .eye ? eye : move }
    }

    /// The preferences, read once per reducer entry rather than at the eight
    /// separate points the tick used to reach for them. Sampled per entry and
    /// never cached across ticks: changing an interval in the menu still takes
    /// effect on the very next tick, which is what the whole app relies on.
    struct Config {
        var eyeEnabled: Bool
        var moveEnabled: Bool
        var eyeIntervalSec: Int
        var moveIntervalSec: Int
        var meetingAware: Bool
        var callBreaks: Bool
        var idleAware: Bool
        var awayResetSec: Int
    }

    /// The world one tick reads. `delta` is real awake seconds since the last
    /// tick, measured by the shell off the monotonic work clock — never assumed
    /// to be one second, so a starved run loop heals instead of losing time.
    struct Tick {
        var now: Date            // wall time
        var delta: Double        // work seconds since the last tick
        var idle: Double         // seconds since the last human input
        var inCall: Bool
        var overlayShowing: Bool
        var config: Config
    }

    enum Input {
        case start(Config)
        case tick(Tick)
        case resumeTick(Tick, onCall: Bool)
        case pause(until: Date?)
        case scheduleBreak(at: Date, kind: BreakKind)
        case breakFinished(BreakKind, BreakEndReason, now: Date)
        case triggerNow(BreakKind, overlayShowing: Bool)
        case setScreenLocked(Bool)
    }

    /// What the shell must do once the rules have decided. Order within the
    /// returned array is behaviour: the status reading is always last on a path
    /// that finishes a tick, because today's `defer { emit() }` runs after the
    /// callback that fired the break.
    enum Effect {
        case breakDue(BreakKind, trail: [Mark])
        case callNudge(BreakKind)
        case meetingDuringBreak
        case awayRest(cleared: [Gauge], seconds: Int)
        case status(Status)

        /// Not a callback: the second half of a tick that suspended. See `step`.
        case resumeTick(Tick, onCall: Bool)
    }

    // MARK: the reducer

    static func step(_ s: State, _ i: Input) -> (State, [Effect]) {
        var s = s
        switch i {
        case .start(let c):
            s.presentDebt = gauges(s, c)
            return (s, [])

        case .pause(let date):
            s.pausedUntil = date
            return (s, [])

        case .scheduleBreak(let date, let kind):
            // Scheduling implies intent, so it clears any active pause.
            s.pending = (date, kind)
            s.pausedUntil = nil
            return (s, [])

        case .setScreenLocked(let locked):
            s.screenLocked = locked
            return (s, [])

        case .triggerNow(let kind, let overlayShowing):
            // Manual "take a break now". Asking for a break doesn't rest you;
            // taking it does, so nothing is credited here — and no tick runs, so
            // there is no status reading either.
            guard !overlayShowing else { return (s, []) }
            s.askedFor = true
            return (s, [.breakDue(kind, trail: trail(s, kind))])

        case .breakFinished(let kind, let reason, let now):
            s.askedFor = false   // whatever it was, it's over
            if reason.creditsRest {
                s = credited(s, kind)
            } else {
                s = over(s, kind) { $0.putting(off: reason.deferSec, now: now, mark: reason.mark) }
                // Putting one break off quiets the other one too, for at least as long.
                // "+5 min" means "leave me alone for five minutes", not "leave this one
                // counter alone" — without this, snoozing a movement break can pop an
                // eye break in the same breath. It buys quiet only: the other counter
                // keeps climbing and it isn't recorded as a refusal, because it wasn't.
                let other: BreakKind = kind == .eye ? .move : .eye
                s = over(s, other) { $0.quiet(untilAtLeast: now.addingTimeInterval(reason.deferSec)) }
            }
            return (s, [])

        case .resumeTick(let t, let onCall):
            return tickTail(s, t, onCall: onCall)

        case .tick(let t):
            var fx: [Effect] = []

            // Is a human demonstrably here, this second? Input in the last couple of
            // seconds is the only evidence of that the machine offers. Everything about
            // absence hangs off this one reading.
            let present = t.idle < 2

            // An absence ends when a human comes back, and only then. Its length is wall
            // time since one was last here, which needs no reconciliation of the work and
            // wall clocks to measure: sleep, dark wakes, a starved run loop and an empty
            // chair all read the same, because none of them are a person.
            //
            // This used to be three separate detectors — a wall-vs-work gap, a drop in
            // the idle counter, and the lock's own duration — each firing on its own. The
            // first of them read the machine *waking* as you *returning*, so a night of
            // macOS dark wakes (roughly one every fifteen minutes) logged a fresh rest at
            // every one: forty pairs a night, 1,188 of them in a fortnight. A machine
            // waking itself is not news about a human, and now nothing treats it as if it
            // were.
            if present {
                if t.config.idleAware, let since = s.lastPresence {
                    let credited = creditAway(s, seconds: Int(t.now.timeIntervalSince(since)), t.config)
                    s = credited.0; fx += credited.1
                }
                s.lastPresence = t.now
            }

            // Self-heal a missed unlock notification: if we think the screen is
            // locked but there has been human input in the last couple of seconds,
            // we are demonstrably back at the desk. Without this a single dropped
            // notification would wedge the app in "away" forever.
            if s.screenLocked, present { s.screenLocked = false }

            if let until = s.pausedUntil {
                if t.now < until {
                    fx.append(.status(status(s, t.config, now: t.now, meeting: false, away: false)))
                    return (s, fx)
                }
                s.pausedUntil = nil
            }

            // On a call. By default we hold breaks until it ends. With on-call nudges
            // enabled we instead keep counting and deliver a gentle nudge at the fire
            // points below, so call-heavy days still get micro-breaks.
            let onCall = t.config.meetingAware && t.inCall

            // The call's own clock, started on the edge and thrown away when the call
            // drops. `fire` reads it to leave a meeting's opening minutes alone.
            s.callSince = onCall ? (s.callSince ?? t.now) : nil

            if onCall {
                // How long a call has kept you from each break. Counted here, above the
                // holding return, because it has to mean the same thing in both call
                // modes: holding freezes `elapsed`, so the debt itself stops growing and
                // would report a two-hour call as costing nothing. This is wall time on a
                // call since the last real rest, which is the question actually being
                // asked — "how long did calls stop me moving" — and it survives the freeze.
                //
                // Both tracks accrue it, and the two are never added together: a minute
                // on a call holds off your eyes and your legs at the same time, so the
                // sum would count that minute twice and stop being a quantity of time.
                s.eye.callHeld += t.delta
                s.move.callHeld += t.delta

                // Never cover a call. This is the one place in the loop that hands
                // control back mid-tick: the handler dismisses the overlay and finishes
                // the break, which runs a whole nested tick before this one resumes. So
                // the reducer stops here, asks the shell to run that handler, and asks
                // to be re-entered for the rest of the tick with `overlayShowing` and the
                // preferences freshly sampled — exactly what the old code saw when the
                // handler returned and it read those two globals again. No status goes
                // out on this path; the resumed half emits it, after the nested tick's.
                //
                // Unless you asked for it. "Never cover a call" is there to stop the
                // app ambushing you, and a break you chose from the menu while already
                // on the call is the opposite of an ambush — pulling it off the screen
                // is the app overruling you, which is the thing it was trying not to do.
                if t.overlayShowing, !s.askedFor {
                    fx.append(.meetingDuringBreak)
                    fx.append(.resumeTick(t, onCall: true))
                    return (s, fx)
                }
            }

            let (after, tail) = tickTail(s, t, onCall: onCall)
            return (after, fx + tail)
        }
    }

    /// The rest of a tick, from the on-call holding return down. Two ways in: by
    /// fall-through from `.tick`, and directly from `.resumeTick` after the
    /// meeting handler has run. One copy of the rules either way.
    ///
    /// `onCall` is carried in rather than recomputed, because the original read
    /// it once at the top of the tick and used that value for the whole of it.
    private static func tickTail(_ s: State, _ t: Tick, onCall: Bool) -> (State, [Effect]) {
        var s = s
        var fx: [Effect] = []
        let present = t.idle < 2

        if onCall, !t.config.callBreaks {
            fx.append(.status(status(s, t.config, now: t.now, meeting: onCall, away: false)))
            return (s, fx)
        }

        // Away: the screen is locked, or nobody has touched the machine for long
        // enough that a break has no one to show itself to. Keep counting so the
        // break you're owed is waiting when you get back, but hold the overlay
        // meanwhile. The threshold is the same "away this long is a real rest" you
        // set in the menu, so there is one answer to "have I left" and not two:
        // below it, reading at your desk still counts as screen time and you still
        // get your breaks.
        //
        // Deliberately *not* behind `idleAware`, which the credits in `creditAway`
        // are. That switch says "reset my counters when I step away", and it was
        // briefly holding two powers: turning it off also gave back "fire breaks at
        // an empty room and auto-complete them", which is the failure this whole
        // area exists to prevent and not something anybody would choose. Whether a
        // rest gets credited is a preference. Whether a break is shown to a chair
        // is not.
        if s.screenLocked || t.idle >= Double(t.config.awayResetSec) {
            fx.append(.status(status(s, t.config, now: t.now, meeting: onCall, away: true)))
            return (s, fx)
        }

        if t.overlayShowing {
            fx.append(.status(status(s, t.config, now: t.now, meeting: onCall, away: false)))
            return (s, fx)
        }

        // A typed one-off break fires first, once its time arrives.
        if let p = s.pending, t.now >= p.date {
            s.pending = nil
            let fired = fire(s, p.kind, onCall: onCall, now: t.now, t.config)
            s = fired.0; fx += fired.1
            fx.append(.status(status(s, t.config, now: t.now, meeting: onCall, away: false)))
            return (s, fx)
        }

        s.eye.elapsed += t.delta
        s.move.elapsed += t.delta

        // Only this line of the tick is reached with a human demonstrably present
        // and the counters up to date, which makes it the one honest place to record
        // "this is what was owed while someone was here". Every path above either
        // freezes the counters (paused, on a call, a break on screen) or is the
        // absence itself, so a snapshot that lags one of those is still correct.
        if present { s.presentDebt = gauges(s, t.config) }

        if t.config.moveEnabled, s.move.isDue(interval: Double(t.config.moveIntervalSec), now: t.now) {
            let fired = fire(s, .move, onCall: onCall, now: t.now, t.config)
            s = fired.0; fx += fired.1
        } else if t.config.eyeEnabled, s.eye.isDue(interval: Double(t.config.eyeIntervalSec), now: t.now) {
            let fired = fire(s, .eye, onCall: onCall, now: t.now, t.config)
            s = fired.0; fx += fired.1
        }

        fx.append(.status(status(s, t.config, now: t.now, meeting: onCall, away: false)))
        return (s, fx)
    }

    // MARK: pure helpers


    /// Something that isn't a break rested you: a long enough lock, a long enough
    /// spell with nobody at the machine, or the machine asleep. One door for all
    /// three, because two of them can land on the same tick — a locked laptop that
    /// slept and then woke — and a rest has to be credited, and logged, once.
    ///
    /// Short spells credit nothing: five minutes away is not a rest, and the
    /// counter should still be where you left it.
    static func creditAway(_ s: State, seconds: Int, _ c: Config) -> (State, [Effect]) {
        guard seconds >= c.awayResetSec else { return (s, []) }
        guard s.eye.elapsed > 0 || s.move.elapsed > 0 else { return (s, []) }   // already rested; don't log it twice
        var s = s
        let cleared = s.presentDebt
        s.eye = s.eye.rested
        s.move = s.move.rested
        s.presentDebt = gauges(s, c)
        return (s, [.awayRest(cleared: cleared, seconds: seconds)])
    }

    /// Deliver a due break: a gentle nudge while on a call (on-call nudges on),
    /// otherwise the full overlay. Nothing is credited either way — showing you a
    /// break is not resting, so the counter keeps climbing through a whole call.
    static func fire(_ s: State, _ kind: BreakKind, onCall: Bool, now: Date, _ c: Config) -> (State, [Effect]) {
        guard onCall else { return (s, [.breakDue(kind, trail: trail(s, kind))]) }
        // A meeting that has only just started gets its opening minutes back. The break
        // stays owed and the counter keeps climbing, so nothing is forgiven — it is the
        // banner that waits. A nudge two minutes into a call arrives while you are still
        // saying hello, and it is not a thing you can act on; the same nudge twenty
        // minutes in is. Held back this way it is not a refusal either, because you were
        // never asked.
        if let since = s.callSince, now.timeIntervalSince(since) < Deferral.callGraceSec { return (s, []) }
        guard track(s, kind).canNudge(now: now) else { return (s, []) }
        return (over(s, kind) { $0.nudged(at: now) }, [.callNudge(kind)])
    }

    /// Credit a real rest. A movement break rests the eyes too, so it clears
    /// both — but only ever for a break that was actually taken.
    static func credited(_ s: State, _ kind: BreakKind) -> State {
        var s = s
        s.eye = s.eye.rested
        if kind == .move { s.move = s.move.rested }
        return s
    }

    /// Put one track through a function and give back the state that results. The
    /// one door to a track, so "which of the two is this" is answered in a single
    /// place and a transform can't be applied to half of a pair.
    static func over(_ s: State, _ kind: BreakKind, _ f: (Track) -> Track) -> State {
        var s = s
        if kind == .eye { s.eye = f(s.eye) } else { s.move = f(s.move) }
        return s
    }

    static func track(_ s: State, _ kind: BreakKind) -> Track {
        kind == .eye ? s.eye : s.move
    }

    static func trail(_ s: State, _ kind: BreakKind) -> [Mark] { track(s, kind).trail }

    static func status(_ s: State, _ c: Config, now: Date, meeting: Bool, away: Bool) -> Status {
        Status(
            paused: s.pausedUntil.map { $0 > now } ?? false,
            pausedUntil: s.pausedUntil,
            meeting: meeting,
            away: away,
            scheduledAt: s.pending?.date,
            eye: gauge(.eye, s.eye, enabled: c.eyeEnabled, interval: Double(c.eyeIntervalSec)),
            move: gauge(.move, s.move, enabled: c.moveEnabled, interval: Double(c.moveIntervalSec)))
    }

    /// Both tracks' readings right now, enabled ones only.
    static func gauges(_ s: State, _ c: Config) -> [Gauge] {
        [gauge(.eye, s.eye, enabled: c.eyeEnabled, interval: Double(c.eyeIntervalSec)),
         gauge(.move, s.move, enabled: c.moveEnabled, interval: Double(c.moveIntervalSec))]
            .filter(\.enabled)
    }

    static func gauge(_ kind: BreakKind, _ t: Track, enabled: Bool, interval: Double) -> Gauge {
        guard enabled else {
            return Gauge(kind: kind, enabled: false, remaining: 0, overdue: 0, strain: 0, refusals: 0, nudges: 0, callHeldSec: 0)
        }
        return Gauge(
            kind: kind,
            enabled: true,
            remaining: Int(max(0, interval - t.elapsed)),
            overdue: Int(max(0, t.elapsed - interval)),
            strain: t.strain(interval: interval),
            refusals: t.refusals,
            nudges: t.nudges,
            callHeldSec: Int(t.callHeld))
    }
}
