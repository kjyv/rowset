import Foundation
import Observation

/// Holds the live state of one bookmark: the session and the tree below it.
@MainActor
@Observable
final class ConnectionModel: Identifiable {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var isBusy: Bool { self == .connecting }
        var isConnected: Bool { self == .connected }
    }

    let id: UUID
    let bookmark: Bookmark

    var state: State = .disconnected
    /// Every table of the database. The sidebar filter searches this list.
    private(set) var allTables: [TableRef] = []
    private var didLoadAllTables = false
    private var isLoadingTables = false
    /// True when the sidebar shows the tree of this connection.
    var isExpanded = false
    var schemas: [TreeNode] = []
    /// Set when the AWS login expired. The view turns this into a sheet.
    var expiredLogin: AWSAuthError?

    private let session: any DatabaseSession

    init(bookmark: Bookmark) {
        self.id = bookmark.id
        self.bookmark = bookmark
        self.session = DatabaseSessionFactory.session(for: bookmark)
    }

    /// True when this connection can be asked for the size of a value without reading it.
    ///
    /// Postgres answers with `pg_column_size`, which reads the pointer and not the value beside
    /// the table. A SQLite file is on this machine, so nothing there is worth leaving behind.
    var measuresValueSize: Bool { bookmark.driver == .postgres }

    var driver: Driver { bookmark.driver }

    // MARK: - Connect

    func connect() async {
        guard !state.isBusy else { return }
        state = .connecting
        expiredLogin = nil
        schemas = []

        do {
            try await session.connect()
            try await loadSchemas()
            state = .connected
        } catch let error as AWSAuthError {
            if case .ssoExpired = error { expiredLogin = error }
            state = .failed(error.errorDescription ?? "\(error)")
        } catch {
            state = .failed(DatabaseErrorText.describe(error))
        }
    }

    func disconnect() async {
        await session.close()
        schemas = []
        allTables = []
        didLoadAllTables = false
        state = .disconnected
    }

    func refresh() async {
        guard state.isConnected else { return }
        schemas = []
        allTables = []
        didLoadAllTables = false
        do {
            try await loadSchemas()
        } catch {
            state = .failed(DatabaseErrorText.describe(error))
        }
    }

    // MARK: - Tree

    private func loadSchemas() async throws {
        let rows = try await session.queryStringsInBackground(CatalogQueries.schemas(bookmark.driver))
        schemas = rows.compactMap { row in
            guard let name = row.first else { return nil }
            return TreeNode(kind: .schema(name: name))
        }
    }

    /// Loads the children of one node the first time it opens.
    func loadChildren(of node: TreeNode) async {
        guard node.children == nil, !node.isLoading, node.kind.canHaveChildren else { return }
        node.isLoading = true
        node.loadError = nil
        defer { node.isLoading = false }

        do {
            switch node.kind {
            case .schema(let name):
                let rows = try await session.queryStringsInBackground(CatalogQueries.tables(bookmark.driver, schema: name))
                node.children = rows.compactMap { row in
                    guard row.count >= 2 else { return nil }
                    let isView = row[1].uppercased().contains("VIEW")
                    return TreeNode(
                        kind: isView
                            ? .view(schema: name, name: row[0])
                            : .table(schema: name, name: row[0]))
                }

            case .table(let schema, let name), .view(let schema, let name):
                node.children = Self.ordered(
                    try await columnNodes(schema: schema, table: name),
                    byName: node.sortsColumnsByName)

            case .column:
                node.children = []
            }
        } catch {
            node.loadError = DatabaseErrorText.describe(error)
        }
    }

    /// Puts the columns in the order the table asks for.
    ///
    /// Sorting by name used to replace the list, which threw the catalog order away and left no
    /// way back. Each column carries its position now, so both orders are always at hand.
    static func ordered(_ columns: [TreeNode], byName: Bool) -> [TreeNode] {
        guard byName else {
            return columns.sorted { $0.columnPosition < $1.columnPosition }
        }
        return columns.sorted {
            $0.kind.title.localizedStandardCompare($1.kind.title) == .orderedAscending
        }
    }

    /// Changes the order of the columns of one table, without asking the server again.
    func setColumnSorting(byName: Bool, on node: TreeNode) {
        node.sortsColumnsByName = byName
        guard let columns = node.children else { return }
        node.children = Self.ordered(columns, byName: byName)
    }

    private func columnNodes(schema: String, table: String) async throws -> [TreeNode] {
        let rows = try await session.queryStringsInBackground(CatalogQueries.columns(bookmark.driver, schema: schema, table: table))
        return rows.enumerated().compactMap { position, row in
            guard row.count >= 3 else { return nil }
            return TreeNode(kind: .column(
                schema: schema,
                table: table,
                name: row[0],
                type: row[1],
                nullable: row[2].uppercased() == "YES",
                position: position))
        }
    }

    /// What the catalog says about every column of one table.
    func columnDetails(schema: String, table: String) async -> [ColumnInfo] {
        guard let rows = try? await session.queryStringsInBackground(
            CatalogQueries.columns(bookmark.driver, schema: schema, table: table))
        else { return [] }
        return rows.compactMap { row in
            guard row.count >= 3 else { return nil }
            // The catalog reports no length limit as NULL, which the query maps to -1.
            let declared = row.count >= 4 ? (Int(row[3]) ?? -1) : -1
            return ColumnInfo(
                name: row[0],
                typeName: row[1],
                isNullable: row[2].uppercased() == "YES",
                maximumLength: declared < 0 ? nil : declared)
        }
    }

    /// Finds a tree row by its id, anywhere in the tree.
    func node(id: UUID) -> TreeNode? {
        var queue = schemas
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node.id == id { return node }
            queue.append(contentsOf: node.children ?? [])
        }
        return nil
    }

    // MARK: - Filter

    /// Reads every table of the database once. The sidebar filter needs the whole list, and the
    /// tree loads a schema only when you open it.
    func loadAllTables() async {
        guard state.isConnected, !didLoadAllTables, !isLoadingTables else { return }
        isLoadingTables = true
        defer { isLoadingTables = false }

        guard let rows = try? await session.queryStringsInBackground(CatalogQueries.allTables(bookmark.driver)) else { return }
        allTables = rows.compactMap { row in
            guard row.count >= 3 else { return nil }
            return TableRef(
                schema: row[0], name: row[1], isView: row[2].uppercased().contains("VIEW"))
        }
        didLoadAllTables = true
    }

    /// The tables whose name holds the text. A column name never matches.
    func tables(matching text: String) -> [TableRef] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return allTables.filter { $0.name.lowercased().contains(needle) }
    }

    // MARK: - Remembering the open rows

    /// The tree rows that are open now.
    var expandedPaths: [NodePath] {
        var paths: [NodePath] = []
        for schema in schemas where schema.isExpanded {
            guard case .schema(let schemaName) = schema.kind else { continue }
            paths.append(NodePath(schema: schemaName, table: nil))
            for child in schema.children ?? [] where child.isExpanded {
                switch child.kind {
                case .table(_, let name), .view(_, let name):
                    paths.append(NodePath(schema: schemaName, table: name))
                default:
                    break
                }
            }
        }
        return paths
    }

    /// Opens the rows that were open the last time, and loads what they need.
    func restoreExpansion(_ paths: [NodePath]) async {
        guard !paths.isEmpty else { return }

        for schemaNode in schemas {
            guard case .schema(let schemaName) = schemaNode.kind,
                  paths.contains(where: { $0.schema == schemaName })
            else { continue }

            schemaNode.isExpanded = true
            await loadChildren(of: schemaNode)

            let wantedTables = Set(paths.filter { $0.schema == schemaName }.compactMap(\.table))
            guard !wantedTables.isEmpty else { continue }

            for tableNode in schemaNode.children ?? [] {
                switch tableNode.kind {
                case .table(_, let name), .view(_, let name):
                    guard wantedTables.contains(name) else { continue }
                    tableNode.isExpanded = true
                    await loadChildren(of: tableNode)
                default:
                    break
                }
            }
        }
    }

    // MARK: - Queries

    func run(_ sql: String, limit: Int, expectedColumns: [ResultColumn] = []) async throws -> ResultSet {
        try await session.query(sql, maxRows: limit, expectedColumns: expectedColumns)
    }

    /// Runs statements in one transaction.
    func runTransaction(_ statements: [String]) async throws {
        try await session.runTransaction(statements)
    }

    /// Runs a statement away from the session connection. The row counts use this.
    func runInBackground(_ sql: String, limit: Int) async throws -> ResultSet {
        try await session.queryInBackground(sql, maxRows: limit, expectedColumns: [])
    }

    /// Asks the database to stop the statement that runs now.
    func cancelRunningQuery() async {
        await session.cancelRunningQuery()
    }
}
