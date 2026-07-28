import Foundation

/// One logged break. The JSONL log of these (in Application Support) is the
/// source of truth; the Obsidian notes are a rendered *view* of it, so they can
/// be rebuilt any time and never drift.
struct BreakEvent: Codable {
    let at: Date
    let kind: String        // "eye" | "move"
    let outcome: String     // "completed" | "skipped" | "snoozed"
    let seconds: Int        // rest seconds credited (completed only)
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

    // MARK: log (always, source of truth)

    static func log(kind: String, outcome: String, seconds: Int, now: Date = Date()) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ev = BreakEvent(at: now, kind: kind, outcome: outcome, seconds: seconds)
        guard let data = try? enc.encode(ev), let line = String(data: data, encoding: .utf8) else { return }
        append(line + "\n", to: logURL)
    }

    static func events() -> [BreakEvent] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? dec.decode(BreakEvent.self, from: Data($0.utf8)) }
    }

    // MARK: in-app stats

    /// Aggregates for the glanceable in-app chart (last `daysBack` days).
    static func summary(now: Date = Date(), daysBack: Int = 14) -> StatsSummary {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: events().filter { $0.outcome == "completed" }) { dayKey($0.at) }

        var days: [DayCount] = []
        for i in stride(from: daysBack - 1, through: 0, by: -1) {
            let date = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: now))!
            let list = byDay[dayKey(date)] ?? []
            days.append(DayCount(day: date,
                                 eye: list.filter { $0.kind == "eye" }.count,
                                 move: list.filter { $0.kind == "move" }.count))
        }

        let last7 = days.suffix(7).reduce(0) { $0 + $1.total }
        var streak = 0, d = cal.startOfDay(for: now)
        while let list = byDay[dayKey(d)], !list.isEmpty { streak += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }

        let cutoff30 = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))!
        let recent = events().filter { $0.at >= cutoff30 && $0.outcome == "completed" }

        return StatsSummary(days: days,
                            todayTotal: days.last?.total ?? 0,
                            avg7: Double(last7) / 7.0,
                            streak: streak,
                            eye30: recent.filter { $0.kind == "eye" }.count,
                            move30: recent.filter { $0.kind == "move" }.count)
    }

    // MARK: vault rendering

    static func vaultBase(_ vaultPath: String) -> URL {
        URL(fileURLWithPath: vaultPath).appendingPathComponent("pace", isDirectory: true)
    }
    static func dailyURL(_ vaultPath: String, now: Date = Date()) -> URL {
        vaultBase(vaultPath).appendingPathComponent("\(dayKey(now)).md")
    }
    static func dashboardURL(_ vaultPath: String) -> URL {
        vaultBase(vaultPath).appendingPathComponent("pace-dashboard.md")
    }

    /// Rewrite today's note (or all days) and the dashboard from the log.
    static func updateVault(_ vaultPath: String, rebuildAll: Bool = false, now: Date = Date()) {
        guard !vaultPath.isEmpty else { return }
        render(events(), base: vaultBase(vaultPath), rebuildAll: rebuildAll, now: now)
    }

    /// Render a folder of sample notes (for `pace --report-demo <dir>`), so the
    /// Obsidian format can be previewed without touching the real log.
    static func previewVault(at path: String, now: Date = Date()) {
        var evs: [BreakEvent] = []
        let cal = Calendar.current
        for d in 0..<14 {
            guard let day = cal.date(byAdding: .day, value: -d, to: now) else { continue }
            let base = cal.startOfDay(for: day)
            for e in 0..<(4 + d % 5) { evs.append(BreakEvent(at: base.addingTimeInterval(Double(9 * 3600 + e * 1200)), kind: "eye", outcome: "completed", seconds: 20)) }
            for m in 0..<(1 + d % 3) { evs.append(BreakEvent(at: base.addingTimeInterval(Double(10 * 3600 + m * 3000)), kind: "move", outcome: "completed", seconds: 60)) }
            if d % 2 == 0 { evs.append(BreakEvent(at: base.addingTimeInterval(11 * 3600), kind: "eye", outcome: "skipped", seconds: 0)) }
        }
        render(evs, base: URL(fileURLWithPath: path).appendingPathComponent("pace", isDirectory: true), rebuildAll: true, now: now)
    }

    private static func render(_ evs: [BreakEvent], base: URL, rebuildAll: Bool, now: Date) {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let byDay = Dictionary(grouping: evs) { dayKey($0.at) }
        if rebuildAll {
            for (day, list) in byDay { write(dayNote(day, list), to: base.appendingPathComponent("\(day).md")) }
        } else {
            let today = dayKey(now)
            write(dayNote(today, byDay[today] ?? []), to: base.appendingPathComponent("\(today).md"))
        }
        write(dashboard(byDay, now: now), to: base.appendingPathComponent("pace-dashboard.md"))
    }

    // MARK: markdown builders

    private static func dayNote(_ day: String, _ list: [BreakEvent]) -> String {
        let eye = list.filter { $0.kind == "eye" && $0.outcome == "completed" }.count
        let move = list.filter { $0.kind == "move" && $0.outcome == "completed" }.count
        let skipped = list.filter { $0.outcome == "skipped" }.count
        let minutes = list.filter { $0.outcome == "completed" }.reduce(0) { $0 + $1.seconds } / 60

        var s = """
        ---
        date: \(day)
        pace_eye: \(eye)
        pace_move: \(move)
        pace_skipped: \(skipped)
        pace_break_minutes: \(minutes)
        ---
        # pace · \(day)

        \(eye) eye · \(move) move · \(skipped) skipped · \(minutes) min resting

        | time | break | outcome |
        |------|-------|---------|

        """
        for e in list.sorted(by: { $0.at < $1.at }) {
            s += "| \(clockHM(e.at)) | \(e.kind) | \(e.outcome) |\n"
        }
        return s
    }

    private static func dashboard(_ byDay: [String: [BreakEvent]], now: Date) -> String {
        func stats(_ days: Int) -> String {
            let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: now))!
            let win = byDay.values.flatMap { $0 }.filter { $0.at >= cutoff }
            let completed = win.filter { $0.outcome == "completed" }.count
            let skipped = win.filter { $0.outcome == "skipped" }.count
            let minutes = win.filter { $0.outcome == "completed" }.reduce(0) { $0 + $1.seconds } / 60
            let perDay = Double(completed) / Double(days)
            let minPerDay = Double(minutes) / Double(days)
            let taken = completed + skipped > 0 ? Int(round(Double(completed) / Double(completed + skipped) * 100)) : 100
            return String(format: "%.1f breaks/day · %.0f min/day resting · %d%% taken", perDay, minPerDay, taken)
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

    private static func write(_ text: String, to url: URL) {
        try? text.data(using: .utf8)?.write(to: url)
    }
}
