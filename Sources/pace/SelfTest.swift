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
