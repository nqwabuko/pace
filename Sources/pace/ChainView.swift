import SwiftUI

/// The chain across the top of the card: two states and one labelled arrow.
///
/// It is drawn as a transition rather than as a row of beads because that is
/// what it is — putting a break off is something that happened *between* two
/// states, not a third state you were in. Three coloured discs made it a traffic
/// light; this leaves the card two quiet glyphs, one plain word and a line.
///
/// Hierarchy does all the work, and there is no colour in it at all. Where you
/// were and what happened are quiet, and now is the heaviest mark in the row,
/// because now is the only part you have to act on.
struct ChainView: View {
    let model: Card.Model

    var body: some View {
        HStack(spacing: 10) {
            end(symbol: "checkmark", caption: "rested", loud: false)
            VStack(spacing: 3) {
                if let step = model.step {
                    // Plain, and the same weight as everything else in the row. The
                    // label is what happened, not an alarm: colouring it or leaning
                    // on it makes the card shout the one thing you already know.
                    Text(step.phrase)
                        .font(.system(size: 14))
                }
                Arrow()
                    .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(.secondary)
                    .frame(width: 104, height: 9)
            }
            .fixedSize()
            end(symbol: model.kind.glyph, caption: model.late ?? "now", loud: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
    }

    private func end(symbol: String, caption: String, loud: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: loud ? 21 : 15, weight: loud ? .bold : .medium))
                .frame(height: 24)
            Text(caption)
                .font(.system(size: 13, weight: loud ? .semibold : .regular))
        }
        .foregroundStyle(loud ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
        .frame(width: 84)
    }

    private var spoken: String {
        let step = model.step.map { ", then \($0.spoken)" } ?? ""
        return "This break: last rest\(step), then now" + (model.late.map { ", \($0)" } ?? "")
    }
}

/// A plain line with a head, drawn rather than typed so it keeps its weight at
/// any size and doesn't depend on a font having the glyph.
private struct Arrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y = r.midY
        p.move(to: CGPoint(x: r.minX, y: y))
        p.addLine(to: CGPoint(x: r.maxX, y: y))
        p.move(to: CGPoint(x: r.maxX - 5, y: y - 4.5))
        p.addLine(to: CGPoint(x: r.maxX, y: y))
        p.addLine(to: CGPoint(x: r.maxX - 5, y: y + 4.5))
        return p
    }
}

extension BreakKind {
    /// The break's own glyph, used wherever "this break" needs a mark: the end of
    /// the chain today, the menu's history tomorrow.
    var glyph: String { self == .eye ? "eye.fill" : "figure.walk" }
}
