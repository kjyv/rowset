import SwiftUI

/// Shows the statements of an edit and waits for your word.
///
/// Nothing reaches the server before you have read this. The sheet is the only path from an edit
/// to a write, so a change can never leave by accident.
struct SQLPreviewSheet: View {
    let write: PendingWrite
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Review before it runs", systemImage: "pencil.and.list.clipboard")
                .font(.headline)

            Text(summary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(write.sql)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 160, maxHeight: 320)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Label(
                "Every statement runs in one transaction. If any of them matches anything but "
                    + "one row, the whole batch rolls back.",
                systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Copy SQL") { Clipboard.write(write.sql) }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: onRun)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var summary: String {
        let cells = write.cellCount == 1 ? "1 cell" : "\(write.cellCount) cells"
        let rows = write.rowCount == 1 ? "1 row" : "\(write.rowCount) rows"
        return "\(cells) in \(rows)."
    }
}
