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

    /// The sidebar must answer while a statement runs.
    ///
    /// One connection carries one statement at a time, so a catalog read on the session
    /// connection would wait for `pg_sleep` to finish.
    func testBackgroundWorkRunsBesideALongStatement() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        addTeardownBlock { await session.close() }

        let running = Task { try await session.query("SELECT pg_sleep(20)", maxRows: 1) }
        try await Task.sleep(nanoseconds: 500_000_000)

        // This opens the background connection, which on an IAM bookmark fetches a token first.
        let start = Date()
        let result = try await session.queryInBackground(
            "SELECT 1", maxRows: 1, expectedColumns: [])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.rows.first?.values.first?.text, "1")
        XCTAssertLessThan(elapsed, 15, "the background statement waited for the long one")

        running.cancel()
        _ = try? await running.value
    }

    /// Stop reaches the server, not only the client.
    ///
    /// `pg_sleep` waits on the server, so a client that only stopped reading would still see the
    /// statement run to its end.
    func testStopEndsALongStatement() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        addTeardownBlock { await session.close() }

        let running = Task { try await session.query("SELECT pg_sleep(30)", maxRows: 1) }
        // The cancel opens its own connection, which on an IAM bookmark first fetches a token.
        try await Task.sleep(nanoseconds: 500_000_000)

        let start = Date()
        await session.cancelRunningQuery()
        do {
            _ = try await running.value
            XCTFail("the statement should have stopped")
        } catch is QueryCanceled {
            XCTAssertLessThan(Date().timeIntervalSince(start), 25, "the stop waited out the sleep")
        }
    }

    /// The connection stays open, so the next statement needs no reconnect.
    func testTheSessionSurvivesAStop() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        addTeardownBlock { await session.close() }

        let running = Task { try await session.query("SELECT pg_sleep(30)", maxRows: 1) }
        try await Task.sleep(nanoseconds: 500_000_000)
        await session.cancelRunningQuery()
        _ = try? await running.value

        let result = try await session.query("SELECT 1", maxRows: 1)
        XCTAssertEqual(result.rows.first?.values.first?.text, "1")
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
        addTeardownBlock { await session.close() }

        let version = try await session.query("SELECT version()", maxRows: 1)
        XCTAssertEqual(version.rows.count, 1)
        let text = version.rows[0].values[0].text
        XCTAssertTrue(text.contains("PostgreSQL"), "unexpected version string: \(text)")

        let schemas = try await session.queryStrings(CatalogQueries.schemas(.postgres))
        XCTAssertFalse(schemas.isEmpty, "the database reports no schema")

        let tables = try await session.queryStrings(CatalogQueries.tables(.postgres, schema: schema))
        XCTAssertFalse(tables.isEmpty, "schema \(schema) reports no table")

        guard let firstTable = tables.first?.first else { return }
        let columns = try await session.queryStrings(
            CatalogQueries.columns(.postgres, schema: schema, table: firstTable))
        XCTAssertFalse(columns.isEmpty, "table \(firstTable) reports no column")
    }

    func testReadRowsWithALimitAndASort() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        addTeardownBlock { await session.close() }

        let tables = try await session.queryStrings(CatalogQueries.tables(.postgres, schema: schema))
        guard let table = tables.first?.first else {
            throw XCTSkip("schema \(schema) has no table")
        }
        let columns = try await session.queryStrings(
            CatalogQueries.columns(.postgres, schema: schema, table: table))
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
        addTeardownBlock { await session.close() }

        let tables = try await session.queryStrings(CatalogQueries.tables(.postgres, schema: schema))
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
        addTeardownBlock { await session.close() }

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
        addTeardownBlock { await session.close() }

        async let first: Void = session.connect()
        async let second: Void = session.connect()
        _ = try await (first, second)

        let open = await session.isOpen
        XCTAssertTrue(open, "the session must hold one open connection")

        let result = try await session.query("SELECT 1", maxRows: 1)
        XCTAssertEqual(result.rows.first?.values.first?.text, "1")
    }

    /// Builds a table of its own, changes it, and drops it again. It touches nothing else.
    func testATransactionWritesEveryStatementOrNone() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()

        let table = "rowset_edit_test_\(UUID().uuidString.prefix(8).lowercased())"
        let qualified = SQLBuilder.qualifiedName(schema: "public", table: table)

        _ = try await session.query(
            "CREATE TABLE \(qualified) (id integer PRIMARY KEY, note text)", maxRows: 1)
        defer {
            Task {
                _ = try? await session.query("DROP TABLE IF EXISTS \(qualified)", maxRows: 1)
                await session.close()
            }
        }
        _ = try await session.query(
            "INSERT INTO \(qualified) VALUES (1, 'one'), (2, 'two')", maxRows: 1)

        // Two rows change together.
        try await session.runTransaction([
            SQLBuilder.update(
                schema: "public", table: table,
                set: [SQLBuilder.Assignment(column: "note", value: "changed")],
                key: [SQLBuilder.Assignment(column: "id", value: "1")]),
            SQLBuilder.update(
                schema: "public", table: table,
                set: [SQLBuilder.Assignment(column: "note", value: nil)],
                key: [SQLBuilder.Assignment(column: "id", value: "2")]),
        ])

        let after = try await session.queryStrings(
            "SELECT id, note FROM \(qualified) ORDER BY id")
        XCTAssertEqual(after, [["1", "changed"], ["2", ""]], "one changed, one set to NULL")

        // A key that matches no row must leave everything as it was.
        do {
            try await session.runTransaction([
                SQLBuilder.update(
                    schema: "public", table: table,
                    set: [SQLBuilder.Assignment(column: "note", value: "first")],
                    key: [SQLBuilder.Assignment(column: "id", value: "1")]),
                SQLBuilder.update(
                    schema: "public", table: table,
                    set: [SQLBuilder.Assignment(column: "note", value: "ghost")],
                    key: [SQLBuilder.Assignment(column: "id", value: "999")]),
            ])
            XCTFail("a statement that matched no row should have stopped the batch")
        } catch {
            let message = DatabaseErrorText.describe(error)
            XCTAssertTrue(message.contains("0 rows"), "unexpected message: \(message)")
        }

        let rolledBack = try await session.queryStrings(
            "SELECT id, note FROM \(qualified) ORDER BY id")
        XCTAssertEqual(rolledBack, [["1", "changed"], ["2", ""]], "the batch rolled back whole")
    }

    /// The primary key query must name the columns an UPDATE can key on.
    func testThePrimaryKeyOfARealTable() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()

        let table = "rowset_key_test_\(UUID().uuidString.prefix(8).lowercased())"
        let qualified = SQLBuilder.qualifiedName(schema: "public", table: table)
        _ = try await session.query(
            "CREATE TABLE \(qualified) (a integer, b text, v text, PRIMARY KEY (a, b))",
            maxRows: 1)
        defer {
            Task {
                _ = try? await session.query("DROP TABLE IF EXISTS \(qualified)", maxRows: 1)
                await session.close()
            }
        }

        let key = try await session.queryStrings(
            CatalogQueries.primaryKey(.postgres, schema: "public", table: table))
        XCTAssertEqual(key.map { $0[0] }, ["a", "b"], "both columns, in key order")
    }

    /// Walks the pages of a table of its own, and checks the count against them.
    func testPagesWalkTheWholeTable() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()

        let table = "rowset_page_test_\(UUID().uuidString.prefix(8).lowercased())"
        let qualified = SQLBuilder.qualifiedName(schema: "public", table: table)
        _ = try await session.query(
            "CREATE TABLE \(qualified) (id integer PRIMARY KEY)", maxRows: 1)
        defer {
            Task {
                _ = try? await session.query("DROP TABLE IF EXISTS \(qualified)", maxRows: 1)
                await session.close()
            }
        }
        _ = try await session.query(
            "INSERT INTO \(qualified) SELECT generate_series(1, 12)", maxRows: 1)

        let pageSize = 5
        var seen: [String] = []
        var offset = 0
        var pages = 0

        // The query asks for one row over the page, which is what says more follow.
        while pages < 10 {
            let sql = SQLBuilder.selectRows(
                schema: "public", table: table, filter: "", orderBy: "id ASC",
                limit: pageSize + 1, offset: offset)
            let rows = try await session.queryStrings(sql)
            pages += 1

            let hasMore = rows.count > pageSize
            seen.append(contentsOf: rows.prefix(pageSize).map { $0[0] })
            guard hasMore else { break }
            offset += pageSize
        }

        XCTAssertEqual(pages, 3, "12 rows in pages of 5")
        XCTAssertEqual(seen, (1...12).map(String.init), "every row once, in order")

        let count = try await session.queryStrings(
            SQLBuilder.countRows(schema: "public", table: table, filter: ""))
        XCTAssertEqual(count.first?.first, "12")

        let filtered = try await session.queryStrings(
            SQLBuilder.countRows(schema: "public", table: table, filter: "id > 8"))
        XCTAssertEqual(filtered.first?.first, "4", "the count keeps the filter")
    }

    /// A console pages a statement by wrapping it, so the wrapper must give the same rows.
    func testAWrappedStatementPagesTheSameRows() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        addTeardownBlock { await session.close() }

        let statement = "SELECT generate_series(1, 12) AS n ORDER BY n"

        var seen: [String] = []
        var offset = 0
        while offset < 40 {
            let sql = SQLBuilder.page(statement, limit: 6, offset: offset)
            let rows = try await session.queryStrings(sql)
            let hasMore = rows.count > 5
            seen.append(contentsOf: rows.prefix(5).map { $0[0] })
            guard hasMore else { break }
            offset += 5
        }

        XCTAssertEqual(seen, (1...12).map(String.init), "every row once, in order")

        let count = try await session.queryStrings(SQLBuilder.countOf(statement))
        XCTAssertEqual(count.first?.first, "12", "the count wraps the same statement")
    }

    /// A CTE and a VALUES list must survive the wrapper as well.
    func testTheWrapperTakesOtherReadingStatements() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        addTeardownBlock { await session.close() }

        let cte = "WITH x AS (SELECT 1 AS a UNION SELECT 2) SELECT * FROM x ORDER BY a"
        let fromCTE = try await session.queryStrings(
            SQLBuilder.page(cte, limit: 10, offset: 0))
        XCTAssertEqual(fromCTE.map { $0[0] }, ["1", "2"])

        let values = "VALUES (1), (2), (3)"
        let fromValues = try await session.queryStrings(
            SQLBuilder.page(values, limit: 2, offset: 1))
        XCTAssertEqual(fromValues.count, 2, "an offset of one leaves two of three")
    }

    /// Reads every array type the app is likely to meet, from the server itself.
    func testArraysComeBackAsLists() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        addTeardownBlock { await session.close() }

        let result = try await session.query(
            """
            SELECT ARRAY[1, 2, 3]::smallint[],
                   ARRAY['2022-09-02 14:36:20.896927+00',
                         '2022-09-03 14:36:20.896927+00']::timestamptz[],
                   ARRAY['a', 'b c']::text[],
                   ARRAY[1, NULL]::integer[],
                   '{}'::integer[],
                   '{"a": 1}'::jsonb
            """,
            maxRows: 1)

        let row = try XCTUnwrap(result.rows.first)
        XCTAssertEqual(row.values[0].text, "{1,2,3}")

        let timestamps = row.values[1].text
        XCTAssertTrue(timestamps.hasPrefix("{"), "a list and not a byte dump: \(timestamps)")
        XCTAssertTrue(timestamps.contains("2022-09-02"), timestamps)
        XCTAssertTrue(timestamps.contains("2022-09-03"), timestamps)
        XCTAssertFalse(timestamps.hasPrefix("\\x"), "it must not fall back to hex")

        XCTAssertEqual(row.values[2].text, "{a,\"b c\"}")
        XCTAssertEqual(row.values[3].text, "{1,NULL}")
        XCTAssertEqual(row.values[4].text, "{}")
        XCTAssertEqual(row.values[5].text, "{\"a\": 1}")
        XCTAssertFalse(row.values[5].isRaw, "jsonb reads as text, so it can be edited")
    }

    /// A console sorts on the wrapper, so the order must hold across the whole result and not
    /// only inside the page.
    func testTheWrapperSortsTheWholeResult() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        addTeardownBlock { await session.close() }

        let statement = "SELECT generate_series(1, 10) AS n"

        let firstPage = try await session.queryStrings(
            SQLBuilder.page(statement, limit: 3, offset: 0, orderBy: "\"n\" DESC"))
        XCTAssertEqual(firstPage.map { $0[0] }, ["10", "9", "8"], "the largest come first")

        let secondPage = try await session.queryStrings(
            SQLBuilder.page(statement, limit: 3, offset: 3, orderBy: "\"n\" DESC"))
        XCTAssertEqual(secondPage.map { $0[0] }, ["7", "6", "5"], "the order runs across pages")

        let ascending = try await session.queryStrings(
            SQLBuilder.page(statement, limit: 3, offset: 0, orderBy: "\"n\" ASC"))
        XCTAssertEqual(ascending.map { $0[0] }, ["1", "2", "3"])
    }

    func testAWrongStatementKeepsTheConnectionOpen() async throws {
        let bookmark = try liveBookmark()
        let session = PostgresSession(bookmark: bookmark)
        try await session.connect()
        addTeardownBlock { await session.close() }

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
        addTeardownBlock { await session.close() }

        // The statement offers 1000 rows. The session must read 10 and cancel the rest.
        let result = try await session.query("SELECT generate_series(1, 1000)", maxRows: 10)
        XCTAssertEqual(result.rows.count, 10)
        XCTAssertTrue(result.truncated)

        let after = try await session.query("SELECT 42", maxRows: 1)
        XCTAssertEqual(after.rows.first?.values.first?.text, "42")
    }
}
