import Charts
import SwiftUI

struct DayCount: Identifiable {
    let id = UUID()
    let day: Date
    let eye: Int
    let move: Int
    var total: Int { eye + move }
}

struct StatsSummary {
    let days: [DayCount]
    let todayTotal: Int
    let avg7: Double
    let streak: Int
    let eye30: Int
    let move30: Int
}

/// The glanceable in-app view: three tiles, a stacked per-day bar chart, and an
/// eye-vs-move donut. Native Swift Charts, so it matches the system look. The
/// Obsidian export stays for long-range tracking; this is for the quick glance.
struct StatsView: View {
    let s: StatsSummary

    private let eyeColor = Color.teal
    private let moveColor = Color.orange

    var body: some View {
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
