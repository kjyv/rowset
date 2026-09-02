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
        let sql = CatalogQueries.tables(.postgres, schema: "it's")
        XCTAssertTrue(sql.contains("'it''s'"))
    }

    // MARK: - Naming a set of rows

    func testAKeyListOfOneColumnReadsAsAnIn() {
        XCTAssertEqual(
            SQLBuilder.keyList(["slug"], values: [["a"], ["b"]]),
            #"("slug") IN (('a'), ('b'))"#)
    }

    func testAKeyListOfTwoColumnsComparesRowByRow() {
        XCTAssertEqual(
            SQLBuilder.keyList(["a", "b"], values: [["1", "2"], ["3", "4"]]),
            #"("a", "b") IN (('1', '2'), ('3', '4'))"#)
    }

    func testAKeyListQuotesAValueThatHoldsAQuote() {
        XCTAssertEqual(
            SQLBuilder.keyList(["slug"], values: [["it's"]]),
            #"("slug") IN (('it''s'))"#)
    }

    /// A page of a thousand rows names a thousand keys, and the statement must still be one list.
    func testAKeyListOfAWholePageIsWellFormed() {
        let keys = (0..<1000).map { ["row-\($0)"] }
        let sql = SQLBuilder.keyList(["slug"], values: keys)
        XCTAssertEqual(sql.filter { $0 == "," }.count, 999)
        XCTAssertTrue(sql.hasSuffix("('row-999'))"))
        XCTAssertFalse(sql.contains(", )"))
    }
}
