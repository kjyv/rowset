import Foundation

extension AppModel {

    /// Reads the primary key of a table. Editing needs it, and a table without one stays read only.
    func loadPrimaryKey(for tab: QueryTab) async {
        guard case .table(let schema, let name) = tab.kind,
              tab.primaryKey.isEmpty,
              let connection = connections[tab.connectionID]
        else { return }

        guard let rows = try? await connection.run(
            CatalogQueries.primaryKey(schema: schema, table: name), limit: 32)
        else { return }

        tab.primaryKey = rows.rows.compactMap { row in
            let value = row.value(at: 0)
            return value.isNull ? nil : value.text
        }
    }

    /// Builds the statements for the edits of a tab and asks you to accept them.
    func prepareWrite(for tab: QueryTab) {
        guard case .table(let schema, let name) = tab.kind,
              let result = tab.result,
              tab.isEditable,
              tab.hasEdits
        else { return }

        // One statement per row, whatever the number of cells it changes.
        var byRow: [Int: [SQLBuilder.Assignment]] = [:]
        for (address, value) in tab.edits {
            guard let column = result.column(id: address.columnID) else { continue }
            byRow[address.rowID, default: []]
                .append(SQLBuilder.Assignment(column: column.name, value: value))
        }

        var statements: [String] = []
        for rowID in byRow.keys.sorted() {
            guard let changes = byRow[rowID], let key = keyAssignments(rowID: rowID, in: result, tab: tab)
            else { continue }
            statements.append(SQLBuilder.update(
                schema: schema,
                table: name,
                set: changes.sorted { $0.column < $1.column },
                key: key))
        }

        guard !statements.isEmpty else { return }
        pendingWrite = PendingWrite(
            tabID: tab.id,
            statements: statements,
            rowCount: statements.count,
            cellCount: tab.edits.count)
    }

    /// The primary key of one row, taken from what the server sent.
    ///
    /// The original value matters. An edit of a key column must still find the row it came from.
    private func keyAssignments(
        rowID: Int, in result: ResultSet, tab: QueryTab
    ) -> [SQLBuilder.Assignment]? {
        var assignments: [SQLBuilder.Assignment] = []
        for name in tab.primaryKey {
            guard let column = result.columns.first(where: { $0.name == name }),
                  let row = result.row(id: rowID)
            else { return nil }
            let value = row.value(at: column.id)
            assignments.append(
                SQLBuilder.Assignment(column: name, value: value.isNull ? nil : value.text))
        }
        return assignments.isEmpty ? nil : assignments
    }

    /// Sends the statements you accepted, all of them or none.
    func commitWrite(_ write: PendingWrite) async {
        guard let tab = tabs.first(where: { $0.id == write.tabID }),
              let connection = connections[tab.connectionID]
        else { return }

        tab.isRunning = true
        tab.errorText = nil
        defer { tab.isRunning = false }

        do {
            try await connection.runTransaction(write.statements)
            tab.discardEdits()
            pendingWrite = nil
            await runTableQuery(tab)
        } catch {
            pendingWrite = nil
            tab.errorText = DatabaseErrorText.describe(error)
        }
    }
}
