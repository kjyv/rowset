import Foundation

extension AppModel {

    /// Runs the query of a table tab and puts the result into the tab.
    ///
    /// It asks the server for one row more than the page holds. That extra row is what says
    /// whether another page follows, and it costs one row instead of a count over the table.
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
            limit: tab.rowLimit + 1,
            offset: tab.pageOffset)

        guard var result = await execute(
            sql, in: tab, connection: connection, expectedColumns: tab.knownColumns)
        else { return }

        // The extra row never reaches the grid. It only answers whether more follow.
        if result.rows.count > tab.rowLimit {
            result.rows.removeLast()
            result.truncated = true
            tab.hasMoreRows = true
        } else {
            tab.hasMoreRows = false
            tab.totalRows = tab.pageOffset + result.rows.count
        }

        tab.result = result
        saveSession()
    }

    /// Runs the query again from the first page, and forgets the count.
    ///
    /// Only a new filter asks for this. It changes which rows there are, so the page you were on
    /// holds other rows and the count is wrong.
    func reloadTable(_ tab: QueryTab) async {
        tab.resetPaging()
        await runTableQuery(tab)
    }

    /// Fetches the same page again and forgets the count.
    ///
    /// The rows may have changed under you, so the count has to go. The page stays, because you
    /// asked to see this page again.
    func refreshTable(_ tab: QueryTab) async {
        tab.totalRows = nil
        await runTableQuery(tab)
    }

    /// Runs the query again on the same page, keeping the count.
    ///
    /// A new sort orders the same rows, so neither the page nor the count is wrong.
    func resortTable(_ tab: QueryTab) async {
        await runTableQuery(tab)
    }

    /// Changes how many rows fit on a page and stays near where you were.
    ///
    /// The count still holds, because the rows are the same. The offset moves to the start of the
    /// page that now holds the row you were looking at.
    func changePageSize(to size: Int, in tab: QueryTab) async {
        guard size > 0 else { return }
        let firstRow = tab.pageOffset
        tab.rowLimit = size
        tab.pageOffset = (firstRow / size) * size

        switch tab.kind {
        case .table:
            await runTableQuery(tab)
        case .sql:
            await goToStatementPage(offset: tab.pageOffset, in: tab)
        }
    }

    /// Moves to another page of the same query.
    func goToPage(offset: Int, in tab: QueryTab) async {
        let wanted = max(0, offset)
        guard wanted != tab.pageOffset else { return }
        tab.pageOffset = wanted
        await runTableQuery(tab)
    }

    /// Counts what the filter matches, so the widget can name the last page.
    func countRows(in tab: QueryTab) async {
        guard case .table(let schema, let name) = tab.kind,
              let connection = connections[tab.connectionID],
              !tab.isCounting
        else { return }

        tab.isCounting = true
        defer { tab.isCounting = false }

        let sql = SQLBuilder.countRows(schema: schema, table: name, filter: tab.filterText)
        guard let result = try? await connection.run(sql, limit: 1),
              let text = result.rows.first?.values.first?.text,
              let count = Int(text)
        else { return }

        tab.totalRows = count
    }

    /// The statement that the filter fields of a table tab stand for.
    ///
    /// It carries the filter and the sort and no page of its own. The page widget puts the LIMIT
    /// and the OFFSET around it, so a LIMIT written in here would fight the widget.
    func generatedSQL(for tab: QueryTab) -> String {
        guard case .table(let schema, let name) = tab.kind else { return tab.sqlText }
        return SQLBuilder.selectAll(
            schema: schema,
            table: name,
            filter: tab.filterText,
            orderBy: tab.orderByText)
    }

    /// Turns a table tab into a console on the query it was showing.
    ///
    /// The tab becomes a console tab in every way, so it runs the same code as one opened from
    /// the tab bar. There is no way back, because the statement may end up showing another table
    /// than the one it started on.
    ///
    /// The query is saved as a console of this connection, so it stands beside the others in the
    /// list and outlives the tab.
    func openConsole(on tab: QueryTab) async {
        guard case .table(_, let name) = tab.kind else { return }

        let statement = generatedSQL(for: tab)
        let sql = "-- \(name)\n\n" + statement + ";"
        let buffer = bufferStore.create(for: tab.connectionID, text: sql)

        // The page you were on carries over, so the console opens on the same rows.
        let keptOffset = tab.pageOffset

        tab.becomeConsole()
        tab.bufferID = buffer.id
        tab.sqlText = sql
        tab.sqlCaret = 0
        tab.resetPaging()
        tab.pageOffset = keptOffset
        saveSession()

        // The tab is a console whatever happens next. Running the page needs a connection, and a
        // dropped one must not leave the tab half converted.
        guard let connection = connections[tab.connectionID] else { return }
        await runPage(of: statement, in: tab, connection: connection)
    }

    /// Runs the statement the caret is in.
    ///
    /// A statement that reads is wrapped in a page, so the widget works in a console as well. A
    /// statement that writes runs as it stands, and shows no widget.
    func runCurrentStatement(_ tab: QueryTab) async {
        guard let connection = connections[tab.connectionID],
              let statement = tab.currentStatement
        else { return }

        // Another statement means other rows and other columns, so the page, the count and the
        // sort all start again.
        if tab.pagedStatement != statement.text {
            tab.resetPaging()
            tab.orderByText = ""
        }

        guard SQLStatementSplitter.isPageable(statement.text) else {
            tab.pagedStatement = nil
            await run(statement.text, in: tab, connection: connection, expectedColumns: [])
            return
        }

        await runPage(of: statement.text, in: tab, connection: connection)
    }

    /// Moves a console to another page of the statement it is showing.
    func goToStatementPage(offset: Int, in tab: QueryTab) async {
        guard let connection = connections[tab.connectionID],
              let statement = tab.pagedStatement
        else { return }
        tab.pageOffset = max(0, offset)
        await runPage(of: statement, in: tab, connection: connection)
    }

    /// The ORDER BY that a console puts on its wrapper.
    ///
    /// Only a column header writes this, so the name is quoted rather than passed through.
    func consoleOrderBy(for tab: QueryTab) -> String {
        guard let sort = tab.sort else { return "" }
        return "\(SQLBuilder.quoteIdentifier(sort.column)) \(sort.sqlDirection)"
    }

    /// Sorts a console on a column and stays on the page.
    func resortConsole(_ tab: QueryTab) async {
        guard let connection = connections[tab.connectionID],
              let statement = tab.pagedStatement
        else { return }
        await runPage(of: statement, in: tab, connection: connection)
    }

    private func runPage(
        of statement: String, in tab: QueryTab, connection: ConnectionModel
    ) async {
        let sql = SQLBuilder.page(
            statement,
            limit: tab.rowLimit + 1,
            offset: tab.pageOffset,
            orderBy: consoleOrderBy(for: tab))
        guard var result = await execute(sql, in: tab, connection: connection, expectedColumns: [])
        else { return }

        if result.rows.count > tab.rowLimit {
            result.rows.removeLast()
            result.truncated = true
            tab.hasMoreRows = true
        } else {
            tab.hasMoreRows = false
            tab.totalRows = tab.pageOffset + result.rows.count
        }

        tab.pagedStatement = statement
        tab.result = result
        saveSession()
    }

    /// Counts the rows the statement of a console gives back.
    func countStatementRows(in tab: QueryTab) async {
        guard let connection = connections[tab.connectionID],
              let statement = tab.pagedStatement,
              !tab.isCounting
        else { return }

        tab.isCounting = true
        defer { tab.isCounting = false }

        guard let result = try? await connection.run(SQLBuilder.countOf(statement), limit: 1),
              let text = result.rows.first?.values.first?.text,
              let count = Int(text)
        else { return }

        tab.totalRows = count
    }

    /// Runs every statement of the editor, one after the other.
    ///
    /// It stops at the first failure, and the result of the last statement stays on screen. The
    /// statements do not share a transaction, which matches what a console does.
    func runAllStatements(_ tab: QueryTab) async {
        guard let connection = connections[tab.connectionID] else { return }
        let statements = tab.sqlStatements
        guard !statements.isEmpty else { return }

        tab.resetPaging()
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
        guard let result = await execute(
            sql, in: tab, connection: connection, expectedColumns: expectedColumns)
        else { return }
        tab.result = result
        saveSession()
    }

    /// Runs a statement and gives the result back instead of putting it on screen.
    ///
    /// The table query trims a row off the result before it shows it, and a result already on
    /// screen would flash the extra row first.
    private func execute(
        _ sql: String,
        in tab: QueryTab,
        connection: ConnectionModel,
        expectedColumns: [ResultColumn]
    ) async -> ResultSet? {
        guard !tab.isRunning else { return nil }
        tab.isRunning = true
        tab.errorText = nil
        tab.lastStatement = sql
        defer { tab.isRunning = false }

        do {
            // One row over the page limit, so the query says whether more follow.
            return try await connection.run(
                sql, limit: tab.rowLimit + 1, expectedColumns: expectedColumns)
        } catch let error as AWSAuthError {
            tab.errorText = error.errorDescription
            if case .ssoExpired(let profile, let detail) = error {
                ssoPrompt = SSOPrompt(profile: profile, detail: detail)
            }
        } catch {
            tab.errorText = DatabaseErrorText.describe(error)
        }

        saveSession()
        return nil
    }

    /// Applies a new sort and runs the query again.
    func applySort(_ sort: SortSpec?, to tab: QueryTab) async {
        tab.orderByText = sort?.text ?? ""
        await runTableQuery(tab)
    }
}
