import Foundation

enum BreakKind {
    case eye, move
    var title: String { self == .eye ? "Rest your eyes" : "Move your body" }
    var durationSec: Int { self == .eye ? Settings.eyeDurationSec : Settings.moveDurationSec }
    var label: String { self == .eye ? "eye" : "move" }
    var shortName: String { self == .eye ? "Eye" : "Move" }
    var doneLabel: String { self == .eye ? "Already rested" : "Already moved" }
}

/// How a break window closed. Only `completed` credits a rest; the rest are
/// refusals, and a refusal buys quiet, never credit.
enum BreakEndReason {
    case completed      // sat through it, or said "already rested"
    case snoozed        // "+5 min"
    case skipped        // "Skip"
    case interrupted    // a call started: not the user's choice, so not their fault

    var logName: String {
        switch self {
        case .completed:   return "completed"
        case .skipped:     return "skipped"
        case .snoozed:     return "snoozed"
        case .interrupted: return "interrupted"
        }
    }

    /// Does this rest you? Exactly one reason does.
    var creditsRest: Bool { self == .completed }

    /// How long the break stays quiet before it is due again.
    var deferSec: TimeInterval {
        switch self {
        case .completed:   return 0
        case .snoozed:     return Deferral.snoozeSec
        case .skipped:     return Deferral.skipSec
        case .interrupted: return Deferral.interruptSec
        }
    }

    /// Does this count against you as "putting it off"? A call interrupting a
    /// break doesn't; choosing to extend or skip does.
    var isRefusal: Bool { self == .snoozed || self == .skipped }
}

/// What putting a break off costs. The answer is: only time, never credit. The
/// counter keeps climbing through every deferral, so the debt (and the menu-bar
/// eye) keeps getting worse the longer you hold out. Declared here as data so
/// there is one place to read the policy, and none to derive it by arithmetic.
enum Deferral {
    static let snoozeSec: TimeInterval = 5 * 60      // "+5 min" means five minutes
    static let skipSec: TimeInterval = 10 * 60       // "Skip" buys longer quiet
    static let interruptSec: TimeInterval = 2 * 60   // a call cut it short: try again soon
    static let nudgeSec: TimeInterval = 5 * 60       // gap between on-call nudges
}

/// The outside world the loop reads: two clocks and two sensors. Injected so the
/// loop can be driven deterministically by `pace --sim`, with no mic and no
/// waiting. `work` is monotonic and excludes system sleep — asleep eyes aren't
/// straining — while `wall` is real time, which is what "away for 20 minutes"
/// and "quiet until 3:05" actually mean.
struct Env {
    var work: () -> Double = { ProcessInfo.processInfo.systemUptime }
    var wall: () -> Date = { Date() }
    var inCall: () -> Bool = { Signals.inCall() }
    var idleSec: () -> Double = { Signals.idleSeconds() }
}

/// The core feedback loop: one 1-second tick that advances two counters (eye,
/// move) toward their intervals and fires a break when one is due.
///
/// The one invariant everything else follows from: a counter measures **seconds
/// of screen work since that break type last actually rested you**. Showing you
/// a break doesn't reset it. Extending or skipping doesn't reset it. Only
/// sitting through a break, saying you already took one, or a long enough
/// locked-away spell does. So if you keep extending, the debt keeps growing and
/// the bar keeps showing it.
///
/// It holds during calls, keeps counting while the screen is locked (so a loo
/// break doesn't wipe your progress), and reads `Settings` live, so changing a
/// setting in the menu takes effect on the next tick with no extra wiring.
final class Scheduler {

    /// One break type's state. Keeping the counter and its deferral together in
    /// one value is what stops the pair drifting apart when only half of it gets
    /// updated — the bug that used to hand you a free eye rest for snoozing a
    /// movement break.
    private struct Track {
        var elapsed: Double = 0     // seconds of screen work since a real rest
        var deferUntil: Date?       // put off: quiet until then, debt still climbing
        var refusals = 0            // times put off since the last real rest
        var lastNudge: Date?        // last on-call nudge; its own gap, not the break's

        mutating func rested() { elapsed = 0; deferUntil = nil; refusals = 0; lastNudge = nil }

        /// A nudge has its own quiet gap so a long call doesn't buzz every second.
        /// Deliberately separate from `deferUntil`: the break is still owed, so
        /// when the call ends it comes up at once rather than waiting out a gap it
        /// never asked for.
        func canNudge(now: Date) -> Bool {
            lastNudge.map { now.timeIntervalSince($0) >= Deferral.nudgeSec } ?? true
        }

        mutating func put(off seconds: TimeInterval, now: Date, refusal: Bool) {
            deferUntil = now.addingTimeInterval(seconds)
            if refusal { refusals += 1 }
        }

        func isDue(interval: Double, now: Date) -> Bool {
            elapsed >= interval && (deferUntil.map { now >= $0 } ?? true)
        }

        /// 0 just rested, 1 due, above 1 overdue by that fraction of an interval.
        func strain(interval: Double) -> Double {
            interval > 0 ? elapsed / interval : 0
        }
    }

    private var eye = Track()
    private var move = Track()
    private var pausedUntil: Date?
    private var pending: (date: Date, kind: BreakKind)?   // a one-off typed/scheduled break
    private var timer: Timer?
    private var lastWork: Double = 0
    private var lastWall: Date?

    /// The outside world. Replaced wholesale by `--sim`.
    var env = Env()

    // Set by the overlay controller so we never stack a second break on the first.
    var overlayShowing = false

    // Away tracking, driven by screen lock (not idle time, so reading never
    // counts as away). While locked we keep counting but hold the overlay; on
    // unlock we credit a rest only if the lock lasted long enough to be one.
    private var screenLocked = false
    private var lockedSince: Date?

    /// What each track owed the last time there was demonstrably a human here.
    /// The counters deliberately keep climbing while you're away, so that the break
    /// you're owed is waiting when you get back — which makes *now* the wrong
    /// reading to record when something finally rests you. An hour at lunch is not
    /// an hour of eye strain. One field for all three away paths (locked, no input,
    /// asleep), because "the debt you walked away with" is the same fact in each.
    private var presentDebt: [Gauge] = []

    /// The idle spell as of the last tick. When input comes back, this is how long
    /// nobody was there — the sensor that doesn't depend on a notification arriving.
    private var lastIdle: Double = 0

    // Per-tick snapshot, used only to build the UI status.
    private var stMeeting = false
    private var stAway = false

    var onTick: ((Status) -> Void)?
    var onBreakDue: ((BreakKind, Int) -> Void)?   // kind, times it's already been put off
    var onMeetingDuringBreak: (() -> Void)?   // a call started while a break is up
    var onCallNudge: ((BreakKind) -> Void)?   // a due break during a call (on-call nudges on)

    /// A rest credited by a long enough spell away from the keys, with what each
    /// enabled track owed at the moment it cleared, and how long you were away.
    /// The loop has always credited this; nothing recorded it, so the log claimed
    /// you'd gone a whole lunch without resting.
    var onAwayRest: (([Gauge], Int) -> Void)?

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

        var name: String { kind.shortName }
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

    func start() {
        lastWork = env.work()
        lastWall = env.wall()
        presentDebt = currentGauges()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    // MARK: user actions

    func pause(for seconds: TimeInterval) { pausedUntil = env.wall().addingTimeInterval(seconds); tick() }

    func pauseUntilTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: env.wall()))!
        pausedUntil = cal.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow)
        tick()
    }

    func pause(until date: Date) { pausedUntil = date; tick() }

    var isPaused: Bool { pausedUntil.map { $0 > env.wall() } ?? false }
    func resume() { pausedUntil = nil; tick() }

    /// Screen lock / unlock (from the workspace notifications). Locking marks you
    /// away; unlocking after a long enough lock is a real rest, so it credits one.
    func setScreenLocked(_ locked: Bool) {
        if locked {
            screenLocked = true
            lockedSince = env.wall()
        } else {
            unlock()
        }
        tick()
    }

    /// The unlock half, without the re-tick, so the missed-notification watchdog
    /// in `tick` can reuse it without recursing.
    private func unlock() {
        if let since = lockedSince {
            creditAway(seconds: Int(env.wall().timeIntervalSince(since)))
        }
        screenLocked = false
        lockedSince = nil
    }

    /// Something that isn't a break rested you: a long enough lock, a long enough
    /// spell with nobody at the machine, or the machine asleep. One door for all
    /// three, because two of them can land on the same tick — a locked laptop that
    /// slept and then woke — and a rest has to be credited, and logged, once.
    ///
    /// Short spells credit nothing: five minutes away is not a rest, and the
    /// counter should still be where you left it.
    private func creditAway(seconds: Int) {
        guard seconds >= Settings.awayResetSec else { return }
        guard eye.elapsed > 0 || move.elapsed > 0 else { return }   // already rested; don't log it twice
        let cleared = presentDebt
        eye.rested()
        move.rested()
        presentDebt = currentGauges()
        onAwayRest?(cleared, seconds)
    }

    /// Schedule one break (typed via the popover). Scheduling implies intent, so
    /// it clears any active pause.
    func scheduleBreak(after t: TimeInterval, kind: BreakKind) { pending = (env.wall().addingTimeInterval(t), kind); pausedUntil = nil; tick() }
    func scheduleBreak(at date: Date, kind: BreakKind) { pending = (date, kind); pausedUntil = nil; tick() }

    /// Apply a parsed command from the text entry.
    func dispatch(_ c: Command) {
        switch c {
        case .breakAfter(let t, let k): scheduleBreak(after: t, kind: k)
        case .breakAt(let d, let k):    scheduleBreak(at: d, kind: k)
        case .pauseFor(let t):          pause(for: t)
        case .pauseUntil(let d):        pause(until: d)
        }
    }

    /// Manual "take a break now" from the menu. Asking for a break doesn't rest
    /// you; taking it does, so nothing is credited here.
    func triggerNow(_ kind: BreakKind) {
        guard !overlayShowing else { return }
        onBreakDue?(kind, refusals(of: kind))
    }

    /// Called by the overlay controller when a break window closes. The single
    /// place a rest is credited.
    func breakFinished(_ kind: BreakKind, _ reason: BreakEndReason) {
        if reason.creditsRest {
            credit(kind)
        } else {
            let now = env.wall()
            withTrack(kind) { $0.put(off: reason.deferSec, now: now, refusal: reason.isRefusal) }
            // Putting one break off quiets the other one too, for at least as long.
            // "+5 min" means "leave me alone for five minutes", not "leave this one
            // counter alone" — without this, snoozing a movement break can pop an
            // eye break in the same breath. It buys quiet only: the other counter
            // keeps climbing and it isn't recorded as a refusal, because it wasn't.
            let other: BreakKind = kind == .eye ? .move : .eye
            withTrack(other) {
                let floor = now.addingTimeInterval(reason.deferSec)
                if ($0.deferUntil ?? now) < floor { $0.deferUntil = floor }
            }
        }
        tick()
    }

    // MARK: the loop

    private func withTrack(_ kind: BreakKind, _ body: (inout Track) -> Void) {
        if kind == .eye { body(&eye) } else { body(&move) }
    }

    private func refusals(of kind: BreakKind) -> Int { kind == .eye ? eye.refusals : move.refusals }

    /// Credit a real rest. A movement break rests the eyes too, so it clears
    /// both — but only ever for a break that was actually taken.
    private func credit(_ kind: BreakKind) {
        if kind == .move { move.rested(); eye.rested() }
        else { eye.rested() }
    }

    /// Real awake seconds since the last tick, from the monotonic work clock. The
    /// timer is only a nudge to look at the clock, never the clock itself: if the
    /// run loop is starved (App Nap, a slow write) the next tick still counts every
    /// second that passed, so the loop heals instead of silently losing time.
    private func elapsedSinceLastTick() -> (work: Double, wall: Double) {
        let now = env.work()
        let work = max(0, now - lastWork)
        lastWork = now

        let wallNow = env.wall()
        let wall = lastWall.map { max(0, wallNow.timeIntervalSince($0)) } ?? work
        lastWall = wallNow
        return (work, wall)
    }

    /// Advance the loop one step, reading the injected clock. `start()`'s timer
    /// calls this once a second; `--sim` calls it directly so a whole scenario can
    /// run in milliseconds. The only reason `tick` has a public door at all.
    func step() { tick() }

    private func tick() {
        let now = env.wall()
        let (delta, wallDelta) = elapsedSinceLastTick()
        let idle = env.idleSec()
        stMeeting = false
        stAway = false
        defer { emit(); lastIdle = idle }

        if Settings.idleAware {
            // The machine was asleep, or this process was starved, for the gap
            // between the two clocks: wall time that was not screen work. A clock
            // can't drop a notification, which is why this is the backstop.
            creditAway(seconds: Int(wallDelta - delta))

            // Input came back after a long spell of none. This is the case that ran
            // all night: a Mac held awake and unlocked by something else (audio
            // assertions, in the event that found it), pace counting screen work and
            // firing breaks into an empty room, each one auto-completing as a rest
            // nobody took. A screen that never locks is not a human who never left.
            if idle < lastIdle { creditAway(seconds: Int(lastIdle)) }
        }

        // Self-heal a missed unlock notification: if we think the screen is
        // locked but there has been human input in the last couple of seconds,
        // we are demonstrably back at the desk. Without this a single dropped
        // notification would wedge the app in "away" forever.
        if screenLocked, idle < 2 { unlock() }

        if let until = pausedUntil {
            if now < until { return }
            pausedUntil = nil
        }

        // On a call. By default we hold breaks until it ends. With on-call nudges
        // enabled we instead keep counting and deliver a gentle nudge at the fire
        // points below, so call-heavy days still get micro-breaks.
        let onCall = Settings.meetingAware && env.inCall()
        if onCall {
            stMeeting = true
            if overlayShowing { onMeetingDuringBreak?() }   // never cover a call
            if !Settings.callBreaks { return }
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
        if screenLocked || idle >= Double(Settings.awayResetSec) {
            stAway = true
            eye.elapsed += delta
            move.elapsed += delta
            return
        }

        if overlayShowing { return }

        // A typed one-off break fires first, once its time arrives.
        if let p = pending, now >= p.date {
            pending = nil
            fire(p.kind, onCall: onCall)
            return
        }

        eye.elapsed += delta
        move.elapsed += delta

        // Only this line of the tick is reached with a human demonstrably present
        // and the counters up to date, which makes it the one honest place to record
        // "this is what was owed while someone was here". Every path above either
        // freezes the counters (paused, on a call, a break on screen) or is the
        // absence itself, so a snapshot that lags one of those is still correct.
        if idle < 2 { presentDebt = currentGauges() }

        if Settings.moveEnabled, move.isDue(interval: Double(Settings.moveIntervalSec), now: now) {
            fire(.move, onCall: onCall)
        } else if Settings.eyeEnabled, eye.isDue(interval: Double(Settings.eyeIntervalSec), now: now) {
            fire(.eye, onCall: onCall)
        }
    }

    /// Deliver a due break: a gentle nudge while on a call (on-call nudges on),
    /// otherwise the full overlay. Nothing is credited either way — showing you a
    /// break is not resting, so the counter keeps climbing through a whole call.
    private func fire(_ kind: BreakKind, onCall: Bool) {
        guard onCall else { onBreakDue?(kind, refusals(of: kind)); return }
        let now = env.wall()
        var nudge = false
        withTrack(kind) {
            guard $0.canNudge(now: now) else { return }
            $0.lastNudge = now
            nudge = true
        }
        if nudge { onCallNudge?(kind) }
    }

    private func emit() {
        onTick?(Status(
            paused: isPaused,
            pausedUntil: pausedUntil,
            meeting: stMeeting,
            away: stAway,
            scheduledAt: pending?.date,
            eye: gauge(.eye, eye, enabled: Settings.eyeEnabled, interval: Double(Settings.eyeIntervalSec)),
            move: gauge(.move, move, enabled: Settings.moveEnabled, interval: Double(Settings.moveIntervalSec))))
    }

    /// Both tracks' readings right now, enabled ones only.
    private func currentGauges() -> [Gauge] {
        [gauge(.eye, eye, enabled: Settings.eyeEnabled, interval: Double(Settings.eyeIntervalSec)),
         gauge(.move, move, enabled: Settings.moveEnabled, interval: Double(Settings.moveIntervalSec))]
            .filter(\.enabled)
    }

    private func gauge(_ kind: BreakKind, _ t: Track, enabled: Bool, interval: Double) -> Gauge {
        guard enabled else {
            return Gauge(kind: kind, enabled: false, remaining: 0, overdue: 0, strain: 0, refusals: 0)
        }
        return Gauge(
            kind: kind,
            enabled: true,
            remaining: Int(max(0, interval - t.elapsed)),
            overdue: Int(max(0, t.elapsed - interval)),
            strain: t.strain(interval: interval),
            refusals: t.refusals)
    }
}
