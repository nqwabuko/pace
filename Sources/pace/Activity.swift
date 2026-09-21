import Foundation

/// The log as a list of things that happened, in words.
///
/// The stats window answers "how am I doing" over days. This answers a different
/// question, and the one the menu-bar glyph structurally cannot: **what did pace
/// actually do, and did any of it reach me?** A red head says a debt exists; it
/// cannot say whether you were asked to clear it and missed the ask, or were
/// never asked at all. That gap is widest exactly where it matters — during a
/// call, when the notification is the only channel and the menu bar is the one
/// thing you are not looking at.
///
/// Pure, all of it. `[BreakEvent]` plus a `Permission` plus a `now` go in, one
/// `Log` value comes out, and the window and the terminal are two renderings of
/// that same value — so they cannot tell you different stories. No clock of its
/// own, no disk, no AppKit, no notification centre: `--selftest` can assert what
/// a row says about a delivery with none of those present.
enum Activity {

    /// The leading mark on a row. It is never the only carrier of anything: every
    /// row says in words what it is, and the tone only makes a scan faster.
    enum Tone { case rested, sent, missed, away }

    struct Row: Identifiable, Equatable {
        let at: Date
        let title: String
        let detail: String
        let tone: Tone

        /// Derived from the event, not minted per build. A `UUID()` here would make
        /// two renderings of the same log unequal, which is exactly the property the
        /// tests lean on.
        var id: String { "\(at.timeIntervalSinceReferenceDate)-\(title)" }
    }

    struct Day: Identifiable, Equatable {
        var id: Date { day }
        let day: Date
        let title: String
        let rows: [Row]
    }

    /// Today's nudges, split by whether anything left the app. `unrecorded` is its
    /// own count and never folded into either side: rows written before pace
    /// tracked delivery cannot be claimed as sent, and calling them lost would be
    /// the same lie in the other direction.
    struct Tally: Equatable {
        var sent = 0
        var notSent = 0
        var unrecorded = 0
        var total: Int { sent + notSent + unrecorded }

        /// One line for the top. The count first, because that is the question, and
        /// only then how well it is known.
        var human: String {
            guard total > 0 else { return "No nudges during calls today." }
            let parts = ["\(total) nudge\(total == 1 ? "" : "s") during calls today"]
                + [sent > 0 ? "\(sent) sent to your desktop" : nil,
                   notSent > 0 ? "\(notSent) never left the app" : nil,
                   unrecorded > 0 ? "\(unrecorded) from before delivery was tracked" : nil].compactMap { $0 }
            return parts.joined(separator: " · ") + "."
        }
    }

    /// Everything either rendering needs, and nothing either has to work out for
    /// itself. Built once by `log`, drawn twice.
    struct Log: Equatable {
        let permission: Permission
        let tally: Tally
        let days: [Day]

        /// The caveat that keeps "sent" honest. It belongs to the value rather than
        /// to the window, because the terminal owes you the same warning.
        static let focusCaveat = "A sent banner can still be held back by a Focus mode. macOS tells apps nothing about that, so \"sent\" here means pace handed it over, never that you saw it."
    }

    // MARK: building it

    /// One event log into one readable log, newest first, grouped by day.
    static func log(_ events: [BreakEvent], now: Date, daysBack: Int = 7,
                    permission: Permission, calendar cal: Calendar = .current) -> Log {
        Log(permission: permission,
            tally: tally(events, on: now, calendar: cal),
            days: days(from: events, now: now, daysBack: daysBack, calendar: cal))
    }

    static func days(from events: [BreakEvent], now: Date, daysBack: Int = 7,
                     calendar cal: Calendar = .current) -> [Day] {
        let cutoff = cal.startOfDay(for: cal.date(byAdding: .day, value: -(daysBack - 1), to: now) ?? now)
        return Dictionary(grouping: events.filter { $0.at >= cutoff }) { cal.startOfDay(for: $0.at) }
            .map { day, evs in
                Day(day: day, title: dayTitle(day, now: now, calendar: cal),
                    rows: evs.sorted { $0.at > $1.at }.map(row))
            }
            .sorted { $0.day > $1.day }
    }

    static func tally(_ events: [BreakEvent], on day: Date, calendar cal: Calendar = .current) -> Tally {
        events
            .filter { $0.outcome == "nudged" && cal.isDate($0.at, inSameDayAs: day) }
            .reduce(into: Tally()) { t, e in
                switch e.delivery.flatMap(Delivery.init(rawValue:)) {
                case .some(let d) where d.sent: t.sent += 1
                case .some:                     t.notSent += 1
                case .none:                     t.unrecorded += 1
                }
            }
    }

    /// One event, in a sentence. The split is deliberate: the title is *what pace
    /// did*, the detail is *what it cost or what became of it*, so a scan down the
    /// left reads as a narrative and the right-hand half is only read when a line
    /// is worth stopping on.
    static func row(_ e: BreakEvent) -> Row {
        let kind = e.kind == "move" ? "Move" : "Eye"
        switch e.outcome {
        case "nudged":
            let sent = e.delivery.flatMap(Delivery.init(rawValue:))?.sent ?? false
            return Row(at: e.at,
                       title: "\(kind) nudge during a call",
                       detail: join([Delivery.describe(e.delivery), pastDue(e), callLine(e)]),
                       tone: sent ? .sent : .missed)

        case "completed":
            return Row(at: e.at,
                       title: "\(kind) break taken",
                       detail: join([e.seconds > 0 ? "rested \(dur(e.seconds))" : nil,
                                     pastDue(e), afterPutOffs(e), callLine(e)]),
                       tone: .rested)

        case "snoozed":
            return Row(at: e.at, title: "\(kind) break put off (+5 min)",
                       detail: join([pastDue(e), "the counter keeps climbing"]), tone: .missed)

        case "skipped":
            return Row(at: e.at, title: "\(kind) break skipped",
                       detail: join([pastDue(e), "quiet for 10 min, nothing credited"]), tone: .missed)

        case "interrupted":
            return Row(at: e.at, title: "\(kind) break cut short by a call",
                       detail: join([pastDue(e), "not a refusal — back in 2 min"]), tone: .missed)

        case "rested":
            return Row(at: e.at, title: "Away from the desk — counted as \(kind == "Eye" ? "an eye" : "a move") rest",
                       detail: join([e.seconds > 0 ? "away \(dur(e.seconds))" : nil, pastDue(e)]),
                       tone: .away)

        default:
            return Row(at: e.at, title: "\(kind) \(e.outcome)", detail: "", tone: .away)
        }
    }

    // MARK: the terminal rendering

    /// The same `Log` the window draws, as text. One value, two renderings.
    static func plainText(_ log: Log, calendar cal: Calendar = .current) -> String {
        let head: [String] = ["Notifications: \(log.permission.human)", log.tally.human]
        let body: [String] = log.days.isEmpty
            ? ["", "Nothing logged in that window."]
            : log.days.flatMap { day -> [String] in ["", day.title] + day.rows.map { line($0, cal) } }
        return (head + body + ["", Log.focusCaveat]).joined(separator: "\n")
    }

    private static func line(_ r: Row, _ cal: Calendar) -> String {
        let head = "  \(clock(r.at, calendar: cal))  \(r.title)"
        return r.detail.isEmpty ? head : head + "\n          \(r.detail)"
    }

    // MARK: wording

    private static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func pastDue(_ e: BreakEvent) -> String? {
        (e.overdueSec).flatMap { $0 > 0 ? "\(dur($0)) past due" : nil }
    }

    private static func afterPutOffs(_ e: BreakEvent) -> String? {
        (e.refusals).flatMap { $0 > 0 ? "after \($0) put-off\($0 == 1 ? "" : "s")" : nil }
    }

    private static func callLine(_ e: BreakEvent) -> String? {
        (e.callSec).flatMap { $0 > 0 ? "\(dur($0)) on calls since the last rest" : nil }
    }

    /// Durations a person reads at a glance, not a stopwatch's.
    static func dur(_ seconds: Int) -> String {
        switch seconds {
        case ..<60:      return "\(seconds)s"
        case ..<5400:    return "\(seconds / 60) min"
        case ..<86400:   return "\(seconds / 3600)h \(String(format: "%02dm", seconds / 60 % 60))"
        // A weekend away is a real row (it credits the rest that clears Friday's
        // debt), and "65h 00m" is a number you have to convert before you can read it.
        default:         return "\(seconds / 86400)d \(seconds % 86400 / 3600)h"
        }
    }

    static func clock(_ d: Date, calendar cal: Calendar = .current) -> String {
        format(d, "HH:mm", cal)
    }

    static func dayTitle(_ day: Date, now: Date, calendar cal: Calendar = .current) -> String {
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
        if cal.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = yesterday, cal.isDate(day, inSameDayAs: y) { return "Yesterday" }
        return format(day, "EEEE d MMMM", cal)
    }

    private static func format(_ d: Date, _ pattern: String, _ cal: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = pattern
        return f.string(from: d)
    }
}
