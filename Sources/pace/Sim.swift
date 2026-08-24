import Foundation

/// `pace --sim "<script>"`: drive the real `Scheduler` off a fake clock and print
/// the trace. This exists because the loop is the product, and the loop's bugs
/// are all bugs of *time* — a counter that resets when it shouldn't, a deferral
/// that comes back too soon. Waiting twenty real minutes to see one is no way to
/// check anything, so the clocks, the mic and the idle sensor are all injected and
/// the whole scenario runs in a few milliseconds.
///
///     pace --sim                                   # the default: extend a break four times
///     pace --sim "eye 5m, work 5m, snooze, work 5m, snooze, work 5m, done"
///
/// Ops, comma or newline separated:
///   eye <dur> / move <dur>   set an interval (short ones keep a trace readable)
///   moveoff / eyeoff         turn a break type off
///   nudges                   turn on-call nudges on
///   work <dur>               work at the desk
///   call <dur>               work with the mic live
///   lock <dur>               screen locked, then unlocked
///   lostunlock <dur>         locked, then the unlock notification is dropped — the
///                            watchdog must notice you're back anyway
///   snooze / skip / done / interrupt      resolve the break that's on screen
///   pause <dur>              pause the app
enum Sim {

    /// A reference box for the pending event lines. Needed because resolving a
    /// break can make the scheduler fire the *other* break re-entrantly, and two
    /// `inout` appends to the same array is an exclusivity trap.
    private final class Pending { var kind: BreakKind? }

    private final class Journal {
        var lines: [String] = []
        func add(_ s: String) { lines.append(s) }
        func take() -> [String] { defer { lines = [] }; return lines }
    }

    private final class Fake {
        var work: Double = 10_000
        var wall = Date(timeIntervalSince1970: 1_755_000_000)   // fixed, so traces are comparable
        var inCall = false
        var locked = false

        func advance(_ seconds: Double) {
            work += seconds
            wall = wall.addingTimeInterval(seconds)
        }
    }

    static func run(_ script: String) -> Int32 {
        // A throwaway settings domain: the sim must not be able to change the
        // real app's configuration as a side effect of being run.
        let suite = "global.ampeco.pace.sim"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        guard let store = UserDefaults(suiteName: suite) else {
            print("sim: could not open a scratch settings domain")
            return 1
        }
        Settings.store = store
        Settings.registerDefaults()
        defer {
            Settings.store = UserDefaults.standard
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        let clock = Fake()
        let sched = Scheduler()
        sched.env = Env(work: { clock.work },
                        wall: { clock.wall },
                        inCall: { clock.inCall },
                        idleSec: { clock.locked ? 600 : 0 })

        let box = Pending()
        let journal = Journal()
        var last: Scheduler.Status?

        sched.onTick = { last = $0 }
        sched.onBreakDue = { kind, _ in
            box.kind = kind
            sched.overlayShowing = true
            journal.add("BREAK DUE (\(kind.label))")
        }
        sched.onCallNudge = { kind in journal.add("nudge (\(kind.label)) — on a call") }
        sched.onMeetingDuringBreak = {
            guard box.kind != nil else { return }
            journal.add("a call started, break stepped aside")
            resolve(sched, box, .interrupted, journal)
        }

        // Fail closed. A typo — `snoze` for `snooze` — would otherwise run a
        // different scenario and print a clean-looking trace, and every claim about
        // the loop rests on these traces being the scenario you asked for.
        guard let ops = parse(script) else { return 1 }
        guard !ops.isEmpty else { print("sim: nothing to do"); return 1 }

        header()
        sched.start()                       // one tick at t=0
        flush(clock, last, journal, note: "start")

        for op in ops {
            switch op {
            case .setEye(let sec):   Settings.set(.eyeIntervalMin, max(1, sec / 60)); note(clock, last, "eye interval \(mmss(sec))")
            case .setMove(let sec):  Settings.set(.moveIntervalMin, max(1, sec / 60)); note(clock, last, "move interval \(mmss(sec))")
            case .eyeOff:            Settings.set(.eyeEnabled, false); note(clock, last, "eye breaks off")
            case .moveOff:          Settings.set(.moveEnabled, false); note(clock, last, "move breaks off")
            case .nudges:            Settings.set(.callBreaks, true); note(clock, last, "on-call nudges on")
            case .pause(let sec):    sched.pause(for: Double(sec)); flush(clock, last, journal, note: "pause \(mmss(sec))")

            case .work(let sec), .call(let sec), .lock(let sec):
                clock.inCall = op.isCall
                clock.locked = op.isLock
                if op.isLock { sched.setScreenLocked(true) }
                for _ in 0..<sec {
                    clock.advance(1)
                    sched.overlayShowing = (box.kind != nil)
                    sched.step()
                    if !journal.lines.isEmpty { flush(clock, last, journal, note: nil) }
                }
                if op.isLock { clock.locked = false; sched.setScreenLocked(false) }
                clock.inCall = false
                flush(clock, last, journal, note: "\(op.name) \(mmss(sec)) done")

            case .lostUnlock(let sec):
                // Lock properly, then take the screen back without ever telling the
                // scheduler. Only the idle-time watchdog can recover from this.
                clock.locked = true
                sched.setScreenLocked(true)
                for _ in 0..<sec { clock.advance(1); sched.overlayShowing = (box.kind != nil); sched.step() }
                clock.locked = false
                note(clock, last, "unlock notification dropped — back at the desk, app not told")
                for _ in 0..<60 {
                    clock.advance(1)
                    sched.overlayShowing = (box.kind != nil)
                    sched.step()
                    if !journal.lines.isEmpty { flush(clock, last, journal, note: nil) }
                }
                flush(clock, last, journal, note: "1:00 later, away = \(last?.away ?? false)")

            case .resolve(let reason):
                guard box.kind != nil else { note(clock, last, "\(reason.logName): nothing on screen"); break }
                resolve(sched, box, reason, journal)
                flush(clock, last, journal, note: nil)
            }
        }
        return 0
    }

    private static func resolve(_ sched: Scheduler, _ box: Pending,
                                _ reason: BreakEndReason, _ journal: Journal) {
        guard let kind = box.kind else { return }
        box.kind = nil
        sched.overlayShowing = false
        journal.add("\(label(reason)) (\(kind.label))")
        sched.breakFinished(kind, reason)
    }

    private static func label(_ r: BreakEndReason) -> String {
        switch r {
        case .completed:   return "took it"
        case .snoozed:     return "+5 min"
        case .skipped:     return "skipped"
        case .interrupted: return "interrupted"
        }
    }

    // MARK: script

    private enum Op {
        case setEye(Int), setMove(Int), eyeOff, moveOff, nudges
        case work(Int), call(Int), lock(Int), pause(Int)
        case lostUnlock(Int)     // locked, then the unlock notification never arrives
        case resolve(BreakEndReason)

        var isCall: Bool { if case .call = self { return true }; return false }
        var isLock: Bool { if case .lock = self { return true }; return false }
        var name: String {
            switch self {
            case .work: return "work"
            case .call: return "call"
            case .lock: return "lock"
            default:    return "op"
            }
        }
    }

    /// The default scenario is the reported bug, written down: a break that gets
    /// put off four times in a row. The counter must keep climbing and the strain
    /// must keep rising through all four.
    static let defaultScript = "eye 5m, moveoff, work 5m, snooze, work 5m, snooze, work 5m, snooze, work 5m, done, work 5m"

    /// Parse the whole script or reject it. Returns nil if any word is unknown or
    /// any op is missing its duration.
    private static func parse(_ script: String) -> [Op]? {
        let words = script
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ").map { String($0).lowercased() }
        var ops: [Op] = []
        var bad: [String] = []
        var i = 0
        func arg(_ op: String) -> Int? {
            guard i + 1 < words.count, let s = duration(words[i + 1]) else {
                bad.append("\(op) needs a duration (20m, 30s, 1h)")
                return nil
            }
            i += 1
            return s
        }
        while i < words.count {
            switch words[i] {
            case "eye":        if let s = arg("eye") { ops.append(.setEye(s)) }
            case "move":       if let s = arg("move") { ops.append(.setMove(s)) }
            case "eyeoff":     ops.append(.eyeOff)
            case "moveoff":    ops.append(.moveOff)
            case "nudges":     ops.append(.nudges)
            case "work":       if let s = arg("work") { ops.append(.work(s)) }
            case "call":       if let s = arg("call") { ops.append(.call(s)) }
            case "lock":       if let s = arg("lock") { ops.append(.lock(s)) }
            case "lostunlock": if let s = arg("lostunlock") { ops.append(.lostUnlock(s)) }
            case "pause":      if let s = arg("pause") { ops.append(.pause(s)) }
            case "snooze", "+5", "extend": ops.append(.resolve(.snoozed))
            case "skip":                   ops.append(.resolve(.skipped))
            case "done", "take", "took":   ops.append(.resolve(.completed))
            case "interrupt":              ops.append(.resolve(.interrupted))
            default: bad.append("unknown op '\(words[i])'")
            }
            i += 1
        }
        guard bad.isEmpty else {
            var msg = "sim: bad script\n"
            for b in bad { msg += "  · \(b)\n" }
            msg += "  ops: eye|move <dur>, eyeoff, moveoff, nudges, work|call|lock|pause <dur>,\n"
            msg += "       lostunlock <dur>, snooze, skip, done, interrupt\n"
            FileHandle.standardError.write(Data(msg.utf8))
            return nil
        }
        return ops
    }

    private static func duration(_ w: String) -> Int? {
        if w.hasSuffix("m"), let n = Int(w.dropLast()) { return n * 60 }
        if w.hasSuffix("s"), let n = Int(w.dropLast()) { return n }
        if w.hasSuffix("h"), let n = Int(w.dropLast()) { return n * 3600 }
        return Int(w).map { $0 * 60 }
    }

    // MARK: output

    private static var t0: Double?

    private static func header() {
        print("")
        print("   time   worked / due   strain  [ rested ---- due ---- overdue ]   off   what happened")
        print(String(repeating: "-", count: 100))
    }

    private static func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
        let gap = String(repeating: " ", count: max(0, width - s.count))
        return right ? gap + s : s + gap
    }

    private static func note(_ c: Fake, _ s: Scheduler.Status?, _ text: String) {
        let j = Journal()
        j.add(text)
        flush(c, s, j, note: nil)
    }

    private static func flush(_ c: Fake, _ s: Scheduler.Status?, _ journal: Journal, note: String?) {
        let all = journal.take() + (note.map { [$0] } ?? [])
        guard !all.isEmpty, let s else { return }
        if t0 == nil { t0 = c.work }
        let t = Int(c.work - (t0 ?? c.work))
        let interval = Settings.eyeIntervalSec
        let elapsed = interval - min(interval, s.eye.remaining) + s.eye.overdue
        let strain = String(format: "%.2f", s.eye.strain)
        print(pad(mmss(t), 7, right: true)
              + "  " + pad(mmss(elapsed), 6, right: true) + " / " + pad(mmss(interval), 6)
              + pad(strain, 7, right: true)
              + "  " + bar(s.eye.strain)
              + pad(String(s.eye.refusals), 5, right: true)
              + "   " + all.joined(separator: " · "))
    }

    /// A 20-cell gauge over strain 0…2. The first ten cells fill up to the break
    /// being due; the last ten are the overdue half, so extending shows as the bar
    /// pushing past the marker instead of snapping back to empty.
    private static func bar(_ strain: Double) -> String {
        let cells = 20
        let filled = max(0, min(cells, Int((min(2, strain) / 2 * Double(cells)).rounded())))
        var out = ""
        for i in 0..<cells {
            if i == 10 { out += "|" }
            out += i < filled ? (i < 10 ? "#" : "!") : "."
        }
        return "[" + out + "]"
    }

    private static func mmss(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}
