import SwiftUI

/// Small "log a bug or improvement" form. Hands the kind + note back to the
/// caller (which writes it via Feedback) and closes.
struct FeedbackView: View {
    let onSubmit: (FeedbackKind, String) -> Void
    let onClose: () -> Void

    @State private var kind: FeedbackKind = .bug
    @State private var note = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Log a bug or improvement").font(.headline)

            Picker("", selection: $kind) {
                ForEach(FeedbackKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextEditor(text: $note)
                .font(.body)
                .frame(height: 120)
                .focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Text("Saved locally\(isVaultLinked ? " and to your vault" : "").")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onClose)
                Button("Save") { onSubmit(kind, note); onClose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private var isVaultLinked: Bool { !Settings.vaultPath.isEmpty }
}
