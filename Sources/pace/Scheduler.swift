import Foundation

enum BreakKind {
    case eye, move
    var title: String { self == .eye ? "Rest your eyes" : "Move your body" }
    var durationSec: Int { self == .eye ? Settings.eyeDurationSec : Settings.moveDurationSec }
    var label: String { self == .eye ? "eye" : "move" }
}

enum BreakEndReason {
    case completed, skipped, snoozed
    var logName: String {
        switch self {
        case .completed: return "completed"
        case .skipped:   return "skipped"
        case .snoozed:   return "snoozed"
        }
    }
}

/// The core feedback loop: one 1-second tick that advances two counters (eye,
/// move) toward their intervals and fires a break when one is due. It holds
/// during calls, keeps counting while the screen is locked (so a loo break
/// doesn't wipe your progress), and only resets after a long enough locked break,
/// on unlock. Time spent reading with the screen unlocked never resets. All
/// decisions read `Settings` live, so changing a setting in the menu takes effect
/// on the next tick with no extra wiring.
final class Scheduler {
    private var eyeElapsed = 0
    private var moveElapsed = 0
    private var pausedUntil: Date?
    private var pending: (date: Date, kind: BreakKind)?   // a one-off typed/scheduled break
    private var timer: Timer?

    // Set by the overlay controller so we never stack a second break on the first.
    var overlayShowing = false

    // Away tracking, driven by screen lock (not idle time, so reading never
    // counts as away). While locked we keep counting but hold the overlay; on
    // unlock we reset only if the lock lasted long enough to be a real rest.
    private var screenLocked = false
    private var lockedSince: Date?

    // Per-tick snapshot, used only to build the UI status.
    private var stMeeting = false
    private var stAway = false

    var onTick: ((Status) -> Void)?
    var onBreakDue: ((BreakKind) -> Void)?
    var onMeetingDuringBreak: (() -> Void)?   // a call started while a break is up
    var onCallNudge: ((BreakKind) -> Void)?   // a due break during a call (on-call nudges on)

    struct Status {
        var paused: Bool
        var pausedUntil: Date?
        var meeting: Bool
        var away: Bool
        var eyeRemaining: Int?   // nil when that break type is disabled
        var moveRemaining: Int?
        var scheduledAt: Date?   // a one-off typed break, if any
    }

    func start() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    // MARK: user actions

    func pause(for seconds: TimeInterval) { pausedUntil = Date().addingTimeInterval(seconds); tick() }

    func pauseUntilTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        pausedUntil = cal.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow)
        tick()
    }

    func pause(until date: Date) { pausedUntil = date; tick() }

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }
    func resume() { pausedUntil = nil; tick() }

    /// Screen lock / unlock (from the workspace notifications). Locking marks you
    /// away; unlocking after a long enough lock counts as a real rest and resets.
    func setScreenLocked(_ locked: Bool) {
        if locked {
            screenLocked = true
            lockedSince = Date()
        } else {
            if let since = lockedSince, Date().timeIntervalSince(since) >= Double(Settings.awayResetSec) {
                eyeElapsed = 0          // a real, long-enough break happened
                moveElapsed = 0
            }
            screenLocked = false
            lockedSince = nil
            tick()                      // back at the desk: fire an owed break now if due
        }
    }

    /// Schedule one break (typed via the popover). Scheduling implies intent, so
    /// it clears any active pause.
    func scheduleBreak(after t: TimeInterval, kind: BreakKind) { pending = (Date().addingTimeInterval(t), kind); pausedUntil = nil; tick() }
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

    /// Manual "take a break now" from the menu.
    func triggerNow(_ kind: BreakKind) {
        guard !overlayShowing else { return }
        reset(for: kind)
        onBreakDue?(kind)
    }

    /// Called by the overlay controller when a break window closes.
    func breakFinished(_ kind: BreakKind, _ reason: BreakEndReason) {
        // completed / skipped: counters were already reset when the break fired.
        // snoozed: re-arm this break to fire again in 5 minutes.
        if reason == .snoozed {
            let inFive = 5 * 60
            if kind == .eye { eyeElapsed = max(0, Settings.eyeIntervalSec - inFive) }
            else            { moveElapsed = max(0, Settings.moveIntervalSec - inFive) }
        }
    }

    // MARK: the loop

    private func reset(for kind: BreakKind) {
        // A movement break rests the eyes too, so it clears both counters.
        if kind == .move { moveElapsed = 0; eyeElapsed = 0 }
        else { eyeElapsed = 0 }
    }

    private func tick() {
        stMeeting = false
        stAway = false
        defer { emit() }

        if let until = pausedUntil {
            if Date() < until { return }
            pausedUntil = nil
        }

        // On a call. By default we hold breaks until it ends. With on-call nudges
        // enabled we instead keep counting and deliver a gentle nudge at the fire
        // points below (via `onCall`), so call-heavy days still get micro-breaks.
        let onCall = Settings.meetingAware && Signals.inCall()
        if onCall {
            stMeeting = true
            if overlayShowing { onMeetingDuringBreak?() }   // never cover a call
            if !Settings.callBreaks { return }
        }

        // Screen locked = genuinely away. Keep counting so the break you're owed
        // is waiting when you unlock, but hold the overlay meanwhile. Reading with
        // the screen unlocked never counts as away, so it never resets and you
        // still get your breaks. The reset (if the lock was long) happens in
        // setScreenLocked on unlock.
        if Settings.idleAware && screenLocked {
            stAway = true
            eyeElapsed += 1
            moveElapsed += 1
            return
        }

        if overlayShowing { return }

        // A typed one-off break fires first, once its time arrives.
        if let p = pending, Date() >= p.date {
            pending = nil
            fire(p.kind, onCall: onCall)
            return
        }

        eyeElapsed += 1
        moveElapsed += 1

        if Settings.moveEnabled && moveElapsed >= Settings.moveIntervalSec {
            fire(.move, onCall: onCall)
        } else if Settings.eyeEnabled && eyeElapsed >= Settings.eyeIntervalSec {
            fire(.eye, onCall: onCall)
        }
    }

    /// Deliver a due break: a gentle nudge while on a call (on-call nudges on),
    /// otherwise the full overlay. Resets the counter either way.
    private func fire(_ kind: BreakKind, onCall: Bool) {
        reset(for: kind)
        if onCall { onCallNudge?(kind) } else { onBreakDue?(kind) }
    }

    private func emit() {
        let status = Status(
            paused: isPaused,
            pausedUntil: pausedUntil,
            meeting: stMeeting,
            away: stAway,
            eyeRemaining: Settings.eyeEnabled ? max(0, Settings.eyeIntervalSec - eyeElapsed) : nil,
            moveRemaining: Settings.moveEnabled ? max(0, Settings.moveIntervalSec - moveElapsed) : nil,
            scheduledAt: pending?.date)
        onTick?(status)
    }
}
