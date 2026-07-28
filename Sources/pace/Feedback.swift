import Foundation

enum FeedbackKind: String, CaseIterable {
    case bug, idea
    var label: String { self == .bug ? "Bug" : "Improvement" }
}

/// A tiny local feedback log: a bug or improvement note, appended to a Markdown
/// file in Application Support (and mirrored into the Obsidian vault if one is
/// configured, so it shows up alongside the reports). Local only, no network.
enum Feedback {
    static let fileURL = Report.dir.appendingPathComponent("feedback.md")

    static func log(kind: FeedbackKind, note: String, mirrorVault: String? = nil, now: Date = Date()) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let line = "- **\(kind.label)** \(stamp(now)): \(trimmed.replacingOccurrences(of: "\n", with: " "))\n"

        append(line, to: fileURL, header: "# pace feedback\n\n")
        if let v = mirrorVault, !v.isEmpty {
            let vaultFile = Report.vaultBase(v).appendingPathComponent("feedback.md")
            try? FileManager.default.createDirectory(at: Report.vaultBase(v), withIntermediateDirectories: true)
            append(line, to: vaultFile, header: "# pace feedback\n\n")
        }
    }

    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()
    private static func stamp(_ d: Date) -> String { fmt.string(from: d) }

    private static func append(_ line: String, to url: URL, header: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path), let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data((header + line).utf8).write(to: url)
        }
    }
}
