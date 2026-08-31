import SwiftUI

/// Shows one whole row, every column under the one before it.
///
/// A wide table means scrolling sideways to read a single row. The space bar opens this instead,
/// the way the Finder opens a file, and the arrow keys walk the rows.
struct RowInspectorSheet: View {
    let result: ResultSet
    @Binding var rowID: Int?
    let onClose: () -> Void

    private var index: Int? {
        guard let rowID else { return nil }
        return result.rows.firstIndex { $0.id == rowID }
    }

    private var row: ResultRow? {
        guard let index else { return nil }
        return result.rows[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            columns
            Divider()
            footer
        }
        .frame(width: 620, height: 520)
        // A hidden button, because onKeyPress asks for focus and a sheet gives none by itself.
        // A shortcut needs no focus at all.
        .background {
            Button("", action: onClose)
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(.secondary)
            Text(position)
                .font(.headline)
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var position: String {
        guard let index else { return "No row" }
        return "Row \(index + 1) of \(result.rows.count)"
    }

    @ViewBuilder
    private var columns: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(result.columns) { column in
                        RowInspectorLine(column: column, value: row.value(at: column.id))
                        Divider()
                    }
                }
                .padding(.vertical, 4)
            }
        } else {
            Text("No row")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled((index ?? 0) <= 0)

            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled((index ?? 0) >= result.rows.count - 1)

            Text("The arrow keys walk the rows")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let row {
                Button("Copy Row") {
                    Clipboard.writeTable(
                        [result.columns.map(\.name), result.line(for: row).components(
                            separatedBy: "\t")],
                        hasHeader: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func step(_ offset: Int) {
        guard let index else { return }
        let next = index + offset
        guard result.rows.indices.contains(next) else { return }
        rowID = result.rows[next].id
    }
}

/// One column of the row, its name over its value.
private struct RowInspectorLine: View {
    let column: ResultColumn
    let value: DisplayValue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(column.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(column.typeName.lowercased())
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 170, alignment: .trailing)

            Text(value.isNull ? "NULL" : value.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(value.isNull ? .secondary : .primary)
                .italic(value.isNull)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
