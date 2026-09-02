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
    /// A table tab turns into a console once, and stays one.
    private(set) var kind: Kind
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

    // MARK: - Pages

    /// How many rows the page skips.
    var pageOffset = 0
    /// True when the server had at least one row more than this page holds.
    var hasMoreRows = false
    /// How many rows the filter matches. It stays `nil` until a count runs.
    var totalRows: Int?
    var isCounting = false
    /// The statement the page on screen belongs to.
    ///
    /// A console shows the widget only while a result stands on a statement it could page. When
    /// you change the statement, the page and the count start again.
    var pagedStatement: String?

    /// The rows this page shows, as `12-36`, or `0` for an empty page.
    var pageRange: String {
        let count = result?.rows.count ?? 0
        guard count > 0 else { return "0" }
        return "\(pageOffset + 1)-\(pageOffset + count)"
    }

    /// The number of rows, or the number seen so far with a plus after it.
    ///
    /// The query asks for one row more than the page holds. That extra row is what says there is
    /// more without a count, and it costs nothing.
    var totalDescription: String {
        if let totalRows { return "\(totalRows)" }
        let seen = pageOffset + (result?.rows.count ?? 0)
        return hasMoreRows ? "\(seen)+" : "\(seen)"
    }

    var isFirstPage: Bool { pageOffset == 0 }

    /// The offset of the last page, once the count is known.
    var lastPageOffset: Int? {
        guard let totalRows, totalRows > 0 else { return nil }
        return ((totalRows - 1) / max(1, rowLimit)) * max(1, rowLimit)
    }

    var isLastPage: Bool {
        if let lastPageOffset { return pageOffset >= lastPageOffset }
        return !hasMoreRows
    }

    /// True when the widget belongs on screen.
    var showsPageBar: Bool {
        guard result != nil else { return false }
        switch kind {
        case .table: return true
        case .sql: return pagedStatement != nil
        }
    }

    /// Puts the paging back to the first page and forgets the count.
    ///
    /// A new filter or a new sort makes both wrong, so neither may be carried over.
    func resetPaging() {
        pageOffset = 0
        hasMoreRows = false
        totalRows = nil
        pagedStatement = nil
    }

    /// SQL tab state.
    var sqlText = ""
    /// Where the caret sits in the editor. It decides which statement runs.
    var sqlCaret = 0
    /// The buffer this console shows. Its text is kept per connection.
    var bufferID: UUID?


    var sqlStatements: [SQLStatement] { SQLStatementSplitter.statements(in: sqlText) }

    /// The statement the caret is in, which is what the Run button sends.
    var currentStatement: SQLStatement? {
        SQLStatementSplitter.statement(at: sqlCaret, in: sqlStatements)
    }

    /// Shared state.
    /// The block of cells you picked. Its focus is the cell the value pane shows.
    var selection: CellSelection?

    var selectedCell: CellAddress? { selection?.focus }
    /// A column to scroll to. The grid clears it once it jumped there.
    var revealColumn: String?
    /// The row the whole row view shows. `nil` keeps it closed.
    var quickLookRow: Int?
    /// Counts the times something asked the value pane to start an edit.
    var paneEditRequests = 0

    // MARK: - Editing

    /// The columns of the primary key. An empty list means this table cannot be edited.
    var primaryKey: [String] = []
    /// What the catalog says about each column, by name.
    var columnInfo: [String: ColumnInfo] = [:]
    /// True when the grid shows the columns in the order of their names.
    var sortsColumnsByName = false

    /// The columns the query asks for, in the order the grid shows them.
    ///
    /// An empty list means `SELECT *`, which gives the order of the table.
    var selectedColumnNames: [String] {
        guard sortsColumnsByName else { return [] }
        return knownColumns
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// True when the server can name the size of a value without reading it.
    ///
    /// Only Postgres can. A SQLite file is on this machine, so nothing in it is worth leaving
    /// behind, and it has no `pg_column_size` to ask with either.
    var measuresValueSize = true

    /// True when the query may leave a large value on the server.
    ///
    /// It needs a key. Without one there is no way to ask for the rest of a row, so the whole
    /// value has to come with the grid.
    var cutsLargeValues: Bool {
        measuresValueSize && !primaryKey.isEmpty && knownColumns.contains { cuts($0.name) }
    }

    /// True when the grid asks for the size of this column and not for its value.
    ///
    /// A key column is never cut. Its value is what finds the row again, both to fetch the rest
    /// of a page and to open one row on a click. A key of type `text` or of an unbounded
    /// `varchar` counts as large by type, so this rule is what keeps such a table usable.
    func cuts(_ name: String) -> Bool {
        columnInfo[name]?.isLarge == true && !primaryKey.contains(name)
    }

    /// The select list of the grid query.
    ///
    /// A large column asks for its size and never for its value. Every other column asks for
    /// itself.
    var selectExpressions: [String] {
        let names = selectedColumnNames.isEmpty ? knownColumns.map(\.name) : selectedColumnNames
        guard cutsLargeValues else {
            return selectedColumnNames.isEmpty ? [] : names.map(SQLBuilder.quoteIdentifier)
        }

        return names.map { name in
            cuts(name) ? SQLBuilder.sizeOfColumn(name) : SQLBuilder.quoteIdentifier(name)
        }
    }

    /// The bytes one page may read out of the value store.
    ///
    /// Only a value too large for its row costs a second lookup, so only those bytes count here.
    /// A quarter of a megabyte of them takes about a second on a cold table.
    static let pageByteBudget = 256 * 1024

    /// Turns the size the server sent into a stand-in the grid can show.
    ///
    /// A large column comes back as a number of bytes. A NULL value has no size, so it stays a
    /// NULL. Everything else becomes a placeholder that says how large the value is, and asks
    /// for the whole row the moment you touch it.
    ///
    /// It gives back the columns this page can afford to read after all, cheapest first, until
    /// the budget is spent. The catalog cannot answer that: `pg_stats` reports an average of
    /// twenty bytes for a column whose values run to fifty kilobytes. Only the page itself knows.
    @discardableResult
    func markCutValues(in result: inout ResultSet) -> [String] {
        guard cutsLargeValues else { return [] }

        let largeColumns = result.columns.filter { cuts($0.name) }
        guard !largeColumns.isEmpty else { return [] }

        let largeIDs = Set(largeColumns.map(\.id))
        var total: [Int: Int] = [:]

        for rowIndex in result.rows.indices {
            for (valueIndex, column) in result.columns.enumerated()
            where largeIDs.contains(column.id) {
                guard valueIndex < result.rows[rowIndex].values.count else { continue }
                let value = result.rows[rowIndex].values[valueIndex]
                guard !value.isNull, let bytes = Int(value.text) else { continue }
                // A value that fits in its row comes with the row, so it costs nothing to read.
                if bytes > ColumnInfo.inlineValueSize {
                    total[column.id, default: 0] += bytes
                }
                result.rows[rowIndex].values[valueIndex] = .placeholder(bytes: bytes)
            }
        }

        // The cheapest column first, until the page has spent its budget. A column whose values
        // all fit in their rows costs nothing and always comes back.
        var left = Self.pageByteBudget
        var worthReading: [String] = []
        for column in largeColumns.sorted(by: { total[$0.id] ?? 0 < total[$1.id] ?? 0 }) {
            let bytes = total[column.id] ?? 0
            guard bytes <= left else { break }
            left -= bytes
            worthReading.append(column.name)
        }
        return worthReading
    }

    /// True when this cell holds only the start of its value.
    func isCut(at address: CellAddress) -> Bool {
        result?.value(at: address)?.isCut ?? false
    }
    /// The changes you made but have not sent. The grid marks these cells.
    var edits: [CellAddress: String?] = [:]

    /// True when a row can be found again by its key, which an UPDATE needs.
    ///
    /// A console is never editable. Its statement may join two tables or rename a column, and an
    /// UPDATE built from such a result would hit the wrong rows.
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

    /// What the catalog says about the column of a cell.
    func info(at address: CellAddress) -> ColumnInfo? {
        guard let column = result?.column(id: address.columnID) else { return nil }
        return columnInfo[column.name]
    }

    /// True when the column of this cell takes NULL.
    func acceptsNull(at address: CellAddress) -> Bool {
        info(at: address)?.isNullable ?? false
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
    }

    /// Whether this tab shows the value pane under its grid.
    ///
    /// A new tab starts without it. The pane takes room the rows want, and a double click on a
    /// cell, Shift-Return, or the button in the bar brings it when you need it.
    ///
    /// It belongs to the tab and not to the window, so one tab does not open the pane of another.
    var showsValuePane = false

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
            bufferID: bufferID,
            showsValuePane: showsValuePane,
            rowLimit: rowLimit)
    }

    /// Turns this tab into a console. A tab makes that move once and does not come back, because
    /// the statement may end up showing another table than the one it started on.
    func becomeConsole() {
        kind = .sql
        primaryKey = []
        discardEdits()
    }

    var title: String {
        switch kind {
        case .table(_, let name): name
        case .sql: "Console"
        }
    }

    var subtitle: String {
        switch kind {
        case .table(let schema, _): "\(schema) — \(connectionName)"
        case .sql: connectionName
        }
    }
}
