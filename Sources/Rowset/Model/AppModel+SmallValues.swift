import Foundation

extension AppModel {

    /// Fetches the columns of a page whose values all turned out to be small.
    ///
    /// The grid asks for the size of every large column, because reading one is what costs. Once
    /// the page is here, the sizes say which of those columns hold nothing big on this page, and
    /// those are worth reading after all. A page of values under two kilobytes is a megabyte or
    /// two, which costs about a second.
    ///
    /// The catalog cannot answer this. `pg_stats` reported an average of twenty bytes for a
    /// column whose values run to fifty kilobytes. Only the page itself knows.
    func fillSmallValues(_ names: [String], in tab: QueryTab) async {
        guard !names.isEmpty,
              case .table(let schema, let table) = tab.kind,
              let result = tab.result,
              let connection = connections[tab.connectionID],
              !tab.primaryKey.isEmpty
        else { return }

        let wanted = tab.primaryKey + names
        let sql = SQLBuilder.selectRows(
            schema: schema,
            table: table,
            filter: tab.filterText,
            orderBy: tab.orderByText,
            limit: tab.rowLimit + 1,
            offset: tab.pageOffset,
            columns: wanted)

        guard let fetched = try? await connection.run(sql, limit: tab.rowLimit + 1),
              fetched.columns.count == wanted.count
        else { return }

        // The rows are matched by key, because two runs of one query need not agree on order.
        let keyCount = tab.primaryKey.count
        var byKey: [String: [DisplayValue]] = [:]
        for row in fetched.rows {
            let key = (0..<keyCount).map { row.value(at: $0).text }.joined(separator: "\u{1}")
            byKey[key] = Array(row.values.dropFirst(keyCount))
        }

        guard let keyIndexes = keyColumnIndexes(of: result, tab: tab),
              let targets = columnIndexes(of: names, in: result)
        else { return }

        var updated = result
        var changed = false

        for rowIndex in updated.rows.indices {
            let row = updated.rows[rowIndex]
            let key = keyIndexes.map { row.value(at: $0).text }.joined(separator: "\u{1}")
            guard let values = byKey[key], values.count == targets.count else { continue }

            for (target, value) in zip(targets, values) {
                guard target < updated.rows[rowIndex].values.count else { continue }
                updated.rows[rowIndex].values[target] = value
                changed = true
            }
        }

        guard changed else { return }
        updated.revision += 1
        tab.result = updated
    }

    private func keyColumnIndexes(of result: ResultSet, tab: QueryTab) -> [Int]? {
        let indexes = tab.primaryKey.compactMap { name in
            result.columns.firstIndex { $0.name == name }
        }
        return indexes.count == tab.primaryKey.count ? indexes : nil
    }

    private func columnIndexes(of names: [String], in result: ResultSet) -> [Int]? {
        let indexes = names.compactMap { name in
            result.columns.firstIndex { $0.name == name }
        }
        return indexes.count == names.count ? indexes : nil
    }
}
