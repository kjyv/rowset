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
        state = .disconnected
    }

    func refresh() async {
        guard state.isConnected else { return }
        schemas = []
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

    /// The catalog columns of one table, used to draw a header when a query returns no row.
    func columns(schema: String, table: String) async -> [ResultColumn] {
        guard let rows = try? await session.queryStrings(
            CatalogQueries.columns(schema: schema, table: table))
        else { return [] }
        return rows.enumerated().compactMap { index, row in
            guard row.count >= 2 else { return nil }
            return ResultColumn(id: index, name: row[0], typeName: row[1])
        }
    }

    // MARK: - Queries

    func run(_ sql: String, limit: Int, expectedColumns: [ResultColumn] = []) async throws -> ResultSet {
        try await session.query(sql, maxRows: limit, expectedColumns: expectedColumns)
    }
}
