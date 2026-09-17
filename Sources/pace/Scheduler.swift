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

    /// What this leaves on the break's trail, and so on the card next time. A
    /// completed break leaves nothing, because there is no trail left to leave it
    /// on — it has just been cleared.
    var mark: Loop.Mark? {
        switch self {
        case .completed:   return nil
        case .snoozed:     return .snoozed
        case .skipped:     return .skipped
        case .interrupted: return .interrupted
        }
    }
}

/// What putting a break off costs. The answer is: only time, never credit. The
/// counter keeps climbing through every deferral, so the debt (and the menu-bar
/// eye) keeps getting worse the longer you hold out. Declared here as data so
/// there is one place to read the policy, and none to derive it by arithmetic.
enum Deferral {
    static let snoozeSec: TimeInterval = 5 * 60      // "+5 min" means five minutes
    static let skipSec: TimeInterval = 10 * 60       // "Skip" buys longer quiet
    static let interruptSec: TimeInterval = 2 * 60   // a call cut it short: try again soon
    static let nudgeSec: TimeInterval = 5 * 60       // first gap between on-call nudges
    static let nudgeCapSec: TimeInterval = 30 * 60   // and the longest it backs off to
    static let callGraceSec: TimeInterval = 5 * 60   // a meeting's opening minutes are its own
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
/// The rules themselves live in `Loop`, which is pure. What is left here is the
/// machinery that drives them: the clock, the timer, the preferences and the
/// callbacks. Every method below reads the world, hands it to `Loop.step` as a
/// value, stores the state that comes back, and performs the effects.
final class Scheduler {

    typealias Status = Loop.Status
    typealias Gauge  = Loop.Gauge

    private var state = Loop.State()
    private var timer: Timer?
    private var lastWork: Double = 0

    /// The outside world. Replaced wholesale by `--sim`.
    var env = Env()

    // Set by the overlay controller so we never stack a second break on the first.
    var overlayShowing = false

    var onTick: ((Status) -> Void)?
    var onBreakDue: ((BreakKind, [Loop.Mark]) -> Void)?   // kind, and what's already happened to it
    var onMeetingDuringBreak: (() -> Void)?   // a call started while a break is up
    var onCallNudge: ((BreakKind) -> Void)?   // a due break during a call (on-call nudges on)

    /// A rest credited by a long enough spell away from the keys, with what each
    /// enabled track owed at the moment it cleared, and how long you were away.
    /// The loop has always credited this; nothing recorded it, so the log claimed
    /// you'd gone a whole lunch without resting.
    var onAwayRest: (([Gauge], Int) -> Void)?

    func start() {
        lastWork = env.work()
        let (s, _) = Loop.step(state, .start(.live()))
        state = s
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    // MARK: user actions

    func pause(for seconds: TimeInterval) { pause(until: env.wall().addingTimeInterval(seconds)) }

    func pauseUntilTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: env.wall()))!
        setPause(cal.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow))
    }

    func pause(until date: Date) { setPause(date) }

    var isPaused: Bool { state.pausedUntil.map { $0 > env.wall() } ?? false }
    func resume() { setPause(nil) }

    private func setPause(_ date: Date?) {
        let (s, _) = Loop.step(state, .pause(until: date))
        state = s
        tick()
    }

    /// Screen lock / unlock (from the workspace notifications). Locking holds the
    /// overlay back: a break has nobody to show itself to on a lock screen.
    ///
    /// It no longer credits the rest the lock earned, and doesn't need to. Unlocking
    /// takes a password or a touch, so the presence clock in `tick` sees a human
    /// arrive and credits the whole absence — from the same field, by the same rule
    /// as every other way of coming back. A lock is one way to be away, not a second
    /// kind of away needing its own arithmetic.
    func setScreenLocked(_ locked: Bool) {
        let (s, _) = Loop.step(state, .setScreenLocked(locked))
        state = s
        tick()
    }

    /// Schedule one break (typed via the popover). Scheduling implies intent, so
    /// it clears any active pause.
    func scheduleBreak(after t: TimeInterval, kind: BreakKind) { scheduleBreak(at: env.wall().addingTimeInterval(t), kind: kind) }

    func scheduleBreak(at date: Date, kind: BreakKind) {
        let (s, _) = Loop.step(state, .scheduleBreak(at: date, kind: kind))
        state = s
        tick()
    }

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
        let (s, effects) = Loop.step(state, .triggerNow(kind, overlayShowing: overlayShowing))
        state = s
        _ = apply(effects)
    }

    /// Called by the overlay controller when a break window closes. The single
    /// place a rest is credited.
    func breakFinished(_ kind: BreakKind, _ reason: BreakEndReason) {
        let (s, _) = Loop.step(state, .breakFinished(kind, reason, now: env.wall()))
        state = s
        tick()
    }

    // MARK: the loop

    /// Real awake seconds since the last tick, from the monotonic work clock. The
    /// timer is only a nudge to look at the clock, never the clock itself: if the
    /// run loop is starved (App Nap, a slow write) the next tick still counts every
    /// second that passed, so the loop heals instead of silently losing time.
    private func elapsedSinceLastTick() -> Double {
        let now = env.work()
        let work = max(0, now - lastWork)
        lastWork = now
        return work
    }

    /// Advance the loop one step, reading the injected clock. `start()`'s timer
    /// calls this once a second; `--sim` calls it directly so a whole scenario can
    /// run in milliseconds. The only reason `tick` has a public door at all.
    func step() { tick() }

    /// Sample the world, run the rules, perform what they ask for.
    ///
    /// The loop around `apply` is the suspension from `Loop.step`: a call starting
    /// while a break is on screen hands control to `onMeetingDuringBreak`, which
    /// dismisses the break and runs a whole nested tick before this one continues.
    /// The re-entry re-reads `overlayShowing` and the preferences, because that
    /// handler has just changed the first and the second is a global — and carries
    /// the tick's own `now`, `delta`, `idle` and `inCall` through unchanged.
    private func tick() {
        // `meetingAware` gates the sensor here, not just the rule. `Loop.step` ANDs
        // the two again, so moving the check out of the loop can't change what the
        // loop decides — but leaving it there would poll CoreAudio and CoreMediaIO
        // once a second for someone who switched meeting-awareness off, which is
        // what the old tick's short-circuit quietly avoided.
        let cfg = Loop.Config.live()
        var t = Loop.Tick(now: env.wall(), delta: elapsedSinceLastTick(), idle: env.idleSec(),
                          inCall: cfg.meetingAware && env.inCall(),
                          overlayShowing: overlayShowing, config: cfg)
        var (s, effects) = Loop.step(state, .tick(t))
        state = s
        while let resume = apply(effects) {
            t = resume.tick
            t.overlayShowing = overlayShowing
            t.config = .live()
            (s, effects) = Loop.step(state, .resumeTick(t, onCall: resume.onCall))
            state = s
        }
    }

    /// Perform a run of effects in order, returning the suspended tick if the
    /// rules asked to be re-entered. Callbacks run here and nowhere else, so a
    /// nested tick provoked by one of them completes before the resume.
    @discardableResult
    private func apply(_ effects: [Loop.Effect]) -> (tick: Loop.Tick, onCall: Bool)? {
        var pending: (tick: Loop.Tick, onCall: Bool)?
        for e in effects {
            switch e {
            case .breakDue(let kind, let trail):    onBreakDue?(kind, trail)
            case .callNudge(let kind):              onCallNudge?(kind)
            case .meetingDuringBreak:               onMeetingDuringBreak?()
            case .awayRest(let cleared, let secs):  onAwayRest?(cleared, secs)
            case .status(let status):               onTick?(status)
            case .resumeTick(let t, let onCall):    pending = (t, onCall)
            }
        }
        return pending
    }
}

extension Loop.Config {
    /// The preferences as the loop sees them, sampled whole. The one place the
    /// rules meet `Settings`, and it is on this side of the line.
    static func live() -> Loop.Config {
        .init(eyeEnabled: Settings.eyeEnabled,
              moveEnabled: Settings.moveEnabled,
              eyeIntervalSec: Settings.eyeIntervalSec,
              moveIntervalSec: Settings.moveIntervalSec,
              meetingAware: Settings.meetingAware,
              callBreaks: Settings.callBreaks,
              idleAware: Settings.idleAware,
              awayResetSec: Settings.awayResetSec)
    }
}
