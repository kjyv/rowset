import XCTest
@testable import Rowset

/// Talks to a real database. The test skips itself when the environment does not describe one.
///
/// Set these variables to run it:
///
///     ROWSET_LIVE_HOST, ROWSET_LIVE_DB, ROWSET_LIVE_USER,
///     ROWSET_LIVE_PROFILE, ROWSET_LIVE_REGION
///     ROWSET_LIVE_SCHEMA   (optional, default "public")
///     ROWSET_CA_BUNDLE     (optional, path to rds-global-bundle.pem)
final class LiveConnectionTests: XCTestCase {

    private func liveBookmark() throws -> Bookmark {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) throws -> String {
            guard let found = environment[key], !found.isEmpty else {
                throw XCTSkip("\(key) is not set, so the live test does not run.")
            }
            return found
        }

        var bookmark = Bookmark()
        bookmark.name = "live test"
        bookmark.host = try value("ROWSET_LIVE_HOST")
        bookmark.database = try value("ROWSET_LIVE_DB")
        bookmark.username = try value("ROWSET_LIVE_USER")
        bookmark.awsProfile = try value("ROWSET_LIVE_PROFILE")
        bookmark.awsRegion = environment["ROWSET_LIVE_REGION"] ?? "eu-central-1"
        bookmark.port = Int(environment["ROWSET_LIVE_PORT"] ?? "5432") ?? 5432
        return bookmark
    }

    private var schema: String {
        ProcessInfo.processInfo.environment["ROWSET_LIVE_SCHEMA"] ?? "public"
    }

    func testTokenGeneratorReturnsAToken() async throws {
        let bookmark = try liveBookmark()
        let token = try await AWSTokenProvider.authToken(for: bookmark)
        XCTAssertTrue(token.hasPrefix(bookmark.host), "the token starts with the host name")
        XCTAssertTrue(token.contains("X-Amz-Signature"), "the token carries a signature")
    }

    func testConnectAndReadTheCatalog() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        defer { Task { await session.close() } }

        let version = try await session.query("SELECT version()", maxRows: 1)
        XCTAssertEqual(version.rows.count, 1)
        let text = version.rows[0].values[0].text
        XCTAssertTrue(text.contains("PostgreSQL"), "unexpected version string: \(text)")

        let schemas = try await session.queryStrings(CatalogQueries.schemas)
        XCTAssertFalse(schemas.isEmpty, "the database reports no schema")

        let tables = try await session.queryStrings(CatalogQueries.tables(schema: schema))
        XCTAssertFalse(tables.isEmpty, "schema \(schema) reports no table")

        guard let firstTable = tables.first?.first else { return }
        let columns = try await session.queryStrings(
            CatalogQueries.columns(schema: schema, table: firstTable))
        XCTAssertFalse(columns.isEmpty, "table \(firstTable) reports no column")
    }

    func testReadRowsWithALimitAndASort() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        defer { Task { await session.close() } }

        let tables = try await session.queryStrings(CatalogQueries.tables(schema: schema))
        guard let table = tables.first?.first else {
            throw XCTSkip("schema \(schema) has no table")
        }
        let columns = try await session.queryStrings(
            CatalogQueries.columns(schema: schema, table: table))
        guard let sortColumn = columns.first?.first else {
            throw XCTSkip("table \(table) has no column")
        }

        let sql = SQLBuilder.selectRows(
            schema: schema,
            table: table,
            filter: "",
            orderBy: SortSpec(column: sortColumn, ascending: false).text,
            limit: 5)

        let result = try await session.query(sql, maxRows: 5)
        XCTAssertLessThanOrEqual(result.rows.count, 5)
        XCTAssertEqual(result.columns.count, columns.count)
        for row in result.rows {
            XCTAssertEqual(row.values.count, result.columns.count)
        }
    }

    /// Proves that the WHERE text of the filter field reaches the server.
    func testTheFilterReachesTheServer() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        defer { Task { await session.close() } }

        let tables = try await session.queryStrings(CatalogQueries.tables(schema: schema))
        guard let table = tables.first?.first else { throw XCTSkip("no table") }

        func rowCount(filter: String) async throws -> Int {
            let sql = SQLBuilder.selectRows(
                schema: schema, table: table, filter: filter, orderBy: "", limit: 5)
            return try await session.query(sql, maxRows: 5).rows.count
        }

        let noRows = try await rowCount(filter: "1 = 0")
        XCTAssertEqual(noRows, 0, "the filter did not reach the server")

        let someRows = try await rowCount(filter: "1 = 1")
        XCTAssertGreaterThan(someRows, 0, "table \(table) is empty")
    }

    /// `= NULL` is never true in SQL. Only `IS NULL` matches a missing value.
    func testEqualsNullMatchesNoRow() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        defer { Task { await session.close() } }

        let equals = try await session.query(
            "SELECT * FROM (VALUES (1), (NULL)) AS t(v) WHERE v = NULL", maxRows: 10)
        XCTAssertEqual(equals.rows.count, 0, "= NULL never matches")

        let isNull = try await session.query(
            "SELECT * FROM (VALUES (1), (NULL)) AS t(v) WHERE v IS NULL", maxRows: 10)
        XCTAssertEqual(isNull.rows.count, 1, "IS NULL matches the missing value")
    }

    /// Two connects at once used to open two connections and drop one without closing it.
    /// PostgresNIO then failed an assertion and the app stopped at startup.
    func testTwoConnectsAtOnceOpenOneConnection() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        defer { Task { await session.close() } }

        async let first: Void = session.connect()
        async let second: Void = session.connect()
        _ = try await (first, second)

        let open = await session.isOpen
        XCTAssertTrue(open, "the session must hold one open connection")

        let result = try await session.query("SELECT 1", maxRows: 1)
        XCTAssertEqual(result.rows.first?.values.first?.text, "1")
    }

    func testAWrongStatementKeepsTheConnectionOpen() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        defer { Task { await session.close() } }

        do {
            _ = try await session.query("SELECT * FROM this_table_does_not_exist", maxRows: 1)
            XCTFail("the wrong statement did not fail")
        } catch {
            let message = DatabaseErrorText.describe(error)
            XCTAssertTrue(
                message.lowercased().contains("does not exist"),
                "unexpected message: \(message)")
        }

        let after = try await session.query("SELECT 1", maxRows: 1)
        XCTAssertEqual(after.rows.count, 1, "the connection did not survive the failed statement")
    }

    func testStoppingEarlyLeavesTheConnectionUsable() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        defer { Task { await session.close() } }

        // The statement offers 1000 rows. The session must read 10 and cancel the rest.
        let result = try await session.query("SELECT generate_series(1, 1000)", maxRows: 10)
        XCTAssertEqual(result.rows.count, 10)
        XCTAssertTrue(result.truncated)

        let after = try await session.query("SELECT 42", maxRows: 1)
        XCTAssertEqual(after.rows.first?.values.first?.text, "42")
    }
}
