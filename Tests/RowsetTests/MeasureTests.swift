import XCTest
@testable import Rowset

/// Times the query the grid runs, and checks that a cut value can be fetched whole again.
///
/// It runs only when the live environment names a table, and it writes its numbers to the log
/// with the prefix MEASURE.
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

    private func columns(
        _ session: PostgresSession, table: String
    ) async throws -> [ColumnInfo] {
        let rows = try await session.queryStrings(
            CatalogQueries.columns(schema: "public", table: table))
        return rows.compactMap { row in
            guard row.count >= 3 else { return nil }
            return ColumnInfo(
                name: row[0], typeName: row[1], isNullable: row[2].uppercased() == "YES")
        }
    }

    func testTheGridQueryIsFaster() async throws {
        let table = try XCTUnwrap(ProcessInfo.processInfo.environment["ROWSET_MEASURE_TABLE"])
        let session = PostgresSession(bookmark: try liveBookmark())
        try await session.connect()
        defer { Task { await session.close() } }

        let details = try await columns(session, table: table)
        let large = details.filter(\.isLarge)
        XCTAssertFalse(large.isEmpty, "\(table) has no large column to measure")

        let expressions = details.map { info in
            info.isLarge
                ? SQLBuilder.cutColumn(info.name, to: DisplayValue.serverCutLength)
                : SQLBuilder.quoteIdentifier(info.name)
        }

        func time(_ label: String, _ sql: String) async throws -> Int {
            var best = Double.greatestFiniteMagnitude
            var bytes = 0
            for _ in 0..<3 {
                let start = DispatchTime.now()
                let result = try await session.query(sql, maxRows: 26)
                best = min(
                    best,
                    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9)
                bytes = result.rows.reduce(0) { total, row in
                    total + row.values.reduce(0) { $0 + $1.text.utf8.count }
                }
            }
            print(String(format: "MEASURE %@ best=%.3fs text=%dKB", label, best, bytes / 1024))
            return Int(best * 1000)
        }

        let qualified = SQLBuilder.qualifiedName(schema: "public", table: table)
        print("MEASURE table=\(table) columns=\(details.count) large=\(large.count)")

        let whole = try await time(
            "whole  ", "SELECT * FROM \(qualified) LIMIT 26")
        let cut = try await time(
            "cut    ",
            SQLBuilder.selectRows(
                schema: "public", table: table, filter: "", orderBy: "", limit: 26,
                expressions: expressions))

        XCTAssertLessThan(cut, whole, "asking for less must not be slower")
    }

    /// The grid must be able to get back what it left behind.
    func testACutValueComesBackWhole() async throws {
        let table = try XCTUnwrap(ProcessInfo.processInfo.environment["ROWSET_MEASURE_TABLE"])
        let session = PostgresSession(bookmark: try liveBookmark())
        try await session.connect()
        defer { Task { await session.close() } }

        let details = try await columns(session, table: table)
        let large = try XCTUnwrap(details.first(where: \.isLarge))
        let key = try await session.queryStrings(
            CatalogQueries.primaryKey(schema: "public", table: table))
        let keyColumn = try XCTUnwrap(key.first?.first)

        let qualified = SQLBuilder.qualifiedName(schema: "public", table: table)
        let name = SQLBuilder.quoteIdentifier(large.name)

        // A row whose large value really is longer than the grid asks for.
        let found = try await session.queryStrings("""
            SELECT \(SQLBuilder.quoteIdentifier(keyColumn))::text,
                   left(\(name)::text, \(DisplayValue.serverCutLength)),
                   length(\(name)::text)
            FROM \(qualified)
            WHERE length(\(name)::text) > \(DisplayValue.serverCutLength)
            LIMIT 1
            """)

        guard let row = found.first else {
            throw XCTSkip("no row of \(table) has a large \(large.name)")
        }

        let cut = row[1]
        let wholeLength = try XCTUnwrap(Int(row[2]))
        XCTAssertEqual(cut.count, DisplayValue.serverCutLength, "the grid gets the start only")

        let whole = try await session.queryStrings("""
            SELECT \(name)::text FROM \(qualified)
            WHERE \(SQLBuilder.quoteIdentifier(keyColumn))::text = \(SQLBuilder.quoteLiteral(row[0]))
            LIMIT 1
            """)
        let full = try XCTUnwrap(whole.first?.first)

        XCTAssertEqual(full.count, wholeLength, "the fetch brings the whole value")
        XCTAssertTrue(full.hasPrefix(cut), "and it starts with what the grid already had")
        print("MEASURE cut=\(cut.count) whole=\(wholeLength) column=\(large.name)")
    }
}
