import AppKit
import Charts
import SwiftUI

/// The glanceable in-app view: three tiles, a stacked per-day bar chart, and an
/// eye-vs-move donut. Native Swift Charts, so it matches the system look. The
/// Obsidian export stays for long-range tracking; this is for the quick glance.
struct StatsView: View {
    let s: StatsSummary

    private let eyeColor = Color.teal
    private let moveColor = Color.orange

    private let debtColor = Color.indigo

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("pace").font(.title2.bold())

            HStack(spacing: 10) {
                tile("Today", "\(s.todayTotal)")
                tile("7-day avg", String(format: "%.1f", s.avg7))
                tile("Streak", "\(s.streak)d")
            }

            Text("Breaks per day").font(.headline)
            Chart(s.days) { d in
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Breaks", d.eye))
                    .foregroundStyle(by: .value("Kind", "Eye"))
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Breaks", d.move))
                    .foregroundStyle(by: .value("Kind", "Move"))
            }
            .chartForegroundStyleScale(["Eye": eyeColor, "Move": moveColor])
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 3)) { AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .frame(height: 170)

            putOffPanel

            callHeldPanel

            Text("Eye vs move (30 days)").font(.headline)
            if s.eye30 + s.move30 == 0 {
                Text("No breaks logged yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    SectorMark(angle: .value("Eye", s.eye30), innerRadius: .ratio(0.6))
                        .foregroundStyle(eyeColor)
                    SectorMark(angle: .value("Move", s.move30), innerRadius: .ratio(0.6))
                        .foregroundStyle(moveColor)
                }
                .frame(height: 130)
                HStack(spacing: 16) {
                    legend("Eye", eyeColor, s.eye30)
                    legend("Move", moveColor, s.move30)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        }
    }

    /// Putting a break off costs time, and this is the bill. Two numbers together
    /// on purpose: the presses say how often the answer was "not yet", the minutes
    /// say what that bought. Either one alone reads as harmless — three taps is
    /// nothing, and a stretch past due is nothing — and the pair doesn't.
    private var putOffPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Putting breaks off").font(.headline)

            HStack(spacing: 10) {
                tile("Past due today", mins(s.overdueToday))
                tile("Put off today", "\(s.putOffsToday)×")
                tile("First time", s.split.total > 0 ? "\(s.split.firstPct)%" : "–")
            }

            if s.putOffsWeek == 0 && s.overdueWeek == 0 {
                Text("Nothing put off in the last 7 days.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Chart(Array(s.days.suffix(7))) { d in
                    BarMark(x: .value("Day", d.day, unit: .day),
                            y: .value("Past due (min)", d.overdueMin))
                        .foregroundStyle(debtColor)
                        .annotation(position: .top, spacing: 2) {
                            if d.putOffs > 0 {
                                Text("\(d.putOffs)×").font(.caption.weight(.semibold))
                            }
                        }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                .chartYAxisLabel("min past due")
                .frame(height: 150)

                Text(trend).font(.callout)
                if s.split.total > 0 {
                    Text("Taken first time \(s.split.first) · after one extension \(s.split.once) · after two or more \(s.split.more)")
                        .font(.callout)
                }
            }
        }
    }

    /// What calls cost you. Two bars per day rather than one stacked pair, because
    /// the two overlap in real time — the same hour on a call is an hour without an
    /// eye rest *and* an hour in the chair — so stacking them would draw a total that
    /// doesn't exist. Side by side they read as what they are: two views of the same
    /// call time, each answering a different question.
    private var callHeldPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Held by calls").font(.headline)

            if s.callEyeWeek == 0 && s.callMoveWeek == 0 {
                Text("No calls have held a break off in the last 7 days.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    tile("No eye rest today", mins(s.callEyeToday))
                    tile("No moving today", mins(s.callMoveToday))
                }

                Chart(Array(s.days.suffix(7))) { d in
                    BarMark(x: .value("Day", d.day, unit: .day),
                            y: .value("On calls (min)", d.callEyeMin))
                        .foregroundStyle(by: .value("Held off", "Eye rest"))  // same teal/orange as

                        .position(by: .value("Held off", "Eye rest"))
                    BarMark(x: .value("Day", d.day, unit: .day),
                            y: .value("On calls (min)", d.callMoveMin))
                        .foregroundStyle(by: .value("Held off", "Moving"))
                        .position(by: .value("Held off", "Moving"))
                }
                .chartForegroundStyleScale(["Eye rest": eyeColor, "Moving": moveColor])  // everywhere else
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                .chartYAxisLabel("min on calls")
                .frame(height: 150)

                Text(callTrend).font(.callout)
            }
        }
    }

    /// The week's call cost in words, averaged over the days that actually had
    /// calls. Spreading it over seven would divide a heavy Tuesday by a quiet
    /// weekend and report a number no day resembled.
    private var callTrend: String {
        let base = "Last 7 days: \(mins(s.callEyeWeek)) on calls without an eye rest, "
            + "\(mins(s.callMoveWeek)) without moving."
        guard s.callDaysWeek > 0 else { return base }
        let perDay = s.callMoveWeek / s.callDaysWeek
        return base + " Across \(s.callDaysWeek) day\(s.callDaysWeek == 1 ? "" : "s") with calls, "
            + "that's \(mins(perDay)) a day sitting still."
    }

    /// This week against the one before, in words. The comparison is the point:
    /// a single day's number says nothing about whether the habit is moving.
    private var trend: String {
        let now = "Last 7 days: \(mins(s.overdueWeek)) past due, put off \(s.putOffsWeek)×."
        guard s.overduePrevWeek > 0 || s.putOffsPrevWeek > 0 else { return now }
        let delta = s.overdueWeek - s.overduePrevWeek
        let direction = delta == 0 ? "level with" : (delta < 0 ? "down \(mins(-delta)) on" : "up \(mins(delta)) on")
        return "\(now) That's \(direction) the week before (\(mins(s.overduePrevWeek)), \(s.putOffsPrevWeek)×)."
    }

    private func mins(_ seconds: Int) -> String {
        let m = seconds / 60
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func legend(_ label: String, _ color: Color, _ n: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text("\(label) \(n)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// `pace --stats-preview <path>`: render the stats window offscreen to a PNG.
/// The window is the deliverable here, and this is how it gets reviewed without
/// opening it over whatever you're doing — same idea as `--make-menuicon`.
enum StatsPreview {
    static func write(to path: String, s: StatsSummary, height: Int = 900) -> Bool {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: StatsView(s: s))
        host.frame = NSRect(x: 0, y: 0, width: 460, height: CGFloat(height))
        host.layoutSubtreeIfNeeded()
        // Charts lay out on the next run-loop pass, so an immediate cacheDisplay
        // catches an empty plot. One turn of the loop is enough.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
