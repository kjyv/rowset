import XCTest
@testable import Rowset

final class SQLBuilderTests: XCTestCase {

    func testQuoteIdentifierWrapsInDoubleQuotes() {
        XCTAssertEqual(SQLBuilder.quoteIdentifier("component"), "\"component\"")
    }

    func testQuoteIdentifierDoublesInnerQuotes() {
        XCTAssertEqual(SQLBuilder.quoteIdentifier("odd\"name"), "\"odd\"\"name\"")
    }

    func testQuoteLiteralDoublesSingleQuotes() {
        XCTAssertEqual(SQLBuilder.quoteLiteral("O'Brien"), "'O''Brien'")
    }

    func testSelectRowsWithoutFilterOrSort() {
        let sql = SQLBuilder.selectRows(
            schema: "public", table: "component", filter: "", sort: nil, limit: 50)
        XCTAssertEqual(sql, "SELECT * FROM \"public\".\"component\"\nLIMIT 50")
    }

    func testSelectRowsWithFilterAndSort() {
        let sql = SQLBuilder.selectRows(
            schema: "public",
            table: "component",
            filter: "  article_identifier = '1004.1'  ",
            sort: SortSpec(column: "created_at", ascending: false),
            limit: 25)

        XCTAssertEqual(sql, """
            SELECT * FROM "public"."component"
            WHERE article_identifier = '1004.1'
            ORDER BY "created_at" DESC
            LIMIT 25
            """)
    }

    func testSelectRowsForcesAPositiveLimit() {
        let sql = SQLBuilder.selectRows(
            schema: "s", table: "t", filter: "", sort: nil, limit: 0)
        XCTAssertTrue(sql.hasSuffix("LIMIT 1"))
    }

    func testCatalogQueriesEscapeTheSchemaName() {
        let sql = CatalogQueries.tables(schema: "it's")
        XCTAssertTrue(sql.contains("'it''s'"))
    }
}
