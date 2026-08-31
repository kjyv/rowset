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
            schema: "public", table: "component", filter: "", orderBy: "", limit: 50)
        XCTAssertEqual(sql, "SELECT * FROM \"public\".\"component\"\nLIMIT 50")
    }

    func testSelectRowsWithFilterAndSort() {
        let sql = SQLBuilder.selectRows(
            schema: "public",
            table: "component",
            filter: "  article_identifier = '1004.1'  ",
            orderBy: "created_at DESC",
            limit: 25)

        XCTAssertEqual(sql, """
            SELECT * FROM "public"."component"
            WHERE article_identifier = '1004.1'
            ORDER BY created_at DESC
            LIMIT 25
            """)
    }

    func testSelectRowsForcesAPositiveLimit() {
        let sql = SQLBuilder.selectRows(
            schema: "s", table: "t", filter: "", orderBy: "", limit: 0)
        XCTAssertTrue(sql.hasSuffix("LIMIT 1"))
    }

    func testSelectRowsPassesAnOrderExpressionThrough() {
        let sql = SQLBuilder.selectRows(
            schema: "public", table: "t", filter: "", orderBy: " created_at DESC, id ", limit: 5)
        XCTAssertTrue(sql.contains("ORDER BY created_at DESC, id"))
    }

    func testCatalogQueriesEscapeTheSchemaName() {
        let sql = CatalogQueries.tables(schema: "it's")
        XCTAssertTrue(sql.contains("'it''s'"))
    }
}
