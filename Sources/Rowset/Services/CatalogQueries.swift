import Foundation

/// The SQL that fills the sidebar tree.
///
/// Each query gives the same columns whatever the driver, so the model above reads one shape.
/// The two dialects stand side by side here, which is the only place they meet.
enum CatalogQueries {

    /// Every schema a user cares about. Skips the system schemas.
    ///
    /// SQLite holds one schema. `main` is what every unqualified name means.
    static func schemas(_ driver: Driver) -> String {
        switch driver {
        case .postgres:
            """
            SELECT nspname
            FROM pg_catalog.pg_namespace
            WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'
            ORDER BY nspname
            """
        case .sqlite:
            "SELECT 'main'"
        }
    }

    /// The tables and views of one schema, and what each one is.
    static func tables(_ driver: Driver, schema: String) -> String {
        switch driver {
        case .postgres:
            """
            SELECT table_name, table_type
            FROM information_schema.tables
            WHERE table_schema = \(SQLBuilder.quoteLiteral(schema))
            ORDER BY table_name
            """
        case .sqlite:
            """
            SELECT name, CASE type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END
            FROM sqlite_master
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
            ORDER BY name
            """
        }
    }

    /// Every table and view of the database, for the sidebar filter.
    static func allTables(_ driver: Driver) -> String {
        switch driver {
        case .postgres:
            """
            SELECT table_schema, table_name, table_type
            FROM information_schema.tables
            WHERE table_schema NOT LIKE 'pg\\_%' AND table_schema <> 'information_schema'
            ORDER BY table_schema, table_name
            """
        case .sqlite:
            """
            SELECT 'main', name, CASE type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END
            FROM sqlite_master
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
            ORDER BY name
            """
        }
    }

    /// The columns of the primary key, in key order.
    ///
    /// An UPDATE needs a WHERE that hits one row. Without such a key there is no such WHERE, so
    /// the app refuses to edit that table rather than guess.
    static func primaryKey(_ driver: Driver, schema: String, table: String) -> String {
        switch driver {
        case .postgres:
            let qualified = SQLBuilder.qualifiedName(schema: schema, table: table)
            return """
                SELECT a.attname
                FROM pg_index i
                JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
                WHERE i.indrelid = \(SQLBuilder.quoteLiteral(qualified))::regclass
                  AND i.indisprimary
                ORDER BY array_position(i.indkey, a.attnum)
                """
        case .sqlite:
            return """
                SELECT name
                FROM pragma_table_info(\(SQLBuilder.quoteLiteral(table)))
                WHERE pk > 0
                ORDER BY pk
                """
        }
    }

    /// The columns of one table, in their real order.
    ///
    /// The fourth column is the length a `varchar` declaration allows. SQLite declares no such
    /// limit, and -1 says there is none.
    static func columns(_ driver: Driver, schema: String, table: String) -> String {
        switch driver {
        case .postgres:
            """
            SELECT column_name, data_type, is_nullable,
                   coalesce(character_maximum_length, -1)::text
            FROM information_schema.columns
            WHERE table_schema = \(SQLBuilder.quoteLiteral(schema))
              AND table_name = \(SQLBuilder.quoteLiteral(table))
            ORDER BY ordinal_position
            """
        case .sqlite:
            """
            SELECT name, type, CASE WHEN "notnull" = 0 THEN 'YES' ELSE 'NO' END, '-1'
            FROM pragma_table_info(\(SQLBuilder.quoteLiteral(table)))
            ORDER BY cid
            """
        }
    }
}
