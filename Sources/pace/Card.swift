import Foundation

/// The break card as a state machine, in the functional sense of the word: the
/// state is a value, the transition is one total function of `(State, Event)`,
/// and everything the card *looks* like is a pure function of that state. There
/// is no clock in here, no timer, no `Settings`, no AppKit. The shell reads all
/// of those and hands them in as events, exactly as `Scheduler` does for `Loop`.
///
/// The card used to be six `var`s on the controller — `isShowing`, `currentKind`,
/// `startedAt`, `durationSec`, plus two timers — each nudged by hand from four
/// places. Nothing was wrong with what it did; the problem was that "can a
/// keypress end a card that isn't up" could only be answered by reading every
/// method and hoping. It is now a line in a switch, and `--selftest` walks every
/// state against every event to prove the machine is total.
enum Card {

    /// Everything one card knows about itself. Fixed at the moment it opens: the
    /// prompt is drawn once, the trail is what the loop handed over, and the debt
    /// is the reading taken when the break fired. None of it changes while the
    /// card is up — only `remaining` does, and that is a function of the clock.
    struct Session: Equatable {
        let kind: BreakKind
        let trail: [Loop.Mark]
        let overdueSec: Int
        let durationSec: Int
        let startedAt: Date
        let prompt: Prompt
    }

    /// Two states, and the second carries its whole world. A card is up or it
    /// isn't; there is no "closing", because ending *is* the move back to `.idle`.
    enum State: Equatable {
        case idle
        case up(Session, remaining: Int)

        var session: Session? {
            if case .up(let s, _) = self { return s }
            return nil
        }
    }

    /// Everything that can happen to a card. The two clocks (the half-second
    /// countdown and the watchdog) send the same `.tick`, because they are the
    /// same question — what time is it — asked twice for safety.
    enum Event {
        case show(Session)
        case key(BreakKey)      // ⌘S / ⌘5 / ⌘D, Esc, Return
        case clickedOff         // a click anywhere off the card
        case tick(Date)
        case timeUp             // the backstop clock: this card has had its run, end it
        case callStarted        // a call began while the card was up
    }

    /// What the shell must do. Order within the array is behaviour: the window
    /// closes before the break is reported finished, as it always has.
    enum Effect: Equatable {
        case startChime
        case open(Session)
        case remaining(Int)     // repaint the clock
        case endChime
        case close
        case ended(BreakKind, BreakEndReason)
    }

    // MARK: the transition

    /// The whole machine. Total by construction: every state takes every event,
    /// and an event with nothing to act on returns the state it was given and asks
    /// for nothing. That is what makes a stray keypress after the card has gone a
    /// non-event rather than a guard someone has to remember to write.
    static func next(_ state: State, _ event: Event) -> (State, [Effect]) {
        switch (state, event) {

        // Opening. A second `.show` while one is up is ignored rather than
        // queued: two full-screen cards over the same desk is never the answer.
        case (.idle, .show(let s)):
            return (.up(s, remaining: s.durationSec), [.startChime, .open(s)])
        case (.up, .show):
            return (state, [])

        // With no card up, nothing that acts on a card can do anything.
        case (.idle, _):
            return (.idle, [])

        // Ending. Which key ended it is the whole difference between a rest and a
        // refusal, so the mapping lives here, once, as data.
        case (.up(let s, _), .key(.skip)),
             (.up(let s, _), .clickedOff):
            return end(s, .skipped)
        case (.up(let s, _), .key(.snooze)):
            return end(s, .snoozed)
        case (.up(let s, _), .key(.done)):
            return end(s, .completed)
        case (.up(let s, _), .callStarted):
            return end(s, .interrupted)

        // The backstop, and deliberately not a `.tick`. Asking "what time is it"
        // twice is only a guarantee while the clock runs forwards: an NTP step
        // backwards, or a clock change, and a tick that should have closed the
        // card instead computes a minute still to run and leaves a full-screen
        // window over the desk. This one ends it because it was asked to, not
        // because of what a clock said.
        case (.up(let s, _), .timeUp):
            return end(s, .completed)

        // The countdown. What's left is recomputed from the clock rather than
        // counted down in ticks, so a starved run loop or a slept machine catches
        // up on the next fire instead of leaving the card stuck. A card can never
        // outlive its own countdown: any tick at or past the end closes it,
        // whichever clock sent it.
        case (.up(let s, let shown), .tick(let now)):
            let left = Double(s.durationSec) - now.timeIntervalSince(s.startedAt)
            if left <= 0 { return end(s, .completed) }
            let whole = max(0, Int(left.rounded(.up)))
            return whole == shown ? (state, []) : (.up(s, remaining: whole), [.remaining(whole)])
        }
    }

    /// One way out, so every ending closes the window and reports itself in the
    /// same order. The chime is asked for only on a natural finish; whether it is
    /// actually played is the shell's business, because that's a preference.
    private static func end(_ s: Session, _ reason: BreakEndReason) -> (State, [Effect]) {
        (.idle, (reason == .completed ? [.endChime] : []) + [.close, .ended(s.kind, reason)])
    }

    // MARK: what the card looks like, as a function of the state

    /// Everything drawn, derived. The card shows the difference since you last saw
    /// it — where you were, the one thing that has happened, and now — so one mark
    /// is all it ever needs. The view holds one of these and renders it; it
    /// computes nothing, which is why the whole card can be checked in `--selftest`
    /// without a window, a screen or a run loop.
    struct Model: Equatable {
        let kind: BreakKind
        let title: String
        let story: Bool             // is there anything to tell? put off, or late
        let step: Loop.Mark?        // the one thing that happened, as the arrow's label
        let late: String?           // "22m late", or nil while it is merely due
        let line: String?           // the sentence under the chain; nil when there's no story
        let prompt: Prompt
        let clock: String
        let doneLabel: String
    }

    static func model(_ s: Session, remaining: Int) -> Model {
        // Something to tell: this break was put off, or it is late. Either earns
        // the chain; a break that turns up on time and clean gets neither it nor
        // the sentence.
        return Model(
            kind: s.kind,
            title: s.kind.title,
            story: !s.trail.isEmpty || s.overdueSec >= 60,
            step: s.trail.last,
            late: s.overdueSec >= 60 ? "\(s.overdueSec / 60)m late" : nil,
            line: line(trail: s.trail),
            prompt: s.prompt,
            clock: clock(remaining),
            doneLabel: s.kind.doneLabel)
    }

    /// Said once, plainly, in whatever terms this break actually earned. Not a
    /// scold: the point is that putting a break off is no longer invisible, and
    /// that a call holding it back doesn't read as something you did.
    ///
    /// What you chose and what happened to you are separate sentences on purpose.
    /// Folded into one count, four extensions and three calls read as seven times
    /// you ignored it, which isn't true and isn't fair.
    ///
    /// How late it is isn't in here: the chain's own last word says that, and the
    /// same number twice in two lines is one line too many.
    static func line(trail: [Loop.Mark]) -> String? {
        func count(_ m: Loop.Mark) -> Int { trail.filter { $0 == m }.count }

        var mine: [String] = []
        if count(.snoozed) > 0 { mine.append("put this one off \(times(count(.snoozed)))") }
        if count(.skipped) > 0 { mine.append("skipped it \(times(count(.skipped)))") }
        var calls: [String] = []
        if count(.held) > 0 { calls.append("held it back \(times(count(.held)))") }
        if count(.interrupted) > 0 { calls.append("cut it short \(times(count(.interrupted)))") }

        var lines: [String] = []
        if !mine.isEmpty { lines.append("You've " + mine.joined(separator: " and ") + " since your last rest.") }
        if !calls.isEmpty { lines.append("A call " + calls.joined(separator: " and ") + ".") }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func times(_ n: Int) -> String {
        switch n {
        case 1:  return "once"
        case 2:  return "twice"
        default: return "\(n) times"
        }
    }
}

extension Loop.Mark {
    /// The label on the arrow: what happened, in the fewest words that are still
    /// the truth. Copy rather than decoration, so it lives with the card's other
    /// words and not inside a view.
    var phrase: String {
        switch self {
        case .snoozed:     return "+5 min"
        case .skipped:     return "Skipped"
        case .held:        return "Call held it"
        case .interrupted: return "Call cut in"
        }
    }

    /// How this mark is spoken aloud, for the chain's accessibility label. Kept
    /// with the mark rather than in the view: it is a fact about the mark.
    var spoken: String {
        switch self {
        case .snoozed:     return "put off five minutes"
        case .skipped:     return "skipped"
        case .interrupted: return "cut short by a call"
        case .held:        return "held back by a call"
        }
    }
}
