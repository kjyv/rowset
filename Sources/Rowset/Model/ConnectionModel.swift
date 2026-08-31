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

    private let session: PostgresSession

    init(bookmark: Bookmark) {
        self.id = bookmark.id
        self.bookmark = bookmark
        self.session = PostgresSession(bookmark: bookmark)
    }

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
        let rows = try await session.queryStrings(CatalogQueries.schemas)
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
                let rows = try await session.queryStrings(CatalogQueries.tables(schema: name))
                node.children = rows.compactMap { row in
                    guard row.count >= 2 else { return nil }
                    let isView = row[1].uppercased().contains("VIEW")
                    return TreeNode(
                        kind: isView
                            ? .view(schema: name, name: row[0])
                            : .table(schema: name, name: row[0]))
                }

            case .table(let schema, let name), .view(let schema, let name):
                node.children = try await columnNodes(schema: schema, table: name)

            case .column:
                node.children = []
            }
        } catch {
            node.loadError = DatabaseErrorText.describe(error)
        }
    }

    private func columnNodes(schema: String, table: String) async throws -> [TreeNode] {
        let rows = try await session.queryStrings(CatalogQueries.columns(schema: schema, table: table))
        return rows.compactMap { row in
            guard row.count >= 3 else { return nil }
            return TreeNode(kind: .column(
                schema: schema,
                table: table,
                name: row[0],
                type: row[1],
                nullable: row[2].uppercased() == "YES"))
        }
    }

    /// What the catalog says about every column of one table.
    func columnDetails(schema: String, table: String) async -> [ColumnInfo] {
        guard let rows = try? await session.queryStrings(
            CatalogQueries.columns(schema: schema, table: table))
        else { return [] }
        return rows.compactMap { row in
            guard row.count >= 3 else { return nil }
            return ColumnInfo(
                name: row[0], typeName: row[1], isNullable: row[2].uppercased() == "YES")
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

        guard let rows = try? await session.queryStrings(CatalogQueries.allTables) else { return }
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
}
