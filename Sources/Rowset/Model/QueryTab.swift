import Foundation
import Observation

/// One tab on the right side.
@MainActor
@Observable
final class QueryTab: Identifiable {
    enum Kind: Hashable, Sendable {
        case table(schema: String, name: String)
        case sql

        var symbolName: String {
            switch self {
            case .table: "tablecells"
            case .sql: "terminal"
            }
        }
    }

    let id = UUID()
    let connectionID: UUID
    let kind: Kind
    let connectionName: String

    /// Table tab state.
    var filterText = ""
    /// What goes after ORDER BY. You may type any SQL here.
    var orderByText = ""
    /// The single column that the header arrow marks. It is `nil` when `orderByText` names more
    /// than one column or holds an expression.
    var sort: SortSpec? { SortSpec.parse(orderByText) }
    /// What the table header shows. It mirrors `sort`.
    var sortOrder: [ColumnComparator] {
        get { sort.map { [ColumnComparator(columnName: $0.column, order: $0.ascending ? .forward : .reverse)] } ?? [] }
        set { orderByText = newValue.first?.sortSpec.text ?? "" }
    }
    var rowLimit: Int
    /// The columns from the catalog. They fill the header when a query returns no row.
    var knownColumns: [ResultColumn] = []

    /// SQL tab state.
    var sqlText = ""

    /// Shared state.
    var rowLimitText: String
    /// The block of cells you picked. Its focus is the cell the value pane shows.
    var selection: CellSelection?

    var selectedCell: CellAddress? { selection?.focus }
    /// A column to scroll to. The grid clears it once it jumped there.
    var revealColumn: String?

    // MARK: - Editing

    /// The columns of the primary key. An empty list means this table cannot be edited.
    var primaryKey: [String] = []
    /// The changes you made but have not sent. The grid marks these cells.
    var edits: [CellAddress: String?] = [:]

    /// True when a row can be found again by its key, which an UPDATE needs.
    var isEditable: Bool {
        if case .table = kind { return !primaryKey.isEmpty }
        return false
    }

    var hasEdits: Bool { !edits.isEmpty }

    /// The text a cell shows now: the edit if you made one, else what the server sent.
    func pendingText(at address: CellAddress) -> String? {
        edits[address] ?? nil
    }

    func isEdited(_ address: CellAddress) -> Bool {
        edits.index(forKey: address) != nil
    }

    func setEdit(_ value: String?, at address: CellAddress) {
        guard let original = result?.value(at: address) else { return }
        let originalText: String? = original.isNull ? nil : original.text

        // An edit back to the original value is no edit at all.
        if value == originalText {
            edits.removeValue(forKey: address)
        } else {
            edits[address] = value
        }
    }

    func discardEdits() {
        edits.removeAll()
    }
    var result: ResultSet?
    var errorText: String?
    var isRunning = false
    var lastStatement = ""

    init(connectionID: UUID, connectionName: String, kind: Kind, rowLimit: Int) {
        self.connectionID = connectionID
        self.kind = kind
        self.connectionName = connectionName
        self.rowLimit = rowLimit
        self.rowLimitText = String(rowLimit)
    }

    /// The column names of this table. The filter field completes against these.
    var completionNames: [String] {
        let source = knownColumns.isEmpty ? (result?.columns ?? []) : knownColumns
        return source.map(\.name)
    }

    /// An example filter that names a real column of this table.
    var filterPlaceholder: String {
        let source = knownColumns.isEmpty ? (result?.columns ?? []) : knownColumns
        guard let column = FilterExample.pick(from: source) else { return "column = 'value'" }
        return FilterExample.text(for: column)
    }

    /// An example sort that names a real column of this table.
    var orderByPlaceholder: String {
        guard let first = completionNames.first else { return "column DESC" }
        return "\(first) DESC"
    }

    /// The value the inspector shows.
    var selectedValue: DisplayValue? {
        guard let selectedCell, let result else { return nil }
        return result.value(at: selectedCell)
    }

    var selectedColumn: ResultColumn? {
        guard let selectedCell, let result else { return nil }
        return result.column(id: selectedCell.columnID)
    }

    /// What to write into the session file.
    var state: TabState {
        var schema: String?
        var table: String?
        if case .table(let s, let name) = kind {
            schema = s
            table = name
        }
        return TabState(
            bookmarkID: connectionID,
            schema: schema,
            table: table,
            filterText: filterText,
            orderByText: orderByText,
            sqlText: sqlText,
            rowLimit: rowLimit)
    }

    var title: String {
        switch kind {
        case .table(_, let name): name
        case .sql: "Query"
        }
    }

    var subtitle: String {
        switch kind {
        case .table(let schema, _): "\(schema) — \(connectionName)"
        case .sql: connectionName
        }
    }
}
