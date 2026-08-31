import Foundation

/// The SQL that fills the sidebar tree.
enum CatalogQueries {
    /// Every schema a user cares about. Skips the system schemas.
    static let schemas = """
        SELECT nspname
        FROM pg_catalog.pg_namespace
        WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'
        ORDER BY nspname
        """

    /// The tables and views of one schema.
    static func tables(schema: String) -> String {
        """
        SELECT table_name, table_type
        FROM information_schema.tables
        WHERE table_schema = \(SQLBuilder.quoteLiteral(schema))
        ORDER BY table_name
        """
    }

    /// The columns of one table, in their real order.
    static func columns(schema: String, table: String) -> String {
        """
        SELECT column_name, data_type, is_nullable
        FROM information_schema.columns
        WHERE table_schema = \(SQLBuilder.quoteLiteral(schema))
          AND table_name = \(SQLBuilder.quoteLiteral(table))
        ORDER BY ordinal_position
        """
    }
}
