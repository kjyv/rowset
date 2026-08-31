import XCTest
@testable import Rowset

final class PageSQLTests: XCTestCase {

    func testTheFirstPageAsksForNoOffset() {
        let sql = SQLBuilder.selectRows(
            schema: "public", table: "batch", filter: "", orderBy: "", limit: 26, offset: 0)
        XCTAssertFalse(sql.contains("OFFSET"))
        XCTAssertTrue(sql.hasSuffix("LIMIT 26"))
    }

    func testALaterPageAsksForAnOffset() {
        let sql = SQLBuilder.selectRows(
            schema: "public", table: "batch", filter: "", orderBy: "", limit: 26, offset: 50)
        XCTAssertEqual(sql, """
            SELECT * FROM "public"."batch"
            LIMIT 26
            OFFSET 50
            """)
    }

    func testTheOffsetComesAfterTheFilterAndTheSort() {
        let sql = SQLBuilder.selectRows(
            schema: "public", table: "batch", filter: "id > 1", orderBy: "id DESC",
            limit: 26, offset: 50)
        XCTAssertEqual(sql, """
            SELECT * FROM "public"."batch"
            WHERE id > 1
            ORDER BY id DESC
            LIMIT 26
            OFFSET 50
            """)
    }

    func testTheCountKeepsTheFilterAndDropsTheSort() {
        let sql = SQLBuilder.countRows(schema: "public", table: "batch", filter: "id > 1")
        XCTAssertEqual(sql, """
            SELECT count(*) FROM "public"."batch"
            WHERE id > 1
            """)
    }

    func testACountWithoutAFilter() {
        XCTAssertEqual(
            SQLBuilder.countRows(schema: "public", table: "batch", filter: "  "),
            "SELECT count(*) FROM \"public\".\"batch\"")
    }
}

@MainActor
final class PageStateTests: XCTestCase {

    private func tab(rows: Int, limit: Int = 25, offset: Int = 0) -> QueryTab {
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "t",
            kind: .table(schema: "public", name: "batch"), rowLimit: limit)
        tab.pageOffset = offset

        var result = ResultSet()
        result.columns = [ResultColumn(id: 0, name: "id", typeName: "integer")]
        result.rows = (0..<rows).map {
            ResultRow(id: $0, values: [DisplayValue.make(text: "\($0)")])
        }
        tab.result = result
        return tab
    }

    func testTheRangeOfTheFirstPage() {
        XCTAssertEqual(tab(rows: 25).pageRange, "1-25")
    }

    func testTheRangeOfALaterPage() {
        XCTAssertEqual(tab(rows: 25, offset: 50).pageRange, "51-75")
    }

    func testTheRangeOfAnEmptyPage() {
        XCTAssertEqual(tab(rows: 0).pageRange, "0")
    }

    /// Until a count runs, the number carries a plus. The extra row of every page pays for it.
    func testTheTotalCarriesAPlusUntilCounted() {
        let tab = tab(rows: 25)
        tab.hasMoreRows = true
        XCTAssertEqual(tab.totalDescription, "25+")
    }

    func testTheLastPageNeedsNoPlus() {
        let tab = tab(rows: 12, offset: 25)
        tab.hasMoreRows = false
        XCTAssertEqual(tab.totalDescription, "37")
    }

    func testACountReplacesThePlus() {
        let tab = tab(rows: 25)
        tab.hasMoreRows = true
        tab.totalRows = 812
        XCTAssertEqual(tab.totalDescription, "812")
    }

    func testTheFirstPageKnowsItIsFirst() {
        XCTAssertTrue(tab(rows: 25).isFirstPage)
        XCTAssertFalse(tab(rows: 25, offset: 25).isFirstPage)
    }

    /// Without a count, the extra row is the only thing that says another page follows.
    func testTheLastPageWithoutACount() {
        let more = tab(rows: 25)
        more.hasMoreRows = true
        XCTAssertFalse(more.isLastPage)

        let end = tab(rows: 3, offset: 25)
        end.hasMoreRows = false
        XCTAssertTrue(end.isLastPage)
    }

    func testTheOffsetOfTheLastPage() {
        let tab = tab(rows: 25, limit: 25)
        tab.totalRows = 812
        XCTAssertEqual(tab.lastPageOffset, 800, "rows 801 to 812")
    }

    func testTheOffsetOfTheLastPageOnAnExactFit() {
        let tab = tab(rows: 25, limit: 25)
        tab.totalRows = 50
        XCTAssertEqual(tab.lastPageOffset, 25, "not 50, which would be an empty page")
    }

    func testAnEmptyTableHasNoLastPage() {
        let tab = tab(rows: 0)
        tab.totalRows = 0
        XCTAssertNil(tab.lastPageOffset)
    }

    func testResettingForgetsThePageAndTheCount() {
        let tab = tab(rows: 25, offset: 100)
        tab.hasMoreRows = true
        tab.totalRows = 812

        tab.resetPaging()
        XCTAssertEqual(tab.pageOffset, 0)
        XCTAssertFalse(tab.hasMoreRows)
        XCTAssertNil(tab.totalRows, "a new filter makes the old count wrong")
    }
}

final class PageableStatementTests: XCTestCase {

    func testAStatementThatReadsCanBePaged() {
        XCTAssertTrue(SQLStatementSplitter.isPageable("SELECT 1"))
        XCTAssertTrue(SQLStatementSplitter.isPageable("select * from t"))
        XCTAssertTrue(SQLStatementSplitter.isPageable("WITH x AS (SELECT 1) SELECT * FROM x"))
        XCTAssertTrue(SQLStatementSplitter.isPageable("VALUES (1), (2)"))
        XCTAssertTrue(SQLStatementSplitter.isPageable("TABLE batch"))
    }

    /// Wrapping any of these would break them, so they run as they stand and show no widget.
    func testAStatementThatWritesCannotBePaged() {
        XCTAssertFalse(SQLStatementSplitter.isPageable("INSERT INTO t VALUES (1)"))
        XCTAssertFalse(SQLStatementSplitter.isPageable("UPDATE t SET a = 1"))
        XCTAssertFalse(SQLStatementSplitter.isPageable("DELETE FROM t"))
        XCTAssertFalse(SQLStatementSplitter.isPageable("CREATE TABLE t (a int)"))
        XCTAssertFalse(SQLStatementSplitter.isPageable("EXPLAIN SELECT 1"))
        XCTAssertFalse(SQLStatementSplitter.isPageable("VACUUM"))
        XCTAssertFalse(SQLStatementSplitter.isPageable(""))
    }

    func testACommentBeforeTheStatementDoesNotHideIt() {
        XCTAssertTrue(SQLStatementSplitter.isPageable("-- note\nSELECT 1"))
        XCTAssertTrue(SQLStatementSplitter.isPageable("/* note */ SELECT 1"))
    }

    func testTheWrapperNamesTheSubquery() {
        XCTAssertEqual(SQLBuilder.page("SELECT 1", limit: 26, offset: 0), """
            SELECT * FROM (
            SELECT 1
            ) AS _rowset_page
            LIMIT 26
            """)
    }

    func testTheWrapperCarriesTheOrder() {
        XCTAssertEqual(
            SQLBuilder.page("SELECT 1 AS a", limit: 26, offset: 0, orderBy: "\"a\" DESC"),
            """
            SELECT * FROM (
            SELECT 1 AS a
            ) AS _rowset_page
            ORDER BY "a" DESC
            LIMIT 26
            """)
    }

    /// The order has to sit on the wrapper. Inside the statement it would sort the page you are
    /// on and not the whole result.
    func testTheOrderComesBeforeTheLimit() {
        let sql = SQLBuilder.page("SELECT 1", limit: 10, offset: 20, orderBy: "\"a\" ASC")
        let order = try? XCTUnwrap(sql.range(of: "ORDER BY"))
        let limit = try? XCTUnwrap(sql.range(of: "LIMIT"))
        XCTAssertNotNil(order)
        XCTAssertNotNil(limit)
        XCTAssertTrue(order!.lowerBound < limit!.lowerBound)
        XCTAssertTrue(sql.hasSuffix("OFFSET 20"))
    }

    func testNoOrderLeavesTheWrapperPlain() {
        let sql = SQLBuilder.page("SELECT 1", limit: 26, offset: 0, orderBy: "   ")
        XCTAssertFalse(sql.contains("ORDER BY"))
    }

    func testTheWrapperAddsAnOffsetOnlyWhenItNeedsOne() {
        let later = SQLBuilder.page("SELECT 1", limit: 26, offset: 50)
        XCTAssertTrue(later.hasSuffix("LIMIT 26\nOFFSET 50"))
    }

    func testTheCountWrapsTheSameWay() {
        XCTAssertEqual(SQLBuilder.countOf("SELECT 1"), """
            SELECT count(*) FROM (
            SELECT 1
            ) AS _rowset_page
            """)
    }

    /// The wrapper must stay one statement, or Run would send two.
    func testTheWrappedStatementIsStillOne() {
        let sql = SQLBuilder.page("SELECT 'a;b'", limit: 26, offset: 0)
        XCTAssertEqual(SQLStatementSplitter.statements(in: sql).count, 1)
    }
}

@MainActor
final class ConsoleSortTests: XCTestCase {

    private func model() -> AppModel {
        let folder = FileManager.default.temporaryDirectory
        let suffix = UUID().uuidString
        return AppModel(
            store: BookmarkStore(fileURL: folder.appending(path: "b-\(suffix).json")),
            sessionStore: SessionStore(fileURL: folder.appending(path: "s-\(suffix).json")),
            bufferStore: BufferStore(fileURL: folder.appending(path: "c-\(suffix).json")))
    }

    private func consoleTab() -> QueryTab {
        QueryTab(connectionID: UUID(), connectionName: "t", kind: .sql, rowLimit: 25)
    }

    func testAHeaderSortBecomesAQuotedOrder() {
        let model = model()
        let tab = consoleTab()
        tab.sortOrder = [ColumnComparator(columnName: "created_at", order: .reverse)]

        XCTAssertEqual(model.consoleOrderBy(for: tab), "\"created_at\" DESC")
    }

    func testAnOddColumnNameIsStillQuoted() {
        let model = model()
        let tab = consoleTab()
        tab.sortOrder = [ColumnComparator(columnName: "odd name", order: .forward)]

        // A name with a space cannot be read back as one word, so no arrow and no order.
        XCTAssertEqual(model.consoleOrderBy(for: tab), "")
    }

    func testNoSortGivesNoOrder() {
        XCTAssertEqual(model().consoleOrderBy(for: consoleTab()), "")
    }
}
