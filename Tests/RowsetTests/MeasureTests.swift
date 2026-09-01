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

    /// The table to measure. Without it there is nothing to time, so the test skips.
    private func measureTable() throws -> String {
        guard let table = ProcessInfo.processInfo.environment["ROWSET_MEASURE_TABLE"],
            !table.isEmpty
        else {
            throw XCTSkip("ROWSET_MEASURE_TABLE is not set")
        }
        return table
    }

    /// How many rows one page holds. The app defaults to 25 and the query asks for one more.
    private static var measureLimit: Int {
        Int(ProcessInfo.processInfo.environment["ROWSET_MEASURE_LIMIT"] ?? "") ?? 25
    }

    /// A tab built the way the app builds one, so a test asks the app what it sends.
    @MainActor
    private static func tab(table: String, details: [ColumnInfo], key: [String]) -> QueryTab {
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "measure",
            kind: .table(schema: "public", name: table), rowLimit: measureLimit)
        tab.primaryKey = key
        tab.knownColumns = details.enumerated().map {
            ResultColumn(id: $0.offset, name: $0.element.name, typeName: $0.element.typeName)
        }
        tab.columnInfo = Dictionary(uniqueKeysWithValues: details.map { ($0.name, $0) })
        return tab
    }

    private func columns(_ session: PostgresSession, table: String) async throws -> [ColumnInfo] {
        let rows = try await session.queryStrings(
            CatalogQueries.columns(schema: "public", table: table))
        return rows.compactMap { row in
            guard row.count >= 3 else { return nil }
            let declared = row.count >= 4 ? (Int(row[3]) ?? -1) : -1
            return ColumnInfo(
                name: row[0],
                typeName: row[1],
                isNullable: row[2].uppercased() == "YES",
                maximumLength: declared < 0 ? nil : declared)
        }
    }

    /// What the catalog already knows about the width of each column.
    func testTheCatalogKnowsTheWidths() async throws {
        let table = try measureTable()
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
        let table = try measureTable()
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

    /// Prints every statement the app sends when a table opens.
    func testTheStatementsOfOpeningATable() async throws {
        let table = try measureTable()
        let session = PostgresSession(bookmark: try liveBookmark())
        try await session.connect()
        defer { Task { await session.close() } }

        let details = try await columns(session, table: table)
        let keyRows = try await session.queryStrings(
            CatalogQueries.primaryKey(schema: "public", table: table))
        let key = keyRows.compactMap(\.first)

        func show(_ title: String, _ sql: String) {
            print("SQL ---------- \(title)")
            for line in sql.split(separator: "\n", omittingEmptySubsequences: false) {
                print("SQL \(line)")
            }
        }

        show("1. the columns", CatalogQueries.columns(schema: "public", table: table))
        show("2. the primary key", CatalogQueries.primaryKey(schema: "public", table: table))

        let tab = await MainActor.run { Self.tab(table: table, details: details, key: key) }
        let limit = Self.measureLimit + 1
        let sql = await MainActor.run {
            SQLBuilder.selectRows(
                schema: "public", table: table, filter: "", orderBy: "", limit: limit,
                expressions: tab.selectExpressions)
        }
        show("3. the page", sql)

        // Which large columns hold nothing big on this page.
        let page = try await session.query(sql, maxRows: limit)

        var largest: [String: Int] = [:]
        for row in page.rows {
            for (index, column) in page.columns.enumerated() {
                guard index < row.values.count, !row.value(at: index).isNull,
                      let bytes = Int(row.value(at: index).text)
                else { continue }
                largest[column.name] = max(largest[column.name] ?? 0, bytes)
            }
        }

        let (cut, small) = await MainActor.run { () -> ([String], [String]) in
            var copy = page
            return (details.map(\.name).filter(tab.cuts), tab.markCutValues(in: &copy))
        }
        let big = cut.filter { !small.contains($0) }

        print("SQL ---------- the sizes of this page")
        for name in cut {
            print("SQL   \(name): largest \(DisplayValue.sizeText(largest[name] ?? 0))")
        }
        print("SQL   read whole: \(small.joined(separator: ", "))")
        print("SQL   left behind: \(big.joined(separator: ", "))")

        if !small.isEmpty {
            show("4. the columns worth reading", SQLBuilder.selectRows(
                schema: "public", table: table, filter: "", orderBy: "", limit: limit,
                columns: key + small))
        }

        show("5. one row, on a click", """
            SELECT \(details.map { SQLBuilder.quoteIdentifier($0.name) }.joined(separator: ", "))
            FROM \(SQLBuilder.qualifiedName(schema: "public", table: table))
            WHERE \(key.map { "\(SQLBuilder.quoteIdentifier($0)) = 'the key'" }
                    .joined(separator: " AND "))
            LIMIT 1
            """)
        show("6. the count, only when you press it",
             SQLBuilder.countRows(schema: "public", table: table, filter: ""))
    }

    /// The grid query must not read a large value, whatever the page size.
    func testTheGridQueryNeverReadsALargeValue() async throws {
        let table = try measureTable()
        let session = PostgresSession(bookmark: try liveBookmark())
        try await session.connect()
        defer { Task { await session.close() } }

        let details = try await columns(session, table: table)
        let keyRows = try await session.queryStrings(
            CatalogQueries.primaryKey(schema: "public", table: table))
        let key = keyRows.compactMap(\.first)
        let tab = await MainActor.run { Self.tab(table: table, details: details, key: key) }
        let (large, expressions) = await MainActor.run {
            (details.map(\.name).filter(tab.cuts), tab.selectExpressions)
        }
        XCTAssertFalse(large.isEmpty, "\(table) has no large column to measure")

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

    /// The page and the second query must agree on which rows they mean.
    ///
    /// The second query used to be the page query with another select list. Two runs of one
    /// statement need not agree on order, so the rows did not line up and the cells kept their
    /// stand-in. The query now names the rows of the page by their key.
    func testTheSmallColumnsOfAPageComeBack() async throws {
        let table = try measureTable()
        let session = PostgresSession(bookmark: try liveBookmark())
        try await session.connect()
        defer { Task { await session.close() } }

        let details = try await columns(session, table: table)
        let keyRows = try await session.queryStrings(
            CatalogQueries.primaryKey(schema: "public", table: table))
        let key = keyRows.compactMap(\.first)
        try XCTSkipIf(key.isEmpty, "\(table) has no primary key")

        let tab = await MainActor.run { Self.tab(table: table, details: details, key: key) }
        let limit = Self.measureLimit + 1
        let sql = await MainActor.run {
            SQLBuilder.selectRows(
                schema: "public", table: table, filter: "", orderBy: "", limit: limit,
                expressions: tab.selectExpressions)
        }
        let page = try await session.query(sql, maxRows: limit)
        let small = await MainActor.run { () -> [String] in
            var copy = page
            return tab.markCutValues(in: &copy)
        }
        try XCTSkipIf(small.isEmpty, "\(table) has no small column on this page")

        let keyIndexes = key.compactMap { name in
            page.columns.firstIndex { $0.name == name }
        }
        XCTAssertEqual(keyIndexes.count, key.count)
        let pageKeys = page.rows.map { row in
            keyIndexes.map { row.value(at: $0).text }.joined(separator: "\u{1}")
        }

        // What the app runs now.
        let wanted = key + small
        let byKey = try await session.query("""
            SELECT \(wanted.map(SQLBuilder.quoteIdentifier).joined(separator: ", "))
            FROM \(SQLBuilder.qualifiedName(schema: "public", table: table))
            WHERE \(SQLBuilder.keyList(key, values: page.rows.map { row in
                keyIndexes.map { row.value(at: $0).text }
            }))
            """, maxRows: page.rows.count)

        let fetchedKeys = Set(byKey.rows.map { row in
            (0..<key.count).map { row.value(at: $0).text }.joined(separator: "\u{1}")
        })
        let missing = pageKeys.filter { !fetchedKeys.contains($0) }
        print("MEASURE by key: page=\(pageKeys.count) fetched=\(byKey.rows.count)"
            + " missing=\(missing.count)")
        XCTAssertTrue(missing.isEmpty, "every row of the page must come back")

        // What it ran before, for comparison.
        let again = try await session.query(
            SQLBuilder.selectRows(
                schema: "public", table: table, filter: "", orderBy: "", limit: limit,
                columns: wanted),
            maxRows: limit)
        let againKeys = again.rows.map { row in
            (0..<key.count).map { row.value(at: $0).text }.joined(separator: "\u{1}")
        }
        let same = zip(pageKeys, againKeys).filter { $0 == $1 }.count
        print("MEASURE page query again: rows=\(againKeys.count)"
            + " in the same place=\(same) of \(pageKeys.count)")
    }

    /// A placeholder has to be able to give up the whole value again.
    func testAValueBehindAPlaceholderComesBackWhole() async throws {
        let table = try measureTable()
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
