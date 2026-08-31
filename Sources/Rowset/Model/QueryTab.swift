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
    var sort: SortSpec?
    /// What the table header shows. It mirrors `sort`.
    var sortOrder: [ColumnComparator] = []
    var rowLimit: Int
    /// The columns from the catalog. They fill the header when a query returns no row.
    var knownColumns: [ResultColumn] = []

    /// SQL tab state.
    var sqlText = ""

    /// Shared state.
    var rowLimitText: String
    var selectedCell: CellAddress?
    var isInspectorVisible = true
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

    /// The value the inspector shows.
    var selectedValue: DisplayValue? {
        guard let selectedCell, let result else { return nil }
        return result.value(at: selectedCell)
    }

    var selectedColumn: ResultColumn? {
        guard let selectedCell, let result else { return nil }
        return result.column(id: selectedCell.columnID)
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
