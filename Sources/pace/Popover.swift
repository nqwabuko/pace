import AppKit
import SwiftUI

/// State + callbacks for the menu-bar popover. AppDelegate owns it, updates
/// `statusText`/`detailText` each tick, and handles submits.
final class PopoverModel: ObservableObject {
    @Published var statusText = ""
    @Published var detailText = ""
    @Published var feedback = ""
    var onSubmit: (String) -> Void = { _ in }
    var onEyeNow: () -> Void = {}
    var onMoveNow: () -> Void = {}
    var onPauseHour: () -> Void = {}
    var onResume: () -> Void = {}
    var onStats: () -> Void = {}
    var onFeedback: () -> Void = {}
}

/// The little Horo-style panel: a line of status, a text field you type times
/// into, and a few quick buttons. Right-clicking the menu-bar icon still opens
/// the full settings menu.
struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.statusText).font(.headline)
            if !model.detailText.isEmpty {
                Text(model.detailText).font(.caption).foregroundStyle(.secondary)
            }

            TextField("break @10am · pause 1h · 20m", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }

            if !model.feedback.isEmpty {
                Text(model.feedback).font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Eyes") { model.onEyeNow() }
                Button("Move") { model.onMoveNow() }
                Spacer()
                Button("Pause 1h") { model.onPauseHour() }
                Button("Resume") { model.onResume() }
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                Button { model.onStats() } label: { Label("Stats", systemImage: "chart.bar.fill") }
                Button { model.onFeedback() } label: { Label("Bug / idea", systemImage: "ladybug.fill") }
                Spacer()
            }
            .controlSize(.small)

            Text("Right-click the icon for settings")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { focused = true }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.onSubmit(t)
        text = ""
    }
}
