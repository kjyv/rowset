import SwiftUI

/// Tells the table which column the user clicked. The server does the sorting, so `compare`
/// never reorders anything here.
struct ColumnComparator: SortComparator, Hashable {
    var columnName: String
    var order: SortOrder = .forward

    func compare(_ lhs: ResultRow, _ rhs: ResultRow) -> ComparisonResult {
        .orderedSame
    }

    var sortSpec: SortSpec {
        SortSpec(column: columnName, ascending: order == .forward)
    }
}

/// The result grid. The columns come from the query, so the table builds them at run time.
struct ResultTableView: View {
    let result: ResultSet
    @Binding var sortOrder: [ColumnComparator]

    var body: some View {
        Table(result.rows, sortOrder: $sortOrder) {
            TableColumnForEach(result.columns) { column in
                TableColumn(column.name, sortUsing: ColumnComparator(columnName: column.name)) { row in
                    CellView(value: row.value(at: column.id))
                }
                .width(min: 60, ideal: 170)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .font(.system(size: 12, design: .monospaced))
    }
}

private struct CellView: View {
    let value: DisplayValue

    var body: some View {
        Text(value.isNull ? "NULL" : value.text)
            .foregroundStyle(color)
            .italic(value.isNull)
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .help(value.isNull ? "NULL" : value.text)
    }

    private var color: Color {
        if value.isNull { return .secondary }
        if value.isRaw { return .orange }
        return .primary
    }
}
