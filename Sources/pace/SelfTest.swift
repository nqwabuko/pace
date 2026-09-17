import AppKit

/// `pace --selftest`: the mechanical checks, the ones that don't need a human to
/// look at a picture or read a trace. `--sim` shows you the loop and you judge it;
/// this asserts the handful of claims the design would quietly break if a constant
/// were nudged. Exits non-zero on the first failure, so it's usable as a gate.
enum SelfTest {

    static var dumpCurve = false

    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ detail: String = "", _ ok: Bool) {
            print("  \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "   \(detail)")")
            if !ok { failures += 1 }
        }

        print("\nglyph — the icon must never look calmer the more rest you owe")
        if dumpCurve {
            for m in stride(from: 0.0, through: 2.0, by: 0.25).map({ IconMaker.measure(strain: CGFloat($0)) }) {
                print(String(format: "    strain %.2f  ink %6.1f  silhouette %6.1f  solidity %.3f",
                             m.strain, m.ink, m.silhouette, m.solidity))
            }
        }
        let steps = stride(from: 0.0, through: 2.0, by: 0.1).map { CGFloat($0) }
        let ms = steps.map { IconMaker.measure(strain: $0) }
        let rested = ms[0]

        // The strong form of the claim, and the one an earlier version of the
        // geometry failed: total ink only ever goes up. Squinting the eye shut when
        // overdue shrank it by a quarter, so the icon got quieter the more rest you
        // owed. Overdue swells now, and this is what holds that in place.
        let lighter = zip(ms, ms.dropFirst())
            .filter { $1.ink <= $0.ink }
            .map { String(format: "%.1f→%.1f (%.0f→%.0f)", $0.strain, $1.strain, $0.ink, $1.ink) }
        check("ink only ever increases", lighter.joined(separator: ", "), lighter.isEmpty)

        let dips = zip(ms, ms.dropFirst())
            .filter { $1.solidity < $0.solidity - 0.005 }
            .map { String(format: "%.1f→%.1f (%.2f→%.2f)", $0.strain, $1.strain, $0.solidity, $1.solidity) }
        check("solidity never falls", dips.joined(separator: ", "), dips.isEmpty)

        // The design's language: hollow when rested, white still showing when the
        // break is merely due, solid only once you've let it go overdue.
        let atDue = ms.first { $0.strain >= 1.0 }?.solidity ?? 1
        let flooded = ms.first { $0.strain >= 1.5 }?.solidity ?? 0
        check("hollow when rested", String(format: "%.2f", rested.solidity), rested.solidity < 0.65)
        check("white still showing when due", String(format: "%.2f", atDue), atDue < 0.90)
        check("solid once overdue (by 1.5)", String(format: "%.2f", flooded), flooded > 0.98)

        // Damage: cracks for eye rests missed, a foot for a movement break missed.
        // Both are knockouts, so unlike strain they take ink *away* — the monotonic
        // checks above deliberately sweep the clean glyph only. What has to hold
        // here is weaker but is the thing that actually breaks: a mark that renders
        // as nothing. It happened once already — added splinters at the lens corners
        // fell off the 18pt canvas the moment the overdue eye swelled, so the most
        // damaged glyph drew identically to the clean one. Nothing caught it but a
        // rendered strip and a pair of eyes; this is what catches it next time.
        let marks: [(String, Int, Bool, Bool)] = [
            ("1 crack", 1, false, false), ("2 cracks", 2, false, false), ("3 cracks", 3, false, false),
            ("foot", 0, true, false), ("both", 3, true, false),
            ("on a call", 0, false, true), ("on a call, both", 3, true, true),
        ]
        // In glyph-space units of area, and an absolute floor rather than a share
        // of a glyph whose total ink trebles between rested and flooded.
        //
        // Be clear about what this does and doesn't prove. The faintest mark drawn
        // measures 1.8 units — one crack on a rested eye, where it only has the
        // 1.5pt rim to cut through — and that one is plainly visible, because a gap
        // in a thin ring reads far louder than its area. So area under-measures the
        // marks and the floor has to sit below the faintest real one. This catches a
        // mark that renders as *nothing*, which is the failure that actually
        // happened. It does not measure legibility: only the rendered strip at true
        // bar size does that, and only a person can read it.
        let minMark = 1.5
        var faint: [String] = []
        for st in [CGFloat(0), 0.5, 1.0, 1.5, 2.0] {
            let clean = IconMaker.measure(strain: st).ink
            for (name, cracks, foot, onCall) in marks {
                let marked = IconMaker.measure(strain: st, cracks: cracks, foot: foot, onCall: onCall).ink
                let delta = abs(marked - clean)
                if delta < minMark { faint.append(String(format: "%@ @%.1f (%.1f)", name, st, delta)) }
            }
        }
        check("every mark shows on the glyph it marks", faint.joined(separator: ", "), faint.isEmpty)

        // And each extra crack has to be its own step, or the count is decoration.
        let counted = [CGFloat(0), 1.0, 1.5].allSatisfy { st in
            let inks = (0...IconMaker.maxCracks).map { IconMaker.measure(strain: st, cracks: $0).ink }
            return zip(inks, inks.dropFirst()).allSatisfy { $0 - $1 > 0.5 }
        }
        check("each further crack cuts more away", "1…\(IconMaker.maxCracks)", counted)

        print("\nloop — extending a break must never credit a rest")
        let loop = extendFourTimes()
        check("counter keeps climbing through 4 extensions",
              loop.strains.map { String(format: "%.2f", $0) }.joined(separator: " → "),
              zip(loop.strains, loop.strains.dropFirst()).allSatisfy { $1 > $0 })
        check("four extensions are all counted", "refusals=\(loop.refusals)", loop.refusals == 4)
        check("taking it finally rests you", String(format: "%.2f", loop.afterTaking), loop.afterTaking == 0)

        print("\ncard — the chain on the break card must be the loop's own trail, in order")
        check("the card is handed what actually happened, in order",
              loop.trail.map(\.rawValue).joined(separator: " → "),
              loop.trail == [.snoozed, .snoozed, .snoozed, .snoozed])
        let story = trailStory()
        check("an extension, an extension, a skip stay in that order",
              story.handed.map(\.rawValue).joined(separator: " → "),
              story.handed == [.snoozed, .snoozed, .skipped])
        check("taking the break clears the story", "\(story.afterTaking.count) marks left", story.afterTaking.isEmpty)
        // The one distinction the chain exists to keep: a call getting in the way is
        // on the trail (it is why the break is late) but is not something you did,
        // so it must never read as a refusal in the counts or in the copy.
        check("a call holding a break back is on the trail but is not a refusal",
              "trail=\(story.callTrail.map(\.rawValue).joined(separator: ",")) refusals=\(story.callRefusals)",
              story.callTrail == [.held] && story.callRefusals == 0)
        check("the line under the chain says what happened, not just how often",
              story.line, story.line ==
                "You've put this one off twice and skipped it once since your last rest.")
        check("a call-held break is not blamed on you", story.callLine,
              story.callLine == "A call held it back once.")
        check("a break that turns up on time gets no chain and no line", story.cleanLine ?? "(nothing)",
              story.cleanLine == nil)

        print("\nthe card machine — every state must take every event, and only one path may end a break")
        let start = Date(timeIntervalSince1970: 1_755_000_000)
        let session = Card.Session(kind: .eye, trail: [.snoozed], overdueSec: 300, durationSec: 20,
                                   startedAt: start, prompt: Tips.random(for: .eye))
        let states: [Card.State] = [.idle, .up(session, remaining: 20), .up(session, remaining: 1)]
        let events: [Card.Event] = [
            .show(session), .key(.skip), .key(.snooze), .key(.done), .clickedOff,
            .tick(start.addingTimeInterval(1)), .tick(start.addingTimeInterval(19.6)),
            .tick(start.addingTimeInterval(20)), .tick(start.addingTimeInterval(9_999)), .callStarted]

        // Totality. Not "it compiles": every pair is actually driven, and the one
        // thing no pair may ever do is report a break finished more than once — that
        // is what would credit a rest twice or log the same break as taken and
        // skipped. The old code held this with `guard isShowing` in two methods.
        var endings = 0
        var badIdle: [String] = []
        for st in states {
            for ev in events {
                let (after, fx) = Card.next(st, ev)
                endings = max(endings, fx.filter { if case .ended = $0 { return true }; return false }.count)
                if case .idle = st, case .show = ev {} else if case .idle = st, !fx.isEmpty || after != .idle {
                    badIdle.append("\(ev)")
                }
            }
        }
        check("no event ends a break twice", "\(endings) ended per step", endings == 1)
        check("with no card up, everything but showing one is a non-event",
              badIdle.joined(separator: ", "), badIdle.isEmpty)

        func ending(_ ev: Card.Event) -> BreakEndReason? {
            let (after, fx) = Card.next(.up(session, remaining: 20), ev)
            guard after == .idle else { return nil }
            for f in fx { if case .ended(_, let reason) = f { return reason } }
            return nil
        }
        check("Skip and a click off the card are the same refusal", "",
              ending(.key(.skip)) == .skipped && ending(.clickedOff) == .skipped)
        check("+5 is snoozed, already-rested is completed, a call is interrupted", "",
              ending(.key(.snooze)) == .snoozed && ending(.key(.done)) == .completed
              && ending(.callStarted) == .interrupted)
        check("only a natural finish asks for the chime", "",
              Card.next(.up(session, remaining: 1), .tick(start.addingTimeInterval(20))).1.contains(.endChime)
              && !Card.next(.up(session, remaining: 20), .key(.skip)).1.contains(.endChime))

        // The guarantee the second timer exists for, stated as a property rather
        // than as a timer: any tick at or past the end closes the card, whichever
        // clock sent it and whatever the card last painted.
        let outlives = states.compactMap { st -> String? in
            guard case .up = st else { return nil }
            let (after, _) = Card.next(st, .tick(start.addingTimeInterval(25)))
            return after == .idle ? nil : "\(st)"
        }
        check("a card can never outlive its own countdown", outlives.joined(separator: ", "), outlives.isEmpty)
        check("a tick that doesn't change the clock repaints nothing", "",
              Card.next(.up(session, remaining: 19), .tick(start.addingTimeInterval(1))).1.isEmpty)

        // A backstop that asks the clock is only a backstop while the clock runs
        // forwards. This is the one event that ends a card because it was asked
        // to, and the check is that it does so from any state and any reading.
        check("the backstop ends the card whatever the clock says", "",
              states.allSatisfy { st in
                  guard case .up = st else { return true }
                  return Card.next(st, .timeUp).0 == .idle
              })

        print("\nthe card's copy — what is drawn is a function of the trail, and nothing else")
        func card(_ trail: [Loop.Mark], overdue: Int) -> Card.Model {
            Card.model(Card.Session(kind: .eye, trail: trail, overdueSec: overdue, durationSec: 20,
                                    startedAt: start, prompt: Tips.random(for: .eye)), remaining: 20)
        }
        let long: [Loop.Mark] = [.snoozed, .snoozed, .held, .skipped, .snoozed, .interrupted, .held]
        // The card shows the difference, not the chart: where you were, the one
        // thing that has happened since, and now. However long the run gets, the
        // arrow carries one step, and it is the most recent one.
        check("the step is the last thing that happened, however long the run",
              "\(long.count) marks → \(card(long, overdue: 0).step.map(\.rawValue) ?? "none")",
              card(long, overdue: 0).step == .held
              && card([.snoozed, .skipped], overdue: 0).step == .skipped)
        check("how late it is belongs to the chain, not the sentence",
              card(long, overdue: 22 * 60).late ?? "(nothing)",
              card(long, overdue: 22 * 60).late == "22m late" && card(long, overdue: 30).late == nil)
        check("a break with no story draws nothing at all", "",
              !card([], overdue: 0).story && card([], overdue: 300).story && card([.snoozed], overdue: 0).story)

        print("\ndebt — extensions and the time they cost must both survive the log")
        let legacy = decodeLegacyLine()
        check("a line written before overdue/refusals/call time existed still decodes",
              legacy.map { "\($0.outcome) overdue=\(String(describing: $0.overdueSec)) call=\(String(describing: $0.callSec))" } ?? "dropped",
              legacy != nil && legacy?.overdueSec == nil && legacy?.refusals == nil && legacy?.callSec == nil)

        let d = debtSummary()
        // 10 overdue minutes on the break that was finally taken, 15 on the debt the
        // lunch break cleared. Not the 5 the second extension was carrying: that
        // same stretch of time is inside the 10, and counting both would bill it twice.
        check("past due counts the event that cleared the debt, once", "\(d.overdueToday)s", d.overdueToday == 1500)
        check("both extensions and the skip count as put off", "\(d.putOffsToday)×", d.putOffsToday == 3)
        check("first-time split ignores rows with no refusals recorded",
              "first=\(d.split.first) once=\(d.split.once) more=\(d.split.more)",
              d.split.first == 1 && d.split.once == 0 && d.split.more == 1 && d.split.firstPct == 50)
        check("a legacy day still shows its breaks, with no debt claimed",
              "eye=\(d.days.first?.eye ?? -1) overdue=\(d.days.first?.overdueSec ?? -1)",
              d.days.first?.eye == 2 && d.days.first?.overdueSec == 0)

        let away = awayRestAfterWorkingPastDue()
        check("a long spell away records the debt you walked away with, not the time away",
              "eye overdue=\(away.overdue)s put off \(away.refusals)× away=\(away.awaySec)s",
              away.overdue == 4 * 60 && away.refusals == 1 && away.awaySec == 20 * 60)

        print("\nnights — one absence is one rest, however often the machine wakes itself")
        let dark = nightOfDarkWakes()
        check("a night of dark wakes credits one rest, not one per wake",
              "\(dark.rests) rests logged", dark.rests == 1)
        check("and the one it credits is the whole night", "\(dark.longest)s", dark.longest >= 10 * 3600)
        check("nothing accrues as screen work while nobody is there",
              "elapsed=\(dark.elapsedAtDawn)s", dark.elapsedAtDawn == 0)

        print("\ncalls — a call that stops you moving must show up as time, not nothing")
        let held = callHeldThroughAnHourOnACall()
        // The whole point of counting this above the holding return. In holding mode
        // `elapsed` is frozen for the hour, so every debt reading says the call cost
        // nothing; the call clock is the only thing that can say otherwise.
        check("an hour on a call is an hour held off both breaks",
              "eye=\(held.eye)s move=\(held.move)s", held.eye == 3600 && held.move == 3600)
        check("and the frozen debt still reports nothing, which is why this exists",
              "elapsed=\(held.eyeElapsed)s", held.eyeElapsed == 600)
        check("taking the break clears what calls were holding", "\(held.afterTaking)s", held.afterTaking == 0)

        let openNow = openCallStretch()
        // The afternoon that reads as zero: on calls for an hour, no break closed yet,
        // so the log knows nothing. The panel has to show it anyway.
        check("call time still standing against a break shows today, before any break closes",
              "today=\(openNow.today)s week=\(openNow.week)s", openNow.today == 3600 && openNow.week == 3600)
        check("and it adds to what the day already closed, never replacing it",
              "\(openNow.withClosed)s", openNow.withClosed == 3600 + 600)

        let callSum = callHeldSummary()
        // 40 minutes on the row that was finally taken. Not the 25 the extension was
        // carrying as well: same stretch of call time, billed once.
        check("call time counts the event that cleared the debt, once",
              "eye=\(callSum.eye)s", callSum.eye == 40 * 60)
        check("eye and move are reported apart, never summed",
              "eye=\(callSum.eye)s move=\(callSum.move)s", callSum.move == 50 * 60)
        check("a row written before call time existed claims none",
              "\(callSum.legacy)s", callSum.legacy == 0)

        print("\nabsence — a screen that never locks is not a human who never left")
        let night = overnightUntouched()
        check("no break fires while nobody is at the machine", "\(night.firesWhileAway) fired", night.firesWhileAway == 0)
        check("coming back credits the hour away as a rest", "away=\(night.awaySec)s", night.awaySec == 60 * 60)
        // Within a tick or two of eighteen minutes left, i.e. the reading from when
        // he was last at the desk. Read at the point of return it would be 0, with
        // the whole hour billed as strain. The tolerance is there because the door
        // is sampled once a second, not because the distinction is fuzzy.
        check("the rest records the debt at the door, not the hour away",
              "remaining=\(night.remainingAtDoor)s of 1080s", abs(night.remainingAtDoor - 18 * 60) <= 2)
        check("and you get the full interval back", "quiet=\(night.quietAfterReturn)s then fired=\(night.firedAfterReturn)",
              night.quietAfterReturn == 19 * 60 && night.firedAfterReturn)

        // Turning off "reset after a long break away" must give back exactly one
        // thing: the reset. Not the room-emptying overlay that started all this.
        let optedOut = overnightUntouched(resetOnReturn: false)
        check("with the reset switched off, still nothing fires at an empty room",
              "\(optedOut.firesWhileAway) fired", optedOut.firesWhileAway == 0)
        check("...and the hour away credits nothing, which is what the switch is for",
              optedOut.awaySec == -1 ? "no rest credited" : "credited \(optedOut.awaySec)s",
              optedOut.awaySec == -1)
        check("...so the break you were owed is waiting the moment you're back",
              "fired after \(optedOut.quietAfterReturn == -1 ? 0 : optedOut.quietAfterReturn)s",
              optedOut.quietAfterReturn == -1 && optedOut.firedAfterReturn)

        let slept = machineSlept()
        check("a sleep the run loop never saw counts as a rest too",
              "away=\(slept.awaySec)s remaining=\(slept.remaining)s of 1080s",
              slept.awaySec >= 60 * 60 && abs(slept.remaining - 18 * 60) <= 2)

        print("\nkeyboard — every button on the card must have a key, and no key may act alone")
        func key(_ chars: String?, _ flags: NSEvent.ModifierFlags = .command, code: UInt16 = 0) -> BreakKey? {
            BreakKey.action(keyCode: code, chars: chars, flags: flags)
        }
        check("⌘S skips", "", key("s") == .skip)
        check("⌘5 buys five more minutes", "", key("5") == .snooze)
        check("⌘D says you already did it", "", key("d") == .done)
        check("Esc still skips, with or without ⌘", "",
              key(nil, [], code: BreakKey.escKeyCode) == .skip
              && key(nil, .command, code: BreakKey.escKeyCode) == .skip)
        check("Return still credits it, from either Enter key", "",
              BreakKey.returnKeyCodes.allSatisfy { key(nil, [], code: $0) == .done })
        // Typing into whatever is behind a full-screen card is not something a
        // break should be able to catch, and a combo the user has bound elsewhere
        // is not ours to take.
        check("a bare letter is not a shortcut", "", key("s", []) == nil && key("d", []) == nil)
        check("⌘ plus another modifier is left alone", "",
              key("s", [.command, .option]) == nil && key("d", [.command, .shift]) == nil)
        check("caps lock doesn't break it", "", key("S", [.command, .capsLock]) == .skip)
        check("⌘Q and friends pass through", "", key("q") == nil && key("w") == nil)

        print("\nvault health — a broken vault must read as broken, then heal")
        var h = Report.VaultHealth()
        let t = Date(timeIntervalSince1970: 1_755_000_000)
        for _ in 0..<3 { h = h.folding("nope", at: t) }
        check("three failures count as three", "\(h.consecutiveFailures)", h.consecutiveFailures == 3 && h.isFailing)
        h = h.folding(nil, at: t)
        check("a success clears it", "", !h.isFailing && h.lastError == nil && h.lastSuccess == t)

        print(failures == 0 ? "\nall checks passed\n" : "\n\(failures) check(s) failed\n")
        return failures == 0 ? 0 : 1
    }

    /// A row from before `overdueSec`/`refusals` existed. `Report.events()` drops
    /// what it can't decode, so if these two ever stop being optional the whole
    /// back history disappears from the dashboard without a word.
    private static func decodeLegacyLine() -> BreakEvent? {
        let line = #"{"at":"2026-08-01T09:00:00Z","kind":"eye","outcome":"completed","seconds":30}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(BreakEvent.self, from: Data(line.utf8))
    }

    /// A day's worth of made-up events through the real aggregation: two extensions
    /// then taking it, one clean take, one skip, and a lunch break that cleared a
    /// standing debt — plus a fortnight-old day with no debt fields at all.
    private static func debtSummary() -> StatsSummary {
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        let today = Calendar.current.startOfDay(for: now).addingTimeInterval(9 * 3600)
        let old = Calendar.current.date(byAdding: .day, value: -13, to: today)!
        var evs: [BreakEvent] = [
            BreakEvent(at: today, kind: "eye", outcome: "snoozed", seconds: 0, overdueSec: 0, refusals: 0),
            BreakEvent(at: today + 300, kind: "eye", outcome: "snoozed", seconds: 0, overdueSec: 300, refusals: 1),
            BreakEvent(at: today + 600, kind: "eye", outcome: "completed", seconds: 30, overdueSec: 600, refusals: 2),
            BreakEvent(at: today + 1800, kind: "eye", outcome: "completed", seconds: 30, overdueSec: 0, refusals: 0),
            BreakEvent(at: today + 2400, kind: "eye", outcome: "skipped", seconds: 0, overdueSec: 0, refusals: 0),
            BreakEvent(at: today + 3600, kind: "eye", outcome: "rested", seconds: 2700, overdueSec: 900, refusals: 1),
            BreakEvent(at: today + 3600, kind: "move", outcome: "rested", seconds: 2700, overdueSec: 300, refusals: 0),
        ]
        // Two takes from before the fields existed: they must still count as breaks.
        evs += [BreakEvent(at: old, kind: "eye", outcome: "completed", seconds: 30),
                BreakEvent(at: old + 1200, kind: "eye", outcome: "completed", seconds: 30)]
        return Report.summary(from: evs, now: now)
    }

    /// The whole path in one go: a break comes up, you extend it, you work four
    /// minutes past due, then you go to lunch for twenty. What the away rest should
    /// record is the four minutes you walked away owing, plus the one extension —
    /// not the twenty minutes at lunch, which are the opposite of eye strain. The
    /// counters deliberately keep climbing while the screen is locked, so this is
    /// the difference between reading the debt at the door and reading it on the
    /// way back in.
    private static func awayRestAfterWorkingPastDue() -> (overdue: Int, refusals: Int, awaySec: Int) {
        var result = (overdue: -1, refusals: -1, awaySec: -1)
        withScratchSettings {
            Settings.set(.moveEnabled, false)
            Settings.set(.eyeIntervalMin, 5)
            Settings.set(.awayResetMin, 15)

            var work = 20_000.0
            var wall = Date(timeIntervalSince1970: 1_755_000_000)
            var locked = false
            let sched = Scheduler()
            sched.env = Env(work: { work }, wall: { wall }, inCall: { false }, idleSec: { locked ? 600 : 0 })
            sched.onAwayRest = { credits, awaySec in
                let eye = credits.first { $0.kind == .eye }
                result = (eye?.overdue ?? -1, eye?.refusals ?? -1, awaySec)
            }
            var due = false
            sched.onBreakDue = { _, _ in due = true; sched.overlayShowing = true }
            sched.start()

            func run(_ seconds: Int) {
                for _ in 0..<seconds { work += 1; wall += 1; sched.step() }
            }

            run(5 * 60)                              // the eye break comes due
            sched.overlayShowing = false
            if due { sched.breakFinished(.eye, .snoozed) }   // "+5 min"
            run(4 * 60)                              // four minutes of screen work past due

            locked = true
            sched.setScreenLocked(true)
            run(20 * 60)                             // lunch
            locked = false
            sched.setScreenLocked(false)
        }
        return result
    }

    /// The overnight failure, reproduced: a Mac left awake and unlocked, nobody
    /// touching it for an hour. Before this, the loop counted every second of that
    /// as screen work, fired a break every twenty minutes and auto-completed each
    /// one, so the morning opened mid-cycle with a break already due and thirty
    /// rests on record that never happened.
    private static func overnightUntouched(resetOnReturn: Bool = true)
        -> (firesWhileAway: Int, awaySec: Int, remainingAtDoor: Int, quietAfterReturn: Int, firedAfterReturn: Bool) {
        var out = (firesWhileAway: -1, awaySec: -1, remainingAtDoor: -1, quietAfterReturn: -1, firedAfterReturn: false)
        withScratchSettings {
            Settings.set(.moveEnabled, false)
            Settings.set(.eyeIntervalMin, 20)
            Settings.set(.awayResetMin, 15)
            Settings.set(.idleAware, resetOnReturn)

            let rig = Rig()
            var fires = 0
            rig.sched.onBreakDue = { _, _ in fires += 1 }
            rig.sched.onAwayRest = { credits, secs in
                out.awaySec = secs
                out.remainingAtDoor = credits.first { $0.kind == .eye }?.remaining ?? -1
            }
            rig.sched.start()

            rig.run(2 * 60)                       // two minutes at the desk
            let before = fires
            rig.run(60 * 60, untouched: true)     // an hour with nobody there
            out.firesWhileAway = fires - before

            rig.run(1)                            // a keypress: back at the desk
            let afterReturn = fires
            rig.run(19 * 60)                      // the interval you're owed, quiet
            out.quietAfterReturn = 19 * 60
            if fires > afterReturn { out.quietAfterReturn = -1 }
            rig.run(90)
            out.firedAfterReturn = fires > afterReturn
        }
        return out
    }

    /// The other half of the same hole: the machine actually slept, so no tick ran
    /// and no notification arrived. The two clocks diverge by exactly the time
    /// asleep, which is what gives it away.
    private static func machineSlept() -> (awaySec: Int, remaining: Int) {
        var out = (awaySec: -1, remaining: -1)
        withScratchSettings {
            Settings.set(.moveEnabled, false)
            Settings.set(.eyeIntervalMin, 20)
            Settings.set(.awayResetMin, 15)

            let rig = Rig()
            rig.sched.onAwayRest = { credits, secs in
                out = (secs, credits.first { $0.kind == .eye }?.remaining ?? -1)
            }
            rig.sched.start()
            rig.run(2 * 60)
            rig.wall += 60 * 60      // an hour of wall time with the work clock frozen
            rig.sched.step()
        }
        return out
    }

    /// A scheduler on injected clocks, driven a second at a time. `untouched` grows
    /// the idle clock instead of resetting it, which is the difference between
    /// sitting there working and having gone home.
    private final class Rig {
        let sched = Scheduler()
        var work = 30_000.0
        var wall = Date(timeIntervalSince1970: 1_755_000_000)
        var idle = 0.0
        var onCall = false

        init() {
            sched.env = Env(work: { [unowned self] in self.work },
                            wall: { [unowned self] in self.wall },
                            inCall: { [unowned self] in self.onCall },
                            idleSec: { [unowned self] in self.idle })
        }

        /// The machine asleep. Wall time passes, the monotonic work clock does not,
        /// and no tick runs — which is what a night of sleep and dark wakes actually
        /// looks like from inside the loop.
        func asleep(_ seconds: Int) {
            wall += TimeInterval(seconds)
            idle += Double(seconds)
        }

        func run(_ seconds: Int, untouched: Bool = false) {
            for _ in 0..<seconds {
                work += 1
                wall += 1
                idle = untouched ? idle + 1 : 0
                sched.step()
            }
        }
    }

    /// An hour of calls standing against the move break with nothing logged yet, then
    /// the same with a closed break already on the day.
    private static func openCallStretch() -> (today: Int, week: Int, withClosed: Int) {
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        let closed = [BreakEvent(at: Calendar.current.startOfDay(for: now).addingTimeInterval(9 * 3600),
                                 kind: "move", outcome: "completed", seconds: 120, callSec: 600)]
        let bare = Report.summary(from: [], now: now, openCall: (eye: 0, move: 3600))
        let both = Report.summary(from: closed, now: now, openCall: (eye: 0, move: 3600))
        return (bare.callMoveToday, bare.callMoveWeek, both.callMoveToday)
    }

    /// The overnight log flood, reproduced: half an hour at the desk, then a night
    /// of the machine sleeping in fifteen-minute chunks and waking itself for forty
    /// seconds at a time. macOS dark-wake cadence, and nobody there for any of it.
    /// Every one of those wakes used to be read as "you came back, rested", so a
    /// single night wrote forty pairs of rest events.
    private static func nightOfDarkWakes() -> (rests: Int, longest: Int, elapsedAtDawn: Int) {
        var out = (rests: 0, longest: 0, elapsedAtDawn: -1)
        withScratchSettings {
            Settings.set(.eyeIntervalMin, 20)
            Settings.set(.moveEnabled, false)
            Settings.set(.awayResetMin, 15)

            let rig = Rig()
            var last: Scheduler.Status?
            rig.sched.onTick = { last = $0 }
            rig.sched.onBreakDue = { _, _ in rig.sched.overlayShowing = true }
            rig.sched.onAwayRest = { _, secs in
                out.rests += 1
                out.longest = max(out.longest, secs)
            }
            rig.sched.start()

            rig.run(30 * 60)                        // half an hour at the desk
            rig.sched.overlayShowing = false
            rig.sched.breakFinished(.eye, .completed)

            for _ in 0..<40 {                       // ten hours of sleep and dark wakes
                rig.asleep(15 * 60)
                rig.run(40, untouched: true)
            }
            out.elapsedAtDawn = Int(Double(Settings.eyeIntervalSec) - Double(last?.eye.remaining ?? 0))

            rig.run(2)                              // morning: a keypress
        }
        return out
    }

    /// An hour on a call in the default holding mode, from ten minutes of desk work.
    /// Holding freezes the counters, so this is the case where every existing number
    /// says the call was free.
    private static func callHeldThroughAnHourOnACall()
        -> (eye: Int, move: Int, eyeElapsed: Int, afterTaking: Int) {
        var out = (eye: -1, move: -1, eyeElapsed: -1, afterTaking: -1)
        withScratchSettings {
            Settings.set(.eyeIntervalMin, 20)
            Settings.set(.moveIntervalMin, 30)
            Settings.set(.callBreaks, false)      // hold, don't nudge: the harder case

            let rig = Rig()
            var last: Scheduler.Status?
            rig.sched.onTick = { last = $0 }
            rig.sched.onBreakDue = { _, _ in rig.sched.overlayShowing = true }
            rig.sched.start()

            rig.run(10 * 60)                      // ten minutes at the desk
            rig.onCall = true
            rig.run(60 * 60)                      // an hour on a call
            rig.onCall = false

            out.eye = last?.eye.callHeldSec ?? -1
            out.move = last?.move.callHeldSec ?? -1
            // 20-minute eye interval, 10 minutes worked, so 10 min of debt, frozen
            // there for the whole call rather than the 70 minutes wall time.
            out.eyeElapsed = Int(Double(Settings.eyeIntervalSec) - Double(last?.eye.remaining ?? 0))

            rig.sched.overlayShowing = false
            rig.sched.breakFinished(.eye, .completed)
            rig.run(1)
            out.afterTaking = last?.eye.callHeldSec ?? -1
        }
        return out
    }

    /// The aggregation, against made-up rows: an eye break nudged twice through a
    /// call then taken, a move break taken, and a legacy row with no call field.
    private static func callHeldSummary() -> (eye: Int, move: Int, legacy: Int) {
        let t = Date(timeIntervalSince1970: 1_755_000_000)
        let evs: [BreakEvent] = [
            BreakEvent(at: t, kind: "eye", outcome: "nudged", seconds: 0, callSec: 10 * 60),
            BreakEvent(at: t + 900, kind: "eye", outcome: "nudged", seconds: 0, callSec: 25 * 60),
            BreakEvent(at: t + 2400, kind: "eye", outcome: "completed", seconds: 30, callSec: 40 * 60),
            BreakEvent(at: t + 2500, kind: "move", outcome: "completed", seconds: 120, callSec: 50 * 60),
        ]
        let legacy = [BreakEvent(at: t, kind: "eye", outcome: "completed", seconds: 30)]
        return (Report.callHeld(evs, kind: "eye"),
                Report.callHeld(evs, kind: "move"),
                Report.callHeld(legacy, kind: "eye"))
    }

    /// Run `body` against a throwaway settings domain, so a check can set an
    /// interval without touching the real one.
    private static func withScratchSettings(_ body: () -> Void) {
        let suite = "global.ampeco.pace.selftest"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let saved = Settings.store
        Settings.store = UserDefaults(suiteName: suite) ?? .standard
        Settings.registerDefaults()
        defer {
            Settings.store = saved
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        body()
    }

    /// Drive the real scheduler through the reported bug: a break put off four
    /// times, then taken. Built inline rather than through `--sim`'s parser so this
    /// check can't be broken by the parser.
    private static func extendFourTimes() -> (strains: [Double], refusals: Int, trail: [Loop.Mark], afterTaking: Double) {
        let suite = "global.ampeco.pace.selftest"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let store = UserDefaults(suiteName: suite) ?? .standard
        let saved = Settings.store
        Settings.store = store
        Settings.registerDefaults()
        Settings.set(.moveEnabled, false)
        Settings.set(.eyeIntervalMin, 5)
        defer {
            Settings.store = saved
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        var work = 10_000.0
        var wall = Date(timeIntervalSince1970: 1_755_000_000)
        let sched = Scheduler()
        sched.env = Env(work: { work }, wall: { wall }, inCall: { false }, idleSec: { 0 })

        var due: BreakKind?
        var last: Scheduler.Status?
        var handed: [Loop.Mark] = []
        sched.onTick = { last = $0 }
        sched.onBreakDue = { kind, trail in due = kind; handed = trail; sched.overlayShowing = true }
        sched.start()

        var strains: [Double] = []
        func workFor(_ seconds: Int) {
            for _ in 0..<seconds {
                work += 1
                wall = wall.addingTimeInterval(1)
                sched.overlayShowing = (due != nil)
                sched.step()
            }
        }
        func resolve(_ reason: BreakEndReason) {
            guard let kind = due else { return }
            due = nil
            sched.overlayShowing = false
            sched.breakFinished(kind, reason)
        }

        for _ in 0..<4 {
            workFor(5 * 60)
            strains.append(last?.eye.strain ?? 0)
            resolve(.snoozed)
        }
        let refusals = last?.eye.refusals ?? 0
        workFor(5 * 60)
        let trail = handed          // what the fifth card was handed: four extensions
        resolve(.completed)
        return (strains, refusals, trail, last?.eye.strain ?? -1)
    }

    /// The break card's story, straight off the pure loop: what a trail looks like
    /// after two extensions and a skip, what a call leaves on it instead, and the
    /// sentence the card writes under the chain in each case.
    private static func trailStory()
        -> (handed: [Loop.Mark], afterTaking: [Loop.Mark], callTrail: [Loop.Mark],
            callRefusals: Int, line: String, callLine: String, cleanLine: String?) {
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        var s = Loop.State()
        for reason in [BreakEndReason.snoozed, .snoozed, .skipped] {
            (s, _) = Loop.step(s, .breakFinished(.eye, reason, now: now))
        }
        let handed = Loop.trail(s, .eye)
        var rested = Loop.State()
        (rested, _) = Loop.step(s, .breakFinished(.eye, .completed, now: now))

        let onCall = Loop.fire(Loop.State(), .eye, onCall: true, now: now, callConfig).0

        func line(_ trail: [Loop.Mark], overdue: Int) -> String? {
            _ = overdue
            return Card.line(trail: trail)
        }
        return (handed, Loop.trail(rested, .eye), Loop.trail(onCall, .eye),
                onCall.eye.refusals,
                line(handed, overdue: 600) ?? "(nothing)",
                line(Loop.trail(onCall, .eye), overdue: 0) ?? "(nothing)",
                line([], overdue: 0))
    }

    /// On a call, with on-call nudges on: the one configuration that marks a trail
    /// without the user touching anything.
    private static let callConfig = Loop.Config(
        eyeEnabled: true, moveEnabled: true, eyeIntervalSec: 20 * 60, moveIntervalSec: 45 * 60,
        meetingAware: true, callBreaks: true, idleAware: true, awayResetSec: 15 * 60)
}
