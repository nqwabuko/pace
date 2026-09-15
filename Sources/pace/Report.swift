import Foundation

/// One logged break. The JSONL log of these (in Application Support) is the
/// source of truth; the Obsidian notes are a rendered *view* of it, so they can
/// be rebuilt any time and never drift.
struct BreakEvent: Codable {
    let at: Date
    let kind: String        // "eye" | "move"
    let outcome: String     // "completed" | "skipped" | "snoozed" | "interrupted" | "nudged" | "rested"
    let seconds: Int        // rest seconds credited (a taken break, or a long spell away)

    /// What the deferral actually cost, recorded at the moment it stopped being
    /// true: how far past due this break had run, and how many times it had
    /// already been put off since its last real rest. `refusals` counts the
    /// put-offs *before* this event, so a `completed` row says how many extensions
    /// it took before you sat through it.
    ///
    /// Optional, and they have to stay that way: every line written before this
    /// existed lacks both keys, a non-optional `Int` would throw decoding them,
    /// and `events()` drops what it can't decode — so the entire back history
    /// would quietly vanish from the dashboard.
    let overdueSec: Int?
    let refusals: Int?

    /// Of the stretch since this break was last rested, how much of it you spent on
    /// a call. Recorded on the row that *ends* the stretch, for the same reason
    /// `overdueSec` is: a break put off four times then taken contributes its call
    /// time once, not five times. `nudged` rows carry the running figure too, so a
    /// long call can be read mid-flight, but the day totals only count the rows that
    /// closed a debt.
    ///
    /// Optional for the same non-negotiable reason as the two above.
    let callSec: Int?

    init(at: Date, kind: String, outcome: String, seconds: Int,
         overdueSec: Int? = nil, refusals: Int? = nil, callSec: Int? = nil) {
        self.at = at
        self.kind = kind
        self.outcome = outcome
        self.seconds = seconds
        self.overdueSec = overdueSec
        self.refusals = refusals
        self.callSec = callSec
    }
}

/// Logging + Obsidian rendering. Writes a per-day note (with Dataview-friendly
/// YAML frontmatter, so it folds into an existing self-mastery vault) plus a
/// plugin-free dashboard: averages, a streak, a monospace bar chart, and a
/// native-mermaid pie. Everything is local; no network.
enum Report {
    static let dir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pace", isDirectory: true)
    static let logURL = dir.appendingPathComponent("events.jsonl")

    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// All disk work happens here, off the main thread. The vault can be a folder
    /// on an unmounted network volume, and a blocking write on the main thread
    /// would stall the run loop — which *is* the break timer and the overlay
    /// countdown. One serial queue keeps the ordering guarantees a log needs.
    private static let io = DispatchQueue(label: "global.ampeco.pace.report", qos: .utility)

    /// What the last vault write did, published back on the main thread so the
    /// menu can say so. `nil` means fine. Failures are not fatal and not sticky:
    /// the next break tries again, so a volume that comes back heals itself.
    struct VaultHealth {
        var lastError: String?
        var consecutiveFailures = 0
        var lastSuccess: Date?
        var isFailing: Bool { consecutiveFailures > 0 }

        /// Fold one attempt in. Pure on purpose: the run of consecutive failures is
        /// the part that carries meaning ("it's been broken for a while, not a
        /// blip"), and a pure fold can be checked without a disk to break.
        func folding(_ problem: String?, at now: Date) -> VaultHealth {
            guard let problem else {
                return VaultHealth(lastError: nil, consecutiveFailures: 0, lastSuccess: now)
            }
            return VaultHealth(lastError: problem,
                               consecutiveFailures: consecutiveFailures + 1,
                               lastSuccess: lastSuccess)
        }
    }

    /// Read on the main thread by the menu when it opens. One copy, no callback.
    private(set) static var vaultHealth = VaultHealth()

    // MARK: log (always, source of truth)

    static func log(kind: String, outcome: String, seconds: Int,
                    overdueSec: Int? = nil, refusals: Int? = nil, callSec: Int? = nil,
                    now: Date) {
        let ev = BreakEvent(at: now, kind: kind, outcome: outcome, seconds: seconds,
                            overdueSec: overdueSec, refusals: refusals, callSec: callSec)
        guard let data = try? enc.encode(ev), let line = String(data: data, encoding: .utf8) else { return }
        io.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            append(line + "\n", to: logURL)
        }
    }

    /// Read the log. Deliberately *not* serialised behind `io`: the log is
    /// append-only and every line decodes on its own, so the worst a concurrent
    /// write can do is leave a half-written last line, which `compactMap` drops.
    /// Queueing reads behind a slow vault write would stall the stats window for
    /// no benefit.
    static func events() -> [BreakEvent] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? dec.decode(BreakEvent.self, from: Data($0.utf8)) }
    }

    // MARK: in-app stats

    /// Aggregates for the glanceable in-app charts (last `daysBack` days).
    static func summary(now: Date, daysBack: Int = 14,
                        openCall: (eye: Int, move: Int) = (0, 0)) -> StatsSummary {
        summary(from: events(), now: now, daysBack: daysBack, openCall: openCall)
    }

    /// The pure half, so the arithmetic can be checked against a handful of made-up
    /// events instead of whatever happens to be on disk. `daysBack` is two weeks
    /// because the debt panel compares the last seven days with the seven before.
    /// `openCall` is the call time standing against each break *right now*, from the
    /// running loop rather than the log. The log only learns what a call cost when a
    /// break closes and carries the figure, so an afternoon of back-to-back calls
    /// with no break taken yet reads as zero everywhere — which is precisely the
    /// afternoon you would want to look at this panel. The two never overlap: the log
    /// holds the closed stretches, this is the open one, so they add.
    static func summary(from evs: [BreakEvent], now: Date, daysBack: Int = 14,
                        openCall: (eye: Int, move: Int) = (0, 0)) -> StatsSummary {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: evs) { dayKey($0.at) }

        var days: [DayCount] = []
        for i in stride(from: daysBack - 1, through: 0, by: -1) {
            let date = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: now))!
            let list = byDay[dayKey(date)] ?? []
            let taken = list.filter { $0.outcome == "completed" }
            days.append(DayCount(day: date,
                                 eye: taken.filter { $0.kind == "eye" }.count,
                                 move: taken.filter { $0.kind == "move" }.count,
                                 overdueSec: eyeDebtCleared(list),
                                 putOffs: list.filter(isPutOff).count,
                                 callEyeSec: callHeld(list, kind: "eye") + (i == 0 ? openCall.eye : 0),
                                 callMoveSec: callHeld(list, kind: "move") + (i == 0 ? openCall.move : 0)))
        }

        let week = days.suffix(7)
        let prevWeek = days.prefix(max(0, days.count - 7))
        let last7 = week.reduce(0) { $0 + $1.total }

        var streak = 0, d = cal.startOfDay(for: now)
        while let list = byDay[dayKey(d)], list.contains(where: { $0.outcome == "completed" }) {
            streak += 1
            d = cal.date(byAdding: .day, value: -1, to: d)!
        }

        let cutoff30 = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))!
        let recent = evs.filter { $0.at >= cutoff30 && $0.outcome == "completed" }
        let cutoff7 = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!

        return StatsSummary(days: Array(days),
                            todayTotal: days.last?.total ?? 0,
                            avg7: Double(last7) / 7.0,
                            streak: streak,
                            eye30: recent.filter { $0.kind == "eye" }.count,
                            move30: recent.filter { $0.kind == "move" }.count,
                            overdueToday: days.last?.overdueSec ?? 0,
                            putOffsToday: days.last?.putOffs ?? 0,
                            overdueWeek: week.reduce(0) { $0 + $1.overdueSec },
                            putOffsWeek: week.reduce(0) { $0 + $1.putOffs },
                            overduePrevWeek: prevWeek.reduce(0) { $0 + $1.overdueSec },
                            putOffsPrevWeek: prevWeek.reduce(0) { $0 + $1.putOffs },
                            callEyeToday: days.last?.callEyeSec ?? 0,
                            callMoveToday: days.last?.callMoveSec ?? 0,
                            callEyeWeek: week.reduce(0) { $0 + $1.callEyeSec },
                            callMoveWeek: week.reduce(0) { $0 + $1.callMoveSec },
                            callDaysWeek: week.filter { $0.callEyeSec > 0 || $0.callMoveSec > 0 }.count,
                            split: takeSplit(evs.filter { $0.at >= cutoff7 }))
    }

    /// Eye seconds worked past due, from the events that cleared an eye debt:
    /// sitting one out, or a long enough spell away from the keys. Only the event
    /// that *ends* a debt carries it, so a break put off four times contributes its
    /// twenty overdue minutes once, not once per extension.
    ///
    /// Eye only, on purpose. Eye and move overdue overlap in real time, so adding
    /// the two would count the same strained minute twice and stop the number being
    /// a quantity of time at all. The known gap: a movement break rests your eyes
    /// too but logs as `move`, so the eye debt it cleared goes unattributed. This
    /// under-reports rather than double-counts, which is the right way to be wrong
    /// about a number you're using to argue with yourself.
    private static func eyeDebtCleared(_ list: [BreakEvent]) -> Int {
        list.filter { $0.kind == "eye" && ($0.outcome == "completed" || $0.outcome == "rested") }
            .reduce(0) { $0 + ($1.overdueSec ?? 0) }
    }

    /// How long calls held one break kind off, over a set of events: summed from the
    /// rows that closed a debt, so an extended break counts its call time once.
    ///
    /// Per kind and never summed across kinds, unlike `eyeDebtCleared`, which reports
    /// eye only. It can afford to: "calls held your eyes off for 40 minutes" and
    /// "calls held you in your chair for 40 minutes" are two readings of the same
    /// forty minutes, and both are worth saying as long as nothing adds them.
    static func callHeld(_ list: [BreakEvent], kind: String) -> Int {
        list.filter { $0.kind == kind && ($0.outcome == "completed" || $0.outcome == "rested") }
            .reduce(0) { $0 + ($1.callSec ?? 0) }
    }

    /// Chose to put it off. A call cutting a break short doesn't count, and neither
    /// does a nudge — same rule as `BreakEndReason.isRefusal`, which is what wrote
    /// these rows.
    private static func isPutOff(_ e: BreakEvent) -> Bool { e.outcome == "snoozed" || e.outcome == "skipped" }

    /// How many extensions the breaks you took needed first. Rows written before
    /// `refusals` existed are left out entirely rather than read as zero: counting
    /// a nil as "took it first time" would flatter the old history and make the
    /// percentage drop the day the honest data started.
    private static func takeSplit(_ evs: [BreakEvent]) -> TakeSplit {
        let taken = evs.compactMap { $0.outcome == "completed" ? $0.refusals : nil }
        return TakeSplit(first: taken.filter { $0 == 0 }.count,
                         once: taken.filter { $0 == 1 }.count,
                         more: taken.filter { $0 >= 2 }.count)
    }

    // MARK: vault rendering

    static func vaultBase(_ vaultPath: String) -> URL {
        URL(fileURLWithPath: vaultPath).appendingPathComponent("pace", isDirectory: true)
    }
    static func dailyURL(_ vaultPath: String, now: Date) -> URL {
        vaultBase(vaultPath).appendingPathComponent("\(dayKey(now)).md")
    }
    static func dashboardURL(_ vaultPath: String) -> URL {
        vaultBase(vaultPath).appendingPathComponent("pace-dashboard.md")
    }

    /// Rewrite today's note (or all days) and the dashboard from the log. Runs off
    /// the main thread and reports what happened rather than swallowing it, so a
    /// vault that has moved, been deleted, or gone offline is visible in the menu
    /// instead of silently doing nothing for weeks.
    static func updateVault(_ vaultPath: String, rebuildAll: Bool = false, now: Date) {
        guard !vaultPath.isEmpty else { return }
        io.async {
            let evs = events()
            let problem = render(evs, base: vaultBase(vaultPath), rebuildAll: rebuildAll, now: now)
            DispatchQueue.main.async { recordVault(problem, at: now) }
        }
    }

    private static func recordVault(_ problem: String?, at now: Date) {
        vaultHealth = vaultHealth.folding(problem, at: now)
    }

    /// Render a folder of sample notes (for `pace --report-demo <dir>`), so the
    /// Obsidian format can be previewed without touching the real log.
    static func previewVault(at path: String, now: Date) {
        _ = render(sampleEvents(now: now), base: URL(fileURLWithPath: path).appendingPathComponent("pace", isDirectory: true), rebuildAll: true, now: now)
    }

    /// A made-up fortnight: breaks taken, some extended a few times first, the odd
    /// skip, and a lunch break every fifth day. Feeds both the sample vault and the
    /// stats-window preview, so what you review is what the real code renders.
    static func sampleEvents(now: Date) -> [BreakEvent] {
        var evs: [BreakEvent] = []
        let cal = Calendar.current
        for d in 0..<14 {
            guard let day = cal.date(byAdding: .day, value: -d, to: now) else { continue }
            let base = cal.startOfDay(for: day)
            for e in 0..<(4 + d % 5) {
                // Some of them get extended a couple of times first, so the sample
                // shows the debt panel with something in it.
                let at = base.addingTimeInterval(Double(9 * 3600 + e * 1200))
                let puts = (e == 1 ? d % 4 : 0)
                for r in 0..<puts {
                    evs.append(BreakEvent(at: at.addingTimeInterval(Double(r * 300)), kind: "eye", outcome: "snoozed",
                                          seconds: 0, overdueSec: r * 300, refusals: r))
                }
                // Every other day is call-heavy, and the eye break that lands mid-morning
                // is the one that carries the call time on those days.
                let onCall = (d % 2 == 0 && e == 2) ? (20 + d % 4 * 10) * 60 : 0
                evs.append(BreakEvent(at: at.addingTimeInterval(Double(puts * 300)), kind: "eye", outcome: "completed",
                                      seconds: 30, overdueSec: puts * 300, refusals: puts, callSec: onCall))
            }
            for m in 0..<(1 + d % 3) {
                let onCall = (d % 2 == 0 && m == 0) ? (35 + d % 4 * 10) * 60 : 0
                evs.append(BreakEvent(at: base.addingTimeInterval(Double(10 * 3600 + m * 3000)), kind: "move", outcome: "completed", seconds: 120, overdueSec: 0, refusals: 0, callSec: onCall))
            }
            if d % 2 == 0 { evs.append(BreakEvent(at: base.addingTimeInterval(11 * 3600), kind: "eye", outcome: "skipped", seconds: 0, overdueSec: 0, refusals: 0)) }
            if d % 5 == 0 {
                for k in ["eye", "move"] { evs.append(BreakEvent(at: base.addingTimeInterval(13 * 3600), kind: k, outcome: "rested", seconds: 2700, overdueSec: 600, refusals: 1)) }
            }
        }
        return evs
    }

    /// Try one vault write and say what happened, for `pace --check`. The same
    /// code path the app uses, run synchronously so the CLI can report it.
    static func probeVault(_ vaultPath: String, now: Date) -> String? {
        guard !vaultPath.isEmpty else { return "not logging" }
        return io.sync { render(events(), base: vaultBase(vaultPath), rebuildAll: false, now: now) }
    }

    /// Returns nil on success, or a short human-readable reason on failure.
    private static func render(_ evs: [BreakEvent], base: URL, rebuildAll: Bool, now: Date) -> String? {
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let byDay = Dictionary(grouping: evs) { dayKey($0.at) }
            if rebuildAll {
                for (day, list) in byDay { try write(dayNote(day, list), to: base.appendingPathComponent("\(day).md")) }
            } else {
                let today = dayKey(now)
                try write(dayNote(today, byDay[today] ?? []), to: base.appendingPathComponent("\(today).md"))
            }
            try write(dashboard(byDay, now: now), to: base.appendingPathComponent("pace-dashboard.md"))
            return nil
        } catch {
            return (error as NSError).localizedDescription
        }
    }

    // MARK: markdown builders

    private static func dayNote(_ day: String, _ list: [BreakEvent]) -> String {
        let eye = list.filter { $0.kind == "eye" && $0.outcome == "completed" }.count
        let move = list.filter { $0.kind == "move" && $0.outcome == "completed" }.count
        let skipped = list.filter { $0.outcome == "skipped" }.count
        let putOff = list.filter(isPutOff).count
        let awayRests = list.filter { $0.outcome == "rested" && $0.kind == "eye" }.count
        let minutes = list.filter { $0.outcome == "completed" }.reduce(0) { $0 + $1.seconds } / 60
        let overdueMin = eyeDebtCleared(list) / 60
        let callEyeMin = callHeld(list, kind: "eye") / 60
        let callMoveMin = callHeld(list, kind: "move") / 60

        var s = """
        ---
        date: \(day)
        pace_eye: \(eye)
        pace_move: \(move)
        pace_skipped: \(skipped)
        pace_put_off: \(putOff)
        pace_away_rests: \(awayRests)
        pace_eye_overdue_min: \(overdueMin)
        pace_break_minutes: \(minutes)
        pace_call_held_eye_min: \(callEyeMin)
        pace_call_held_move_min: \(callMoveMin)
        ---
        # pace · \(day)

        \(eye) eye · \(move) move · \(skipped) skipped · \(minutes) min resting
        Put off \(putOff)× · \(overdueMin) min of eye time past due
        Held by calls: \(callEyeMin) min without an eye rest · \(callMoveMin) min without moving

        | time | break | outcome | overdue | put off before | on a call |
        |------|-------|---------|---------|----------------|-----------|

        """
        for e in list.sorted(by: { $0.at < $1.at }) {
            let over = e.overdueSec.map { "\($0 / 60)m \($0 % 60)s" } ?? "–"
            let put = e.refusals.map(String.init) ?? "–"
            let call = e.callSec.map { "\($0 / 60)m" } ?? "–"
            s += "| \(clockHM(e.at)) | \(e.kind) | \(e.outcome) | \(over) | \(put) | \(call) |\n"
        }
        return s
    }

    private static func dashboard(_ byDay: [String: [BreakEvent]], now: Date) -> String {
        func stats(_ days: Int) -> String {
            let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: now))!
            let win = byDay.values.flatMap { $0 }.filter { $0.at >= cutoff }
            let completed = win.filter { $0.outcome == "completed" }.count
            let minutes = win.filter { $0.outcome == "completed" }.reduce(0) { $0 + $1.seconds } / 60
            let perDay = Double(completed) / Double(days)
            let minPerDay = Double(minutes) / Double(days)
            // Not a "% taken" ratio any more. That one counted a break you extended
            // twice and then sat through as two thirds of a failure, and left plain
            // extensions out of the denominator entirely. Put-offs and first-time
            // takes are two different facts, so they get reported as two numbers.
            let putOff = win.filter(isPutOff).count
            let overdueMin = eyeDebtCleared(win) / 60
            let split = takeSplit(win)
            let firstTime = split.total > 0 ? "\(split.firstPct)% first time" : "no first-time data yet"
            return String(format: "%.1f taken/day · %.0f min/day resting · %.1f put off/day · %d min past due · %@\n  - *Held by calls:* %d min without an eye rest, %d min without moving",
                          perDay, minPerDay, Double(putOff) / Double(days), overdueMin, firstTime,
                          callHeld(win, kind: "eye") / 60, callHeld(win, kind: "move") / 60)
        }

        // Current streak: consecutive days up to today with ≥1 completed break.
        var streak = 0
        var d = Calendar.current.startOfDay(for: now)
        while let list = byDay[dayKey(d)], list.contains(where: { $0.outcome == "completed" }) {
            streak += 1
            d = Calendar.current.date(byAdding: .day, value: -1, to: d)!
        }

        // 14-day bar chart (monospace, no plugin needed).
        var days: [(String, Int)] = []
        for i in stride(from: 13, through: 0, by: -1) {
            let day = Calendar.current.date(byAdding: .day, value: -i, to: Calendar.current.startOfDay(for: now))!
            let key = dayKey(day)
            let n = byDay[key]?.filter { $0.outcome == "completed" }.count ?? 0
            days.append((String(key.suffix(5)), n))
        }
        let maxN = max(1, days.map { $0.1 }.max() ?? 1)
        let bars = days.map { label, n -> String in
            let filled = Int(round(Double(n) / Double(maxN) * 10))
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
            return "\(label)  \(bar)  \(n)"
        }.joined(separator: "\n")

        // Eye vs move over 30 days.
        let cutoff30 = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: now))!
        let recent = byDay.values.flatMap { $0 }.filter { $0.at >= cutoff30 && $0.outcome == "completed" }
        let eye = recent.filter { $0.kind == "eye" }.count
        let move = recent.filter { $0.kind == "move" }.count

        return """
        ---
        updated: \(clockHM(now)) \(dayKey(now))
        ---
        # pace dashboard

        ## Averages
        - **Last 7 days:** \(stats(7))
        - **Last 30 days:** \(stats(30))
        - **Streak:** \(streak) day\(streak == 1 ? "" : "s") with a break

        ## Breaks per day (last 14 days)
        ```text
        \(bars)
        ```

        ## Eye vs move (last 30 days)
        ```mermaid
        pie showData
            title Breaks by type
            "Eye" : \(eye)
            "Move" : \(move)
        ```
        """
    }

    // MARK: helpers

    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static let hmFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static func dayKey(_ d: Date) -> String { dayFmt.string(from: d) }
    private static func clockHM(_ d: Date) -> String { hmFmt.string(from: d) }

    private static func append(_ s: String, to url: URL) {
        let data = Data(s.utf8)
        if FileManager.default.fileExists(atPath: url.path), let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
