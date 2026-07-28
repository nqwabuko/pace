import Foundation

/// What a typed command resolves to. `break…` schedules a one-off break;
/// `pause…` suppresses all breaks. Time is either a duration from now or an
/// absolute clock time (next occurrence).
enum Command: Equatable {
    case breakAfter(TimeInterval, BreakKind)
    case breakAt(Date, BreakKind)
    case pauseFor(TimeInterval)
    case pauseUntil(Date)

    var human: String {
        switch self {
        case .breakAfter(let t, let k): return "\(k.label) break in \(fuzzy(t))"
        case .breakAt(let d, let k):    return "\(k.label) break at \(hm(d))"
        case .pauseFor(let t):          return "paused for \(fuzzy(t))"
        case .pauseUntil(let d):        return "paused until \(hm(d))"
        }
    }
}

/// A deterministic natural-language time parser, in the spirit of Horo /
/// Hourglass and of `detell.py`: a small set of rules over the text, no
/// dependencies. `break @10am`, `pause 1h`, `eye break in 20m`, `90s`, `1:30`.
///
/// Decision rule (from Hourglass): am/pm, noon/midnight, or a leading `@` means
/// an absolute time; a bare number or duration units mean a countdown.
enum TimeParser {
    enum When { case after(TimeInterval); case at(Date) }

    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> Command? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        var isPause = false
        var kind: BreakKind = .move          // "a break" defaults to a movement break
        var rest: [String] = []
        for tok in s.split(separator: " ").map(String.init) {
            switch tok {
            case "pause", "snooze", "mute", "quiet", "dnd", "hold":  isPause = true
            case "break", "rest":                                    break        // schedule a break
            case "eye", "eyes":                                      kind = .eye
            case "move", "moving", "movement", "stretch", "body":    kind = .move
            case "in", "for", "until", "till", "til", "at",
                 "a", "an", "the", "take", "me":                     break        // filler
            default:                                                 rest.append(tok)
            }
        }

        guard let when = parseWhen(rest.joined(separator: " "), now: now, calendar: calendar) else { return nil }
        switch (isPause, when) {
        case (true,  .after(let t)): return .pauseFor(t)
        case (true,  .at(let d)):    return .pauseUntil(d)
        case (false, .after(let t)): return .breakAfter(t, kind)
        case (false, .at(let d)):    return .breakAt(d, kind)
        }
    }

    // MARK: pieces

    static func parseWhen(_ expr: String, now: Date, calendar: Calendar) -> When? {
        var t = expr.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }

        let hadAt = t.hasPrefix("@")
        if hadAt { t.removeFirst(); t = t.trimmingCharacters(in: .whitespaces) }

        if t == "noon"     { return .at(nextOccurrence(hour: 12, minute: 0, now: now, cal: calendar)) }
        if t == "midnight" { return .at(nextOccurrence(hour: 0, minute: 0, now: now, cal: calendar)) }

        let hasAMPM = t.contains("am") || t.contains("pm")
        if hadAt || hasAMPM, let d = parseClock(t, now: now, cal: calendar) { return .at(d) }

        if let secs = parseDuration(t) { return .after(secs) }
        return nil
    }

    static func parseClock(_ s0: String, now: Date, cal: Calendar) -> Date? {
        var s = s0.replacingOccurrences(of: " ", with: "")
        var ap: String?
        if s.hasSuffix("am") { ap = "am"; s.removeLast(2) }
        else if s.hasSuffix("pm") { ap = "pm"; s.removeLast(2) }

        guard let g = groups("^(\\d{1,2})(?::(\\d{1,2}))?$", s), let raw = g[1], var hour = Int(raw) else { return nil }
        let minute = g[2].flatMap { Int($0) } ?? 0
        guard hour <= 23, minute <= 59 else { return nil }
        if ap == "pm", hour < 12 { hour += 12 }
        if ap == "am", hour == 12 { hour = 0 }
        return nextOccurrence(hour: hour, minute: minute, now: now, cal: cal)
    }

    /// Durations: `20m`, `1h 15m`, `1.5h`, `90s`, bare `20` (minutes), and the
    /// colon forms `m:ss` / `h:mm:ss`.
    static func parseDuration(_ s0: String) -> TimeInterval? {
        let s = s0.replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }

        if let g = groups("^(\\d{1,2}):(\\d{1,2})(?::(\\d{1,2}))?$", s),
           let a = g[1].flatMap({ Int($0) }), let b = g[2].flatMap({ Int($0) }) {
            if let cS = g[3], let c = Int(cS) { return TimeInterval(a * 3600 + b * 60 + c) }
            return TimeInterval(a * 60 + b)
        }

        guard let re = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)([a-z]+)?") else { return nil }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var total = 0.0, covered = 0
        for m in matches {
            covered += m.range.length
            guard let num = Double(ns.substring(with: m.range(at: 1))) else { return nil }
            let uR = m.range(at: 2)
            let unit = uR.location == NSNotFound ? "" : ns.substring(with: uR)
            let mult: Double
            switch unit {
            case "", "m", "min", "mins", "minute", "minutes": mult = 60
            case "h", "hr", "hrs", "hour", "hours":           mult = 3600
            case "s", "sec", "secs", "second", "seconds":     mult = 1
            case "d", "day", "days":                          mult = 86400
            default: return nil                                // unknown unit → not a duration
            }
            total += num * mult
        }
        guard covered == ns.length, total > 0 else { return nil }   // whole string must be time
        return total
    }

    // MARK: helpers

    static func nextOccurrence(hour: Int, minute: Int, now: Date, cal: Calendar) -> Date {
        var c = cal.dateComponents([.year, .month, .day], from: now)
        c.hour = hour; c.minute = minute; c.second = 0
        guard var d = cal.date(from: c) else { return now }
        if d <= now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }

    private static func groups(_ pattern: String, _ s: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        let ns = s as NSString
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
}

// Shared small formatters.
func fuzzy(_ t: TimeInterval) -> String {
    let s = Int(t.rounded()), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    if m > 0 { return sec > 0 ? "\(m)m \(sec)s" : "\(m)m" }
    return "\(sec)s"
}

func hm(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
}
