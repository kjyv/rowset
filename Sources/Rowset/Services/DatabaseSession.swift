import Foundation

/// One open connection to one database, whatever kind it is.
///
/// The app talks to a database only through this. `PostgresSession` opens a server and
/// `SQLiteSession` opens a file, and everything above them reads rows the same way.
protocol DatabaseSession: Actor {
    var isOpen: Bool { get }

    func connect() async throws
    func close() async

    /// Runs a statement and reads at most `maxRows` rows.
    ///
    /// A statement that returns no row carries no column description, so `expectedColumns` says
    /// what the caller already knows from the catalog.
    func query(
        _ sql: String, maxRows: Int, expectedColumns: [ResultColumn]
    ) async throws -> ResultSet

    /// Runs statements in one transaction. Either every one takes effect or none does.
    ///
    /// Each statement ends with `RETURNING 1`, so a count of the returned rows says whether it
    /// hit the row it aimed at. Anything but one row rolls the whole batch back.
    func runTransaction(_ statements: [String]) async throws
}

extension DatabaseSession {
    func query(_ sql: String, maxRows: Int) async throws -> ResultSet {
        try await query(sql, maxRows: maxRows, expectedColumns: [])
    }

    /// Runs a statement and gives the rows back as plain strings. The catalog queries use this.
    func queryStrings(_ sql: String, maxRows: Int = 10_000) async throws -> [[String]] {
        let result = try await query(sql, maxRows: maxRows, expectedColumns: [])
        return result.rows.map { row in row.values.map { $0.isNull ? "" : $0.text } }
    }
}

/// Opens the session a bookmark asks for.
enum DatabaseSessionFactory {
    static func session(for bookmark: Bookmark) -> any DatabaseSession {
        switch bookmark.driver {
        case .postgres: PostgresSession(bookmark: bookmark)
        case .sqlite: SQLiteSession(bookmark: bookmark)
        }
    }
}
