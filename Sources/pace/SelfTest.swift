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

        print("\nglyph — a gauge you cannot see is not a gauge")
        // The design this replaced passed every monotonicity check while being
        // invisible: ink rose smoothly across the movement axis and not one pixel of
        // the 1296 changed at the size the bar renders. Monotone and perceptible are
        // different claims. These gate the second one, in pixels, at 36px.
        let mono = IconMaker.Appearance(differentiateWithoutColor: true)
        let plain = IconMaker.Appearance.standard
        // The app's own redraw quantisation, not a finer grid: if a step the app can
        // actually produce is invisible, the icon repaints and the user sees nothing.
        // Exactly the quantisation AppDelegate ships, so the claim these prove is
        // the strong one: every redraw the app can produce is a change a person can
        // see. Finer steps are not a better gauge, they are a repaint that shows
        // nothing — which is how the previous design passed every check while being
        // invisible.
        let eyeSteps = stride(from: 0.0, through: 2.0, by: 0.5).map { CGFloat($0) }
        let moveSteps = stride(from: 0.0, through: 2.0, by: 0.25).map { CGFloat($0) }
        let floor = 12   // of 1296 px. The design that failed bottomed out at 2.

        if dumpCurve {
            for e in stride(from: 0.0, through: 2.0, by: 0.25) {
                let m = IconMaker.measure(.init(eye: CGFloat(e)))
                print(String(format: "    eye %.2f  ink %6.1f  tone %@", e, m.ink,
                             String(describing: IconMaker.headTone(IconMaker.strain(CGFloat(e), paused: false),
                                                                   missed: 0, plain))))
            }
        }

        func worstStep(_ states: [IconMaker.GlyphState], _ ap: IconMaker.Appearance) -> (Int, String) {
            var worst = Int.max, where_ = ""
            for (x, y) in zip(states, states.dropFirst()) {
                let d = IconMaker.visibleDelta(x, y, ap)
                if d < worst {
                    worst = d
                    // name the axis that actually moved, or the label lies about
                    // which step was the weak one
                    where_ = x.eye != y.eye
                        ? String(format: "eye %.2f→%.2f", x.eye, y.eye)
                        : String(format: "move %@→%@",
                                 x.move.map { String(format: "%.2f", $0) } ?? "off",
                                 y.move.map { String(format: "%.2f", $0) } ?? "off")
                }
            }
            return (worst, where_)
        }

        // Movement. This is the axis the previous design lost, so it is checked at
        // every eye level rather than just the convenient one.
        var worstMove = Int.max, worstMoveAt = ""
        for e in [0.0, 0.5, 1.0, 1.5, 2.0] as [CGFloat] {
            let col = moveSteps.map { IconMaker.GlyphState(eye: e, move: $0) }
            let (d, w) = worstStep(col, plain)
            if d < worstMove { worstMove = d; worstMoveAt = w }
        }
        check("every posture step is visible at 36px",
              "worst \(worstMove) px at \(worstMoveAt)", worstMove >= floor)

        // The eye axis in colour. Its whole range is a hue ramp on one disc, so this
        // is the assertion that the ramp's stops are far enough apart to read.
        let (worstEye, worstEyeAt) = worstStep(eyeSteps.map { .init(eye: $0, move: 0.5) }, plain)
        check("every eye step is visible at 36px", "worst \(worstEye) px at \(worstEyeAt)", worstEye >= floor)

        // The one that makes the fallback real. Making the head solid moved the eye
        // axis entirely onto colour: in monochrome the first three steps are 0 px.
        // `differentiateWithoutColor` hands the axis back to head size, and if that
        // ever stops working the fallback is decoration.
        let (worstMonoEye, worstMonoAt) = worstStep(eyeSteps.map { .init(eye: $0, move: 0.5) }, mono)
        check("…and still visible with colour switched off",
              "worst \(worstMonoEye) px at \(worstMonoAt)", worstMonoEye >= floor)

        // Orthogonality, phrased on the marks rather than on pixels: the gauges may
        // not borrow each other's channel. Movement moving the head would make the
        // eye unreadable while movement changed; the eye moving the body would break
        // the silhouette pace is findable by on a crowded bar.
        let headMoved = moveSteps.contains { m in
            IconMaker.marks(.init(eye: 1.0, move: m)).first { $0.id == .head }?.tone
                != IconMaker.marks(.init(eye: 1.0, move: 0)).first { $0.id == .head }?.tone
        }
        check("movement never touches the eye's tone", "", !headMoved)
        let bodyMoved = eyeSteps.contains { e in
            IconMaker.marks(.init(eye: e, move: 1.0)).first { $0.id == .body }
                != IconMaker.marks(.init(eye: 0, move: 1.0)).first { $0.id == .body }
        }
        check("the eye never moves the body", "", !bodyMoved)

        // Posture only ever closes, and only movement closes it.
        let leans = moveSteps.map { IconMaker.posture(move: IconMaker.strain($0, paused: false),
                                                      onCall: false, nudge: false).leanDeg }
        check("the lean only ever increases",
              String(format: "%.0f° → %.0f°", leans.first ?? 0, leans.last ?? 0),
              zip(leans, leans.dropFirst()).allSatisfy { $1 > $0 })
        check("rested still reads as a body, not a flagpole",
              String(format: "%.0f°", leans.first ?? 0), (leans.first ?? 0) > 5)

        // Breaks missed ride the eye ramp rather than getting a mark of their own,
        // so a refusal has to actually move the tone.
        let byMissed = (0...IconMaker.maxMissed).map { n in
            IconMaker.marks(.init(eye: 0.5, missed: n)).first { $0.id == .head }?.tone
        }
        check("each further break missed shows on the head", "0…\(IconMaker.maxMissed)",
              Set(byMissed.map { String(describing: $0) }).count == IconMaker.maxMissed + 1)

        // Everything must fit the 18pt box. The eye axis is forbidden from moving
        // the body, so the figure has to be laid out for its LARGEST head — which
        // the monochrome one is, and it grew straight out of the top before this
        // check existed.
        var spill: [String] = []
        for ap in [plain, mono] {
            for e in eyeSteps {
                for m in moveSteps {
                    for (call, paused) in [(false, false), (true, false), (false, true)] {
                        let st = IconMaker.GlyphState(eye: e, move: m, missed: 3,
                                                      onCall: call, paused: paused)
                        for mk in IconMaker.marks(st, ap) {
                            let b = IconMaker.bounds(mk)
                            if b.minX < -0.01 || b.minY < -0.01 || b.maxX > 18.01 || b.maxY > 18.01 {
                                spill.append(String(format: "%@ eye %.1f move %.1f → %.1f…%.1f",
                                                    String(describing: mk.id), e, m, b.minY, b.maxY))
                            }
                        }
                    }
                }
            }
        }
        check("the glyph never leaves its 18pt box", spill.prefix(2).joined(separator: ", "), spill.isEmpty)

        // The appearance matrix, enumerated. This is the payoff for Appearance being
        // a value: the combination that only shows up on someone else's Mac with an
        // accessibility setting on is checked here rather than discovered there.
        var blank: [String] = []
        for dark in [false, true] {
            for hi in [false, true] {
                for diff in [false, true] {
                    for contrast in [false, true] {
                        let ap = IconMaker.Appearance(barIsDark: dark, highlighted: hi,
                                                      differentiateWithoutColor: diff,
                                                      increaseContrast: contrast)
                        let ink = IconMaker.measure(.init(eye: 1.0, move: 1.0), ap).ink
                        if ink < 20 { blank.append("dark:\(dark) hi:\(hi) diff:\(diff) contrast:\(contrast)") }
                    }
                }
            }
        }
        check("all 16 appearance combinations draw a glyph", blank.joined(separator: ", "), blank.isEmpty)

        // A template image is the only kind macOS tints for free, so the mono path
        // must actually produce one — and the colour path must not claim to be one.
        check("colour off gives a template image", "",
              IconMaker.statusImage(.init(eye: 1.0), mono).isTemplate)
        check("colour on gives a plain image", "",
              !IconMaker.statusImage(.init(eye: 1.0), plain).isTemplate)

        // Mode composition, on the marks: what is on the glyph in each mode, by name.
        func ids(_ st: IconMaker.GlyphState) -> String {
            IconMaker.marks(st).map { String(describing: $0.id) }.joined(separator: " + ")
        }
        check("paused lays the pause sign over the figure", ids(.init(eye: 1.5, paused: true)),
              ids(.init(eye: 1.5, paused: true)) == "body + head + pauseHalo + pauseHalo + pause + pause")
        check("a paused glyph reads as rested", "",
              IconMaker.marks(.init(eye: 2.0, missed: 3, paused: true)) == IconMaker.marks(.init(eye: 0, paused: true)))
        check("on a call keeps the held bar", ids(.init(eye: 1.0, onCall: true)),
              ids(.init(eye: 1.0, onCall: true)) == "body + callBar + head")
        check("the glance-away cue sits the figure up", "",
              IconMaker.posture(move: IconMaker.strain(2, paused: false), onCall: true, nudge: true).leanDeg
                  < IconMaker.posture(move: IconMaker.strain(2, paused: false), onCall: true, nudge: false).leanDeg)

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

        print("\na meeting's opening minutes — and the break you asked for anyway")
        let call = callManners()
        // The grace holds the banner, never the debt. If the counter stopped climbing
        // too, a morning of back-to-back calls would come out owing nothing.
        check("a nudge waits out the start of a call", "\(call.firstNudgeSec)s in",
              call.firstNudgeSec == Int(Deferral.callGraceSec))
        check("the break is still owed while it waits", "elapsed \(call.elapsedAtNudge)s",
              call.elapsedAtNudge > 0)
        check("waiting is not a refusal, because you were never asked",
              "refusals=\(call.refusalsAtNudge)", call.refusalsAtNudge == 0)
        // The one that no `--sim` script can reach: the simulator has no verb for the
        // menu's "break now", which is exactly how this went unnoticed on a live call.
        check("a break you asked for is not swept away by a call",
              call.askedForSurvives ? "stays up" : "dismissed", call.askedForSurvives)
        check("a break that turned up by itself still steps aside",
              call.unaskedDismissed ? "dismissed" : "stayed up", call.unaskedDismissed)

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

        print("\nfocus — a card that took the keyboard has to give it back")
        // The bug: a borderless full-screen window must steal activation or Esc
        // and ⌘S go to whatever is behind it, and nothing gave it back. pace has
        // no windows of its own, so a dismissed break left the keys typing into
        // nothing. Every way out of the card runs one `close`, so this is asserted
        // once rather than per button.
        let editor: pid_t = 501, pace: pid_t = 99
        check("the app the card interrupted gets the keyboard back", "",
              Handback.decide(paceActive: true, pace: pace, previous: editor, alive: true) == .give(editor))
        check("clicking into something else during the break wins", "",
              Handback.decide(paceActive: false, pace: pace, previous: editor, alive: true) == .keep)
        check("an app that quit mid-break leaves pace standing down", "",
              Handback.decide(paceActive: true, pace: pace, previous: editor, alive: false) == .standDown)
        check("pace never hands the keyboard to itself", "",
              Handback.decide(paceActive: true, pace: pace, previous: pace, alive: true) == .standDown)
        check("no record of who was there is not a reason to keep it", "",
              Handback.decide(paceActive: true, pace: pace, previous: nil, alive: true) == .standDown)

        print("\nnudges — a record of what was sent must not be a record of what was intended")
        // The failure this section gates: a nudge logged whatever macOS did, so
        // "I never saw it" and "it was never sent" left identical rows. Every
        // claim here is about that distinction surviving.
        check("a denied permission can never record as sent", "",
              ![Permission.denied, .neverAsked, .noBundle]
                  .map { Delivery.of($0, failed: false) }
                  .contains { $0.sent })
        check("banners on, accepted, reads as sent", "",
              Delivery.of(.allowed(alerts: true), failed: false) == .banner)
        check("banners off still leaves Notification Centre", "",
              Delivery.of(.allowed(alerts: false), failed: false) == .centreOnly)
        check("a refused request is not a delivery", "",
              !Delivery.of(.allowed(alerts: true), failed: true).sent)
        // The one that keeps the back history honest: rows written before delivery
        // was tracked must not be read as either outcome.
        let nudges = nudgeLog()
        check("a nudge with no delivery recorded claims neither way", "",
              Delivery.describe(nil) == Delivery.unrecorded
              && nudges.tally == Activity.Tally(sent: 1, notSent: 1, unrecorded: 1))
        check("the row says in words what became of it", "",
              nudges.sentRow.contains("banner sent") && nudges.blockedRow.contains("not sent"))
        check("a blocked nudge is not drawn as a delivered one", "",
              nudges.sentTone == .sent && nudges.blockedTone == .missed && nudges.legacyTone == .missed)
        check("a delivery survives the log and back", "\(nudges.roundTripped ?? "nil")",
              nudges.roundTripped == Delivery.banner.rawValue)
        check("newest first, grouped by day", "\(nudges.dayTitles)",
              nudges.dayTitles == ["Today", "Yesterday"] && nudges.firstRowIsNewest)

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

    /// Three nudges — one delivered, one blocked, one from before delivery was
    /// recorded — plus a day boundary, through the real builder. Everything the
    /// activity log claims is read off this one fixture.
    private static func nudgeLog() -> (tally: Activity.Tally, sentRow: String, blockedRow: String,
                                       sentTone: Activity.Tone, blockedTone: Activity.Tone,
                                       legacyTone: Activity.Tone, roundTripped: String?,
                                       dayTitles: [String], firstRowIsNewest: Bool) {
        let cal = Calendar.current
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        let today = cal.startOfDay(for: now).addingTimeInterval(9 * 3600)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let events = [
            BreakEvent(at: today, kind: "eye", outcome: "nudged", seconds: 0,
                       overdueSec: 0, refusals: 0, callSec: 600, delivery: Delivery.banner.rawValue),
            BreakEvent(at: today + 600, kind: "eye", outcome: "nudged", seconds: 0,
                       overdueSec: 300, refusals: 0, callSec: 1200, delivery: Delivery.blocked.rawValue),
            BreakEvent(at: today + 1200, kind: "move", outcome: "nudged", seconds: 0),   // before delivery existed
            BreakEvent(at: yesterday, kind: "eye", outcome: "completed", seconds: 30),
        ]
        let log = Activity.log(events, now: now, permission: .allowed(alerts: true), calendar: cal)
        let rows = log.days.first?.rows ?? []
        // Round-trip through the encoder the log actually writes with.
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = (try? enc.encode(events[0])).flatMap { try? dec.decode(BreakEvent.self, from: $0) }
        return (tally: log.tally,
                sentRow: Activity.row(events[0]).detail,
                blockedRow: Activity.row(events[1]).detail,
                sentTone: Activity.row(events[0]).tone,
                blockedTone: Activity.row(events[1]).tone,
                legacyTone: Activity.row(events[2]).tone,
                roundTripped: back?.delivery,
                dayTitles: log.days.map(\.title),
                firstRowIsNewest: rows.first?.at == today + 1200)
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
    /// Two manners a call asks of the loop, driven through the reducer a minute at a
    /// time. Both are invisible to `--sim`: the first because a grace only shows up as
    /// an absence, the second because the simulator has no verb for the menu's
    /// "break now" — which is precisely how it went unnoticed on a live call.
    private static func callManners()
        -> (firstNudgeSec: Int, elapsedAtNudge: Double, refusalsAtNudge: Int,
            askedForSurvives: Bool, unaskedDismissed: Bool) {
        let t0 = Date(timeIntervalSince1970: 1_755_000_000)
        func tick(_ s: Loop.State, at sec: Int, inCall: Bool, overlay: Bool = false)
            -> (Loop.State, [Loop.Effect]) {
            Loop.step(s, .tick(.init(now: t0.addingTimeInterval(Double(sec)), delta: 60, idle: 0,
                                     inCall: inCall, overlayShowing: overlay, config: callConfig)))
        }

        // Work past the eye interval off-call, so the break is already owed when the
        // call lands. Then stay on the call and wait for the banner.
        var s = Loop.State()
        for m in 1...25 { (s, _) = tick(s, at: m * 60, inCall: false) }
        let callStart = 26 * 60
        var nudgeAt = -1, elapsed = 0.0, refusals = 0
        for m in 26...45 {
            let (next, fx) = tick(s, at: m * 60, inCall: true)
            s = next
            if nudgeAt < 0, fx.contains(where: { if case .callNudge = $0 { return true }; return false }) {
                nudgeAt = m * 60 - callStart
                elapsed = s.eye.elapsed
                refusals = s.eye.refusals
            }
        }

        // The same second of the same call, asked for and not. Only the break that
        // turned up by itself may be swept off the screen.
        func dismissed(askedFor: Bool) -> Bool {
            var c = Loop.State()
            if askedFor { (c, _) = Loop.step(c, .triggerNow(.eye, overlayShowing: false)) }
            let (_, fx) = tick(c, at: 60, inCall: true, overlay: true)
            return fx.contains { if case .meetingDuringBreak = $0 { return true }; return false }
        }
        return (nudgeAt, elapsed, refusals, !dismissed(askedFor: true), dismissed(askedFor: false))
    }

    private static let callConfig = Loop.Config(
        eyeEnabled: true, moveEnabled: true, eyeIntervalSec: 20 * 60, moveIntervalSec: 45 * 60,
        meetingAware: true, callBreaks: true, idleAware: true, awayResetSec: 15 * 60)
}
