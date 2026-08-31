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

    /// The statement that the filter fields of a table tab stand for.
    ///
    /// This is the same SELECT the table runs, so opening the console shows you what you were
    /// already looking at and lets you take it further.
    func generatedSQL(for tab: QueryTab) -> String {
        guard case .table(let schema, let name) = tab.kind else { return tab.sqlText }
        return SQLBuilder.selectRows(
            schema: schema,
            table: name,
            filter: tab.filterText,
            orderBy: tab.orderByText,
            limit: tab.rowLimit) + ";"
    }

    /// Shows or hides the console of a table tab.
    ///
    /// The first time it opens, it takes the query of the filter fields. After that it keeps what
    /// you wrote, so closing and opening the pane loses nothing.
    func toggleConsole(_ tab: QueryTab) {
        if !tab.showsConsole, !tab.didPrefillConsole {
            resetConsoleFromFilter(tab)
        }
        tab.showsConsole.toggle()
        saveSession()
    }

    /// Writes the query of the filter fields into the console, over whatever is there.
    func resetConsoleFromFilter(_ tab: QueryTab) {
        tab.sqlText = generatedSQL(for: tab)
        tab.sqlCaret = 0
        tab.didPrefillConsole = true
    }

    /// Runs the statement the caret is in.
    func runCurrentStatement(_ tab: QueryTab) async {
        guard let connection = connections[tab.connectionID],
              let statement = tab.currentStatement
        else { return }
        await run(statement.text, in: tab, connection: connection, expectedColumns: [])
    }

    /// Runs every statement of the editor, one after the other.
    ///
    /// It stops at the first failure, and the result of the last statement stays on screen. The
    /// statements do not share a transaction, which matches what a console does.
    func runAllStatements(_ tab: QueryTab) async {
        guard let connection = connections[tab.connectionID] else { return }
        let statements = tab.sqlStatements
        guard !statements.isEmpty else { return }

        for statement in statements {
            await run(statement.text, in: tab, connection: connection, expectedColumns: [])
            if tab.errorText != nil { return }
        }
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
