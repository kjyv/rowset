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

    /// The ORDER BY text for this sort.
    var text: String { "\(column) \(sqlDirection)" }

    /// Reads an ORDER BY text that names one column.
    ///
    /// The header arrow needs a single column and a direction. A text such as
    /// `created_at DESC, id` names more than that, so the parser returns `nil` and the header
    /// shows no arrow. The text still goes into the query.
    static func parse(_ text: String) -> SortSpec? {
        let parts = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard (1...2).contains(parts.count) else { return nil }

        let name = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        // Only a plain name can carry the header arrow. An expression such as `lower(slug)`
        // matches no column, so the arrow would point at nothing.
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }

        guard parts.count == 2 else { return SortSpec(column: name, ascending: true) }
        switch parts[1].uppercased() {
        case "ASC": return SortSpec(column: name, ascending: true)
        case "DESC": return SortSpec(column: name, ascending: false)
        default: return nil
        }
    }
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

    /// A WHERE that names an exact set of rows by their key.
    ///
    /// One column gives `"slug" IN ('a', 'b')`. Two give `("a", "b") IN (('1', '2'))`, which
    /// Postgres compares row by row.
    static func keyList(_ columns: [String], values: [[String]]) -> String {
        let names = columns.map(quoteIdentifier).joined(separator: ", ")
        let rows = values
            .map { "(" + $0.map(quoteLiteral).joined(separator: ", ") + ")" }
            .joined(separator: ", ")
        return "(\(names)) IN (\(rows))"
    }

    /// One column and the value it takes. `nil` means NULL.
    struct Assignment: Hashable, Sendable {
        var column: String
        var value: String?
    }

    /// Writes an UPDATE for one row.
    ///
    /// The WHERE holds the primary key of that row, read from the values the server sent, so an
    /// edit of a key column still finds the row it came from. `RETURNING 1` lets the caller check
    /// that exactly one row changed.
    static func update(
        schema: String,
        table: String,
        set changes: [Assignment],
        key: [Assignment]
    ) -> String {
        let sets = changes
            .map { "\(quoteIdentifier($0.column)) = \(literal($0.value))" }
            .joined(separator: ", ")

        let conditions = key
            .map { assignment -> String in
                guard let value = assignment.value else {
                    return "\(quoteIdentifier(assignment.column)) IS NULL"
                }
                return "\(quoteIdentifier(assignment.column)) = \(quoteLiteral(value))"
            }
            .joined(separator: " AND ")

        return """
            UPDATE \(qualifiedName(schema: schema, table: table))
            SET \(sets)
            WHERE \(conditions)
            RETURNING 1
            """
    }

    /// A value as SQL. A missing value is NULL and not the text "NULL".
    static func literal(_ value: String?) -> String {
        value.map(quoteLiteral) ?? "NULL"
    }

    /// Builds `SELECT * FROM "s"."t" [WHERE ...] [ORDER BY ...] LIMIT n`.
    ///
    /// The filter text and the order text go in unchanged. A database client must let you write
    /// SQL, so you can type `lower(slug) LIKE 'a%'` or `created_at DESC, id`.
    static func selectRows(
        schema: String,
        table: String,
        filter: String,
        orderBy: String,
        limit: Int,
        offset: Int = 0,
        columns: [String] = [],
        expressions: [String] = []
    ) -> String {
        let selectList = expressions.isEmpty ? columnList(columns) : expressionList(expressions)
        var sql = "SELECT \(selectList) FROM \(qualifiedName(schema: schema, table: table))"

        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFilter.isEmpty {
            sql += "\nWHERE \(trimmedFilter)"
        }

        let trimmedOrder = orderBy.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOrder.isEmpty {
            sql += "\nORDER BY \(trimmedOrder)"
        }

        sql += "\nLIMIT \(max(1, limit))"
        if offset > 0 { sql += "\nOFFSET \(offset)" }
        return sql
    }

    /// Builds `SELECT * FROM "s"."t" [WHERE ...] [ORDER BY ...]`, with no page of its own.
    ///
    /// A console gets this one. The page widget adds the LIMIT and the OFFSET around it, so a
    /// LIMIT written in here would fight the widget.
    static func selectAll(
        schema: String, table: String, filter: String, orderBy: String, columns: [String] = []
    ) -> String {
        var sql = "SELECT \(columnList(columns)) FROM \(qualifiedName(schema: schema, table: table))"

        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFilter.isEmpty { sql += "\nWHERE \(trimmedFilter)" }

        let trimmedOrder = orderBy.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOrder.isEmpty { sql += "\nORDER BY \(trimmedOrder)" }

        return sql
    }

    /// The name the page wrapper gives the statement it wraps.
    ///
    /// A subquery in a FROM needs a name, and this one is unlikely to clash with a real table.
    static let pageAlias = "_rowset_page"

    /// Wraps a statement so a page of its rows comes back.
    ///
    /// The order goes on the wrapper as well, so a click on a column header sorts the whole
    /// result and not the page you happen to be on. The columns of the statement are in scope by
    /// their output names.
    ///
    /// Only a statement that reads may be wrapped, see `SQLStatementSplitter.isPageable`.
    static func page(
        _ statement: String, limit: Int, offset: Int, orderBy: String = ""
    ) -> String {
        var sql = """
            SELECT * FROM (
            \(statement)
            ) AS \(pageAlias)
            """

        let trimmedOrder = orderBy.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOrder.isEmpty { sql += "\nORDER BY \(trimmedOrder)" }

        sql += "\nLIMIT \(max(1, limit))"
        if offset > 0 { sql += "\nOFFSET \(offset)" }
        return sql
    }

    /// Counts the rows a statement gives back.
    static func countOf(_ statement: String) -> String {
        """
        SELECT count(*) FROM (
        \(statement)
        ) AS \(pageAlias)
        """
    }

    /// The columns a SELECT asks for. An empty list means every column, in the table order.
    static func columnList(_ columns: [String]) -> String {
        guard !columns.isEmpty else { return "*" }
        return columns.map(quoteIdentifier).joined(separator: ", ")
    }

    /// Asks for the size of a large value and never for the value.
    ///
    /// Reading the value is the whole cost. Postgres keeps a value over about two kilobytes
    /// outside the row, and it has to fetch and unpack that store to give even the first
    /// characters. `pg_column_size` reads the pointer instead, which costs nothing.
    ///
    /// The name is kept, so the grid sees the column it expects.
    static func sizeOfColumn(_ name: String) -> String {
        "pg_column_size(\(quoteIdentifier(name)))::text AS \(quoteIdentifier(name))"
    }

    /// A ready made select list. Each entry is already SQL.
    static func expressionList(_ expressions: [String]) -> String {
        expressions.isEmpty ? "*" : expressions.joined(separator: ", ")
    }

    /// Counts the rows a filter matches, for the page widget.
    static func countRows(schema: String, table: String, filter: String) -> String {
        var sql = "SELECT count(*) FROM \(qualifiedName(schema: schema, table: table))"
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sql += "\nWHERE \(trimmed)" }
        return sql
    }
}
