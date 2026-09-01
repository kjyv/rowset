import Foundation

extension AppModel {

    /// Fetches a row whole, for the values the grid asked the server to cut.
    ///
    /// The grid asks for the first characters of a large value, which is what makes a wide table
    /// open quickly. Everything that shows or writes a whole value comes here first, so a cut
    /// value is never what you read, edit or copy.
    func loadFullRow(_ rowID: Int, in tab: QueryTab) async {
        guard case .table(let schema, let name) = tab.kind,
              let result = tab.result,
              let row = result.row(id: rowID),
              row.values.contains(where: \.isCut),
              let connection = connections[tab.connectionID],
              let key = keyAssignments(for: row, in: result, tab: tab)
        else { return }

        let conditions = key
            .map { assignment -> String in
                guard let value = assignment.value else {
                    return "\(SQLBuilder.quoteIdentifier(assignment.column)) IS NULL"
                }
                return "\(SQLBuilder.quoteIdentifier(assignment.column)) = "
                    + SQLBuilder.quoteLiteral(value)
            }
            .joined(separator: " AND ")

        let columns = result.columns.map { SQLBuilder.quoteIdentifier($0.name) }
        let sql = """
            SELECT \(columns.joined(separator: ", "))
            FROM \(SQLBuilder.qualifiedName(schema: schema, table: name))
            WHERE \(conditions)
            LIMIT 1
            """

        guard let whole = try? await connection.run(sql, limit: 1),
              let fetched = whole.rows.first,
              fetched.values.count == row.values.count,
              var current = tab.result,
              let index = current.rows.firstIndex(where: { $0.id == rowID })
        else { return }

        current.rows[index].values = fetched.values
        current.revision += 1
        tab.result = current
    }

    /// Fetches every row of a selection that still holds a cut value.
    func loadFullRows(of selection: CellSelection, in tab: QueryTab) async {
        guard let result = tab.result else { return }
        for rowID in selection.rows {
            guard let row = result.row(id: rowID), row.values.contains(where: \.isCut) else {
                continue
            }
            await loadFullRow(rowID, in: tab)
        }
    }

    /// The primary key of one row, taken from what the server sent.
    private func keyAssignments(
        for row: ResultRow, in result: ResultSet, tab: QueryTab
    ) -> [SQLBuilder.Assignment]? {
        var assignments: [SQLBuilder.Assignment] = []
        for name in tab.primaryKey {
            guard let column = result.columns.first(where: { $0.name == name }) else { return nil }
            let value = row.value(at: column.id)
            // A key column is never large, so its value is whole.
            guard !value.isCut else { return nil }
            assignments.append(
                SQLBuilder.Assignment(column: name, value: value.isNull ? nil : value.text))
        }
        return assignments.isEmpty ? nil : assignments
    }
}
