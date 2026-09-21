import AppKit
import SwiftUI

/// The action log: what pace did, in order, and what became of it.
///
/// Everything on the row is text. The tone symbol is a second cue for scanning
/// and carries nothing on its own, for the same reason the glyph has a
/// monochrome path: a reading you can only get from a colour is a reading some
/// people never get. Nothing here is greyed either — every line on this window
/// is data, and data that is hard to read is data you stop checking.
struct ActivityView: View {
    /// One value in, the whole window out. Every sentence on screen was decided
    /// in `Activity`, which is where it can be checked; this file only lays them
    /// out. The view holds no clock, reads no log and asks macOS nothing.
    let log: Activity.Log

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What pace has done").font(.title2.bold())

                header

                if log.days.isEmpty {
                    Text("Nothing logged in the last week.").font(.body)
                } else {
                    ForEach(log.days) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(day.title).font(.headline)
                            ForEach(day.rows) { row($0) }
                        }
                    }
                }

                Text(Activity.Log.focusCaveat)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(width: 480, alignment: .leading)
        }
    }

    /// The two facts you came for, before any scrolling: can a nudge reach the
    /// desktop at all, and did today's actually go.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Notifications:").font(.body.weight(.semibold))
                Text(log.permission.human).font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(log.tally.human).font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }

    private func row(_ r: Activity.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Activity.clock(r.at))
                .font(.body.monospacedDigit())
                .frame(width: 44, alignment: .leading)
            Image(systemName: symbol(r.tone))
                .foregroundStyle(colour(r.tone))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.body)
                if !r.detail.isEmpty {
                    Text(r.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func symbol(_ t: Activity.Tone) -> String {
        switch t {
        case .rested: return "checkmark.circle.fill"
        case .sent:   return "bell.fill"
        case .missed: return "exclamationmark.triangle.fill"
        case .away:   return "figure.walk"
        }
    }

    private func colour(_ t: Activity.Tone) -> Color {
        switch t {
        case .rested: return .green
        case .sent:   return .teal
        case .missed: return .orange
        case .away:   return .primary
        }
    }
}

/// Render the window offscreen, the same way the stats window does, so the log
/// can be reviewed without a window landing over your work.
enum ActivityPreview {
    static func write(to path: String, view: ActivityView, height: Int = 900) -> Bool {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: CGFloat(height))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
