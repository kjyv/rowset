import SQLite3
import XCTest
@testable import Rowset

/// The SQLite driver, end to end.
///
/// A SQLite database is a file, so these tests need no server and run with the rest. They write a
/// small database, open it the way the app opens one, and read it back through the app.
final class SQLiteTests: XCTestCase {

    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rowset-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("test.sqlite")
        try write("""
            CREATE TABLE note (
              id INTEGER PRIMARY KEY,
              slug TEXT NOT NULL,
              body TEXT,
              size REAL,
              payload BLOB
            );
            CREATE VIEW note_slug AS SELECT slug FROM note;
            INSERT INTO note (id, slug, body, size, payload) VALUES
              (1, 'first', '{"a": 1}', 1.5, x'00ff'),
              (2, 'second', NULL, NULL, NULL);
            """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes the database with the C library, so the test does not lean on the code it tests.
    private func write(_ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    private func bookmark() -> Bookmark {
        var bookmark = Bookmark()
        bookmark.name = "notes"
        bookmark.driver = .sqlite
        bookmark.filePath = file.path
        return bookmark
    }

    /// A file session answers background work from the connection it already has.
    func testBackgroundWorkReadsTheFile() async throws {
        let session = SQLiteSession(bookmark: bookmark())
        try await session.connect()
        addTeardownBlock { await session.close() }

        let result = try await session.queryInBackground(
            "SELECT count(*) FROM note", maxRows: 1, expectedColumns: [])
        XCTAssertEqual(result.rows.first?.value(at: 0).text, "2")
    }

    // MARK: - Stopping a statement

    /// A statement long enough to interrupt, but bounded, so a missed interrupt fails the test
    /// instead of hanging it.
    private static let longStatement = """
        WITH RECURSIVE counter(n) AS (
          SELECT 1 UNION ALL SELECT n + 1 FROM counter WHERE n < 20000000
        )
        SELECT count(*) FROM counter
        """

    /// The actor runs sqlite3_step for the whole statement, so the cancel must not wait for it.
    func testStopEndsALongStatement() async throws {
        let session = SQLiteSession(bookmark: bookmark())
        try await session.connect()
        addTeardownBlock { await session.close() }

        let running = Task { try await session.query(Self.longStatement, maxRows: 1) }
        // Let the statement reach sqlite3_step. An interrupt before that does nothing.
        try await Task.sleep(nanoseconds: 200_000_000)
        await session.cancelRunningQuery()

        do {
            _ = try await running.value
            XCTFail("the statement should have stopped")
        } catch is QueryCanceled {
            // What Stop reports.
        }
    }

    /// The session stays usable, so the next statement needs no reconnect.
    func testTheSessionSurvivesAStop() async throws {
        let session = SQLiteSession(bookmark: bookmark())
        try await session.connect()
        addTeardownBlock { await session.close() }

        let running = Task { try await session.query(Self.longStatement, maxRows: 1) }
        try await Task.sleep(nanoseconds: 200_000_000)
        await session.cancelRunningQuery()
        _ = try? await running.value

        let result = try await session.query("SELECT count(*) FROM note", maxRows: 1)
        XCTAssertEqual(result.rows.first?.value(at: 0).text, "2")
    }

    func testAStopWithNothingRunningDoesNothing() async throws {
        let session = SQLiteSession(bookmark: bookmark())
        try await session.connect()

        await session.cancelRunningQuery()
        await session.close()
        // A closed session must not reach a handle that is gone.
        await session.cancelRunningQuery()
    }

    // MARK: - The session

    func testAFileOpensAndReadsItsRows() async throws {
        let session = SQLiteSession(bookmark: bookmark())
        try await session.connect()
        addTeardownBlock { await session.close() }

        let result = try await session.query("SELECT id, slug FROM note ORDER BY id", maxRows: 10)
        XCTAssertEqual(result.columns.map(\.name), ["id", "slug"])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].value(at: 0).text, "1")
        XCTAssertEqual(result.rows[0].value(at: 1).text, "first")
    }

    func testEveryValueTypeReadsAsText() async throws {
        let session = SQLiteSession(bookmark: bookmark())
        try await session.connect()
        addTeardownBlock { await session.close() }

        let result = try await session.query(
            "SELECT body, size, payload FROM note WHERE id = 1", maxRows: 1)
        let row = try XCTUnwrap(result.rows.first)
        XCTAssertEqual(row.value(at: 0).text, #"{"a": 1}"#)
        XCTAssertEqual(row.value(at: 1).text, "1.5")
        XCTAssertEqual(row.value(at: 2).text, "\\x00ff")
        XCTAssertTrue(row.value(at: 2).isRaw)
    }

    func testANullIsANull() async throws {
        let session = SQLiteSession(bookmark: bookmark())
        try await session.connect()
        addTeardownBlock { await session.close() }

        let result = try await session.query("SELECT body FROM note WHERE id = 2", maxRows: 1)
        XCTAssertTrue(try XCTUnwrap(result.rows.first).value(at: 0).isNull)
    }

    func testAStatementThatGivesNoRowStillNamesItsColumns() async throws {
        let session = SQLiteSession(bookmark: bookmark())
        try await session.connect()
        addTeardownBlock { await session.close() }

        let result = try await session.query("SELECT id, slug FROM note WHERE id = 99", maxRows: 5)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.columns.map(\.name), ["id", "slug"])
    }

    func testAMissingFileIsAnError() async throws {
        var missing = bookmark()
        missing.filePath = directory.appendingPathComponent("nothing.sqlite").path
        let session = SQLiteSession(bookmark: missing)
        do {
            try await session.connect()
            XCTFail("a missing file must not open")
        } catch {
            XCTAssertTrue(error is SQLiteError)
        }
    }

    /// A batch that hits the wrong number of rows must change nothing at all.
    func testATransactionRollsBackWhenAStatementMissesItsRow() async throws {
        let session = SQLiteSession(bookmark: bookmark())
        try await session.connect()
        addTeardownBlock { await session.close() }

        do {
            try await session.runTransaction([
                "UPDATE note SET slug = 'changed' WHERE id = 1 RETURNING 1",
                "UPDATE note SET slug = 'never' WHERE id = 99 RETURNING 1",
            ])
            XCTFail("the second statement matched no row")
        } catch {
            // The first statement is rolled back with the second.
        }

        let after = try await session.query("SELECT slug FROM note WHERE id = 1", maxRows: 1)
        XCTAssertEqual(try XCTUnwrap(after.rows.first).value(at: 0).text, "first")
    }

    func testATransactionCommitsWhenEveryStatementHitsOneRow() async throws {
        let session = SQLiteSession(bookmark: bookmark())
        try await session.connect()
        addTeardownBlock { await session.close() }

        try await session.runTransaction([
            "UPDATE note SET slug = 'changed' WHERE id = 1 RETURNING 1"
        ])
        let after = try await session.query("SELECT slug FROM note WHERE id = 1", maxRows: 1)
        XCTAssertEqual(try XCTUnwrap(after.rows.first).value(at: 0).text, "changed")
    }

    // MARK: - The catalog

    @MainActor
    func testTheTreeShowsTheTablesAndTheirColumns() async throws {
        let connection = ConnectionModel(bookmark: bookmark())
        await connection.connect()
        XCTAssertTrue(connection.state.isConnected, "\(connection.state)")
        addTeardownBlock { @MainActor in await connection.disconnect() }

        XCTAssertEqual(connection.schemas.map { $0.kind.title }, ["main"])

        let schema = try XCTUnwrap(connection.schemas.first)
        await connection.loadChildren(of: schema)
        let children: [TreeNode] = schema.children ?? []
        XCTAssertEqual(children.map { $0.kind.title }, ["note", "note_slug"])

        let details = await connection.columnDetails(schema: "main", table: "note")
        XCTAssertEqual(details.map(\.name), ["id", "slug", "body", "size", "payload"])
        XCTAssertEqual(details.first?.typeName, "INTEGER")
        XCTAssertEqual(details.first(where: { $0.name == "slug" })?.isNullable, false)
        XCTAssertEqual(details.first(where: { $0.name == "body" })?.isNullable, true)
    }

    // MARK: - The app

    @MainActor
    func testATableTabReadsItsRows() async throws {
        let model = AppModel(
            store: BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json")),
            sessionStore: SessionStore(fileURL: directory.appendingPathComponent("session.json")),
            bufferStore: BufferStore(fileURL: directory.appendingPathComponent("consoles.json")))
        let connection = ConnectionModel(bookmark: bookmark())
        model.connections[connection.id] = connection
        await connection.connect()
        addTeardownBlock { @MainActor in await connection.disconnect() }

        let tab = model.openTable(schema: "main", name: "note", connection: connection)
        await model.runTableQuery(tab)

        let result = try XCTUnwrap(tab.result)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(tab.primaryKey, ["id"])

        // Nothing is left on the server. A file on this machine is read whole.
        XCTAssertFalse(tab.cutsLargeValues)
        XCTAssertFalse(result.rows.contains { $0.values.contains { $0.isPlaceholder } })
    }

    /// A column added since the tab opened must reach the grid on Refresh.
    ///
    /// Sorting by name names every column in the SELECT, the way a Postgres table does once it
    /// cuts a large value. A stale column list then leaves the new column out of the statement.
    @MainActor
    func testRefreshShowsAColumnAddedSinceTheTabOpened() async throws {
        let model = AppModel(
            store: BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json")),
            sessionStore: SessionStore(fileURL: directory.appendingPathComponent("session.json")),
            bufferStore: BufferStore(fileURL: directory.appendingPathComponent("consoles.json")))
        let connection = ConnectionModel(bookmark: bookmark())
        model.connections[connection.id] = connection
        await connection.connect()
        addTeardownBlock { @MainActor in await connection.disconnect() }

        let tab = model.openTable(schema: "main", name: "note", connection: connection)
        tab.sortsColumnsByName = true
        await model.runTableQuery(tab)
        XCTAssertFalse(tab.knownColumns.contains { $0.name == "author" })

        try write("ALTER TABLE note ADD COLUMN author TEXT")
        await model.refreshTable(tab)

        XCTAssertTrue(
            tab.knownColumns.contains { $0.name == "author" }, "the catalog was not read again")
        let result = try XCTUnwrap(tab.result)
        XCTAssertTrue(
            result.columns.contains { $0.name == "author" },
            "the new column never reached the grid")
    }

    /// The tree shows the new column too, without a second trip to the catalog.
    @MainActor
    func testRefreshUpdatesTheColumnsInTheTree() async throws {
        let model = AppModel(
            store: BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json")),
            sessionStore: SessionStore(fileURL: directory.appendingPathComponent("session.json")),
            bufferStore: BufferStore(fileURL: directory.appendingPathComponent("consoles.json")))
        let connection = ConnectionModel(bookmark: bookmark())
        model.connections[connection.id] = connection
        await connection.connect()
        addTeardownBlock { @MainActor in await connection.disconnect() }

        let schemaNode = try XCTUnwrap(connection.schemas.first)
        await connection.loadChildren(of: schemaNode)
        let tableNode = try XCTUnwrap(schemaNode.children?.first { $0.kind.title == "note" })
        await connection.loadChildren(of: tableNode)
        XCTAssertFalse(tableNode.children?.contains { $0.kind.title == "author" } ?? true)

        let tab = model.openTable(schema: "main", name: "note", connection: connection)
        await model.runTableQuery(tab)

        try write("ALTER TABLE note ADD COLUMN author TEXT")
        await model.refreshTable(tab)

        XCTAssertTrue(
            tableNode.children?.contains { $0.kind.title == "author" } ?? false,
            "the tree still shows the old columns")
    }

    @MainActor
    func testAFilterAndASortReachTheFile() async throws {
        let model = AppModel(
            store: BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json")),
            sessionStore: SessionStore(fileURL: directory.appendingPathComponent("session.json")),
            bufferStore: BufferStore(fileURL: directory.appendingPathComponent("consoles.json")))
        let connection = ConnectionModel(bookmark: bookmark())
        model.connections[connection.id] = connection
        await connection.connect()
        addTeardownBlock { @MainActor in await connection.disconnect() }

        let tab = model.openTable(schema: "main", name: "note", connection: connection)
        tab.filterText = "id = 2"
        tab.orderByText = "slug DESC"
        await model.runTableQuery(tab)

        let result = try XCTUnwrap(tab.result)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].value(at: 1).text, "second")
    }
}
