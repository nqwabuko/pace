import SwiftUI

/// A pair of googly eyes with pupils that jiggle: the little easter egg shown on
/// the break card. Original drawing (circles + a springy offset), nothing lifted.
/// Honours Reduce Motion by settling the pupils low and still.
struct GooglyEyesView: View {
    var eyeSize: CGFloat = 52
    @State private var offsets: [CGSize] = [.zero, .zero]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tick = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: eyeSize * 0.16) {
            eye(0)
            eye(1)
        }
        .onAppear { reduceMotion ? restLow() : wobble() }
        .onReceive(tick) { _ in if !reduceMotion { wobble() } }
    }

    private func eye(_ i: Int) -> some View {
        ZStack {
            Circle().stroke(lineWidth: eyeSize * 0.085)
            Circle()
                .frame(width: eyeSize * 0.42, height: eyeSize * 0.42)
                .offset(offsets[i])
        }
        .foregroundStyle(.primary)
        .frame(width: eyeSize, height: eyeSize)
    }

    private var maxOffset: CGFloat { eyeSize * 0.19 }

    private func wobble() {
        withAnimation(.interpolatingSpring(stiffness: 90, damping: 6)) {
            offsets = (0..<2).map { _ in
                let angle = Double.random(in: 0 ..< 2 * .pi)
                let dist = Double.random(in: 0.35 ... 1.0) * maxOffset
                return CGSize(width: cos(angle) * dist, height: sin(angle) * dist)
            }
        }
    }

    private func restLow() {
        offsets = [CGSize(width: 0, height: maxOffset), CGSize(width: 0, height: maxOffset)]
    }
}
