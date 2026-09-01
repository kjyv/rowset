import XCTest
@testable import Rowset

/// Times the query the grid runs on a table of large values.
///
/// It runs only when the live environment names a table, and it writes its numbers to the log
/// with the prefix MEASURE. Each shape reads an offset the ones before it did not, so a warm
/// cache does not flatter the later runs.
final class MeasureTests: XCTestCase {

    private func liveBookmark() throws -> Bookmark {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) throws -> String {
            guard let found = environment[key], !found.isEmpty else {
                throw XCTSkip("\(key) is not set")
            }
            return found
        }
        var bookmark = Bookmark()
        bookmark.host = try value("ROWSET_LIVE_HOST")
        bookmark.database = try value("ROWSET_LIVE_DB")
        bookmark.username = try value("ROWSET_LIVE_USER")
        bookmark.awsProfile = try value("ROWSET_LIVE_PROFILE")
        bookmark.awsRegion = environment["ROWSET_LIVE_REGION"] ?? "eu-central-1"
        return bookmark
    }

    private func columns(_ session: PostgresSession, table: String) async throws -> [ColumnInfo] {
        let rows = try await session.queryStrings(
            CatalogQueries.columns(schema: "public", table: table))
        return rows.compactMap { row in
            guard row.count >= 3 else { return nil }
            return ColumnInfo(
                name: row[0], typeName: row[1], isNullable: row[2].uppercased() == "YES")
        }
    }

    /// What the catalog already knows about the width of each column.
    func testTheCatalogKnowsTheWidths() async throws {
        let table = try XCTUnwrap(ProcessInfo.processInfo.environment["ROWSET_MEASURE_TABLE"])
        let session = PostgresSession(bookmark: try liveBookmark())
        try await session.connect()
        defer { Task { await session.close() } }

        let start = DispatchTime.now()
        let rows = try await session.queryStrings("""
            SELECT a.attname, t.typname, coalesce(s.avg_width, -1)::text
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_stats s
              ON s.schemaname = n.nspname AND s.tablename = c.relname
             AND s.attname = a.attname
            WHERE n.nspname = 'public' AND c.relname = '\(table)' AND a.attnum > 0
            ORDER BY a.attnum
            """)
        let seconds = Double(
            DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

        print(String(format: "MEASURE catalog widths in %.3fs", seconds))
        for row in rows {
            print("MEASURE   \(row[0])  \(row[1])  avg_width=\(row[2])")
        }
        XCTAssertFalse(rows.isEmpty)
    }

    /// Times each large column on its own, each on rows nothing has read.
    ///
    /// The average width says these values are small, and reading them still cost minutes. This
    /// says which column is the cost and how it grows.
    func testTheCostOfEachLargeColumn() async throws {
        let table = try XCTUnwrap(ProcessInfo.processInfo.environment["ROWSET_MEASURE_TABLE"])
        let session = PostgresSession(bookmark: try liveBookmark())
        try await session.connect()
        defer { Task { await session.close() } }

        let details = try await columns(session, table: table)
        let qualified = SQLBuilder.qualifiedName(schema: "public", table: table)
        var offset = 200_000

        func time(_ label: String, _ select: String) async throws {
            offset += 3_000
            let sql = "SELECT \(select) FROM \(qualified) LIMIT 1001 OFFSET \(offset)"
            let start = DispatchTime.now()
            let result = try await session.query(sql, maxRows: 1001)
            let seconds = Double(
                DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            let bytes = result.rows.reduce(0) { total, row in
                total + row.values.reduce(0) { $0 + $1.text.utf8.count }
            }
            print(String(format: "MEASURE %-38@ %.3fs %dKB", label as NSString, seconds, bytes / 1024))
        }

        print("MEASURE --- one column at a time, 1000 rows each ---")
        try await time("nothing", "1")
        for info in details where info.isLarge {
            try await time(
                "\(info.name) [\(info.typeName)]", SQLBuilder.quoteIdentifier(info.name))
        }
    }

    /// The grid query must not read a large value, whatever the page size.
    func testTheGridQueryNeverReadsALargeValue() async throws {
        let table = try XCTUnwrap(ProcessInfo.processInfo.environment["ROWSET_MEASURE_TABLE"])
        let session = PostgresSession(bookmark: try liveBookmark())
        try await session.connect()
        defer { Task { await session.close() } }

        let details = try await columns(session, table: table)
        let large = details.filter(\.isLarge)
        XCTAssertFalse(large.isEmpty, "\(table) has no large column to measure")

        let expressions = details.map { info in
            info.isLarge
                ? SQLBuilder.sizeOfColumn(info.name)
                : SQLBuilder.quoteIdentifier(info.name)
        }

        func time(_ label: String, _ sql: String, rows: Int) async throws -> Double {
            let start = DispatchTime.now()
            let result = try await session.query(sql, maxRows: rows)
            let seconds = Double(
                DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            let bytes = result.rows.reduce(0) { total, row in
                total + row.values.reduce(0) { $0 + $1.text.utf8.count }
            }
            print(String(
                format: "MEASURE %@ %.3fs rows=%d text=%dKB",
                label, seconds, result.rows.count, bytes / 1024))
            return seconds
        }

        let qualified = SQLBuilder.qualifiedName(schema: "public", table: table)
        print("MEASURE table=\(table) columns=\(details.count) large=\(large.count)")

        let grid = SQLBuilder.selectRows(
            schema: "public", table: table, filter: "", orderBy: "", limit: 1001,
            offset: 120_000, expressions: expressions)
        let seconds = try await time("grid 1000 rows ", grid, rows: 1001)

        XCTAssertLessThan(seconds, 5, "a page of a thousand rows must not wait on the value store")
    }

    /// A placeholder has to be able to give up the whole value again.
    func testAValueBehindAPlaceholderComesBackWhole() async throws {
        let table = try XCTUnwrap(ProcessInfo.processInfo.environment["ROWSET_MEASURE_TABLE"])
        let session = PostgresSession(bookmark: try liveBookmark())
        try await session.connect()
        defer { Task { await session.close() } }

        let details = try await columns(session, table: table)
        let large = try XCTUnwrap(details.first(where: \.isLarge))
        let keyRows = try await session.queryStrings(
            CatalogQueries.primaryKey(schema: "public", table: table))
        let keyColumn = try XCTUnwrap(keyRows.first?.first)

        let qualified = SQLBuilder.qualifiedName(schema: "public", table: table)
        let name = SQLBuilder.quoteIdentifier(large.name)
        let key = SQLBuilder.quoteIdentifier(keyColumn)

        // What the grid gets: a key and a size, never a value.
        let listed = try await session.queryStrings("""
            SELECT \(key)::text, \(SQLBuilder.sizeOfColumn(large.name))
            FROM \(qualified)
            WHERE \(name) IS NOT NULL
            LIMIT 1
            """)
        let row = try XCTUnwrap(listed.first)
        let bytes = try XCTUnwrap(Int(row[1]))
        XCTAssertGreaterThan(bytes, 0)
        print("MEASURE placeholder=\(DisplayValue.sizeText(bytes)) column=\(large.name)")

        // What a click gets.
        let whole = try await session.queryStrings("""
            SELECT \(name)::text FROM \(qualified)
            WHERE \(key)::text = \(SQLBuilder.quoteLiteral(row[0]))
            LIMIT 1
            """)
        let full = try XCTUnwrap(whole.first?.first)
        XCTAssertFalse(full.isEmpty, "the click brings the value the grid never fetched")
    }
}
