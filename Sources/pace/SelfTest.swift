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

        print("\nloop — extending a break must never credit a rest")
        let loop = extendFourTimes()
        check("counter keeps climbing through 4 extensions",
              loop.strains.map { String(format: "%.2f", $0) }.joined(separator: " → "),
              zip(loop.strains, loop.strains.dropFirst()).allSatisfy { $1 > $0 })
        check("four extensions are all counted", "refusals=\(loop.refusals)", loop.refusals == 4)
        check("taking it finally rests you", String(format: "%.2f", loop.afterTaking), loop.afterTaking == 0)

        print("\ndebt — extensions and the time they cost must both survive the log")
        let legacy = decodeLegacyLine()
        check("a line written before overdue/refusals existed still decodes",
              legacy.map { "\($0.outcome) overdue=\(String(describing: $0.overdueSec))" } ?? "dropped",
              legacy != nil && legacy?.overdueSec == nil && legacy?.refusals == nil)

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
    private static func extendFourTimes() -> (strains: [Double], refusals: Int, afterTaking: Double) {
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
        sched.onTick = { last = $0 }
        sched.onBreakDue = { kind, _ in due = kind; sched.overlayShowing = true }
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
        resolve(.completed)
        return (strains, refusals, last?.eye.strain ?? -1)
    }
}
