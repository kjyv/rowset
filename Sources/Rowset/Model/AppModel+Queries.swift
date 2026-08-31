import Foundation

extension AppModel {

    /// Runs the query of a table tab and puts the result into the tab.
    func runTableQuery(_ tab: QueryTab) async {
        guard case .table(let schema, let name) = tab.kind,
              let connection = connections[tab.connectionID]
        else { return }

        if tab.columnInfo.isEmpty {
            let details = await connection.columnDetails(schema: schema, table: name)
            tab.columnInfo = Dictionary(uniqueKeysWithValues: details.map { ($0.name, $0) })
            tab.knownColumns = details.enumerated().map { index, info in
                ResultColumn(id: index, name: info.name, typeName: info.typeName)
            }
        }
        await loadPrimaryKey(for: tab)

        let sql = SQLBuilder.selectRows(
            schema: schema,
            table: name,
            filter: tab.filterText,
            orderBy: tab.orderByText,
            limit: tab.rowLimit)

        await run(sql, in: tab, connection: connection, expectedColumns: tab.knownColumns)
    }

    /// Runs the text of a SQL tab.
    func runSQLTab(_ tab: QueryTab) async {
        guard let connection = connections[tab.connectionID] else { return }
        let sql = tab.sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }
        await run(sql, in: tab, connection: connection, expectedColumns: [])
    }

    private func run(
        _ sql: String,
        in tab: QueryTab,
        connection: ConnectionModel,
        expectedColumns: [ResultColumn]
    ) async {
        guard !tab.isRunning else { return }
        tab.isRunning = true
        tab.errorText = nil
        tab.lastStatement = sql
        defer { tab.isRunning = false }

        do {
            tab.result = try await connection.run(
                sql, limit: tab.rowLimit, expectedColumns: expectedColumns)
        } catch let error as AWSAuthError {
            tab.errorText = error.errorDescription
            if case .ssoExpired(let profile, let detail) = error {
                ssoPrompt = SSOPrompt(profile: profile, detail: detail)
            }
        } catch {
            tab.errorText = DatabaseErrorText.describe(error)
        }

        saveSession()
    }

    /// Applies a new sort and runs the query again.
    func applySort(_ sort: SortSpec?, to tab: QueryTab) async {
        tab.orderByText = sort?.text ?? ""
        await runTableQuery(tab)
    }
}
