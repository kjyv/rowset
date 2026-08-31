import Foundation

/// Tells the table which column the user clicked. The server does the sorting, so `compare`
/// never reorders anything here.
struct ColumnComparator: SortComparator, Hashable, Sendable {
    var columnName: String
    var order: SortOrder = .forward

    func compare(_ lhs: ResultRow, _ rhs: ResultRow) -> ComparisonResult {
        .orderedSame
    }

    var sortSpec: SortSpec {
        SortSpec(column: columnName, ascending: order == .forward)
    }
}

/// Which column the result sorts on.
struct SortSpec: Hashable, Sendable {
    var column: String
    var ascending: Bool = true

    var sqlDirection: String { ascending ? "ASC" : "DESC" }
}

/// Builds the SQL that the table tab runs.
enum SQLBuilder {
    /// Wraps an identifier in double quotes and doubles any inner quote.
    static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Wraps a value in single quotes and doubles any inner quote.
    static func quoteLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func qualifiedName(schema: String, table: String) -> String {
        "\(quoteIdentifier(schema)).\(quoteIdentifier(table))"
    }

    /// Builds `SELECT * FROM "s"."t" [WHERE ...] [ORDER BY ...] LIMIT n`.
    ///
    /// The filter text goes in unchanged. A database client must let you write SQL.
    static func selectRows(
        schema: String,
        table: String,
        filter: String,
        sort: SortSpec?,
        limit: Int
    ) -> String {
        var sql = "SELECT * FROM \(qualifiedName(schema: schema, table: table))"

        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFilter.isEmpty {
            sql += "\nWHERE \(trimmedFilter)"
        }

        if let sort {
            sql += "\nORDER BY \(quoteIdentifier(sort.column)) \(sort.sqlDirection)"
        }

        sql += "\nLIMIT \(max(1, limit))"
        return sql
    }
}
