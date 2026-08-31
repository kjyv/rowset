import XCTest
@testable import Rowset

final class UpdateStatementTests: XCTestCase {

    func testOneColumnAndOneKey() {
        let sql = SQLBuilder.update(
            schema: "public",
            table: "component",
            set: [SQLBuilder.Assignment(column: "slug", value: "new")],
            key: [SQLBuilder.Assignment(column: "id", value: "42")])

        XCTAssertEqual(sql, """
            UPDATE "public"."component"
            SET "slug" = 'new'
            WHERE "id" = '42'
            RETURNING 1
            """)
    }

    func testAMissingValueBecomesNullAndNotTheWordNull() {
        let sql = SQLBuilder.update(
            schema: "public", table: "t",
            set: [SQLBuilder.Assignment(column: "note", value: nil)],
            key: [SQLBuilder.Assignment(column: "id", value: "1")])
        XCTAssertTrue(sql.contains("SET \"note\" = NULL"))
        XCTAssertFalse(sql.contains("'NULL'"))
    }

    func testTheWordNullStaysText() {
        let sql = SQLBuilder.update(
            schema: "public", table: "t",
            set: [SQLBuilder.Assignment(column: "note", value: "NULL")],
            key: [SQLBuilder.Assignment(column: "id", value: "1")])
        XCTAssertTrue(sql.contains("SET \"note\" = 'NULL'"))
    }

    func testAQuoteInAValueIsEscaped() {
        let sql = SQLBuilder.update(
            schema: "public", table: "t",
            set: [SQLBuilder.Assignment(column: "note", value: "O'Brien")],
            key: [SQLBuilder.Assignment(column: "id", value: "1")])
        XCTAssertTrue(sql.contains("'O''Brien'"))
    }

    func testAKeyOfMoreThanOneColumn() {
        let sql = SQLBuilder.update(
            schema: "public", table: "t",
            set: [SQLBuilder.Assignment(column: "v", value: "x")],
            key: [
                SQLBuilder.Assignment(column: "a", value: "1"),
                SQLBuilder.Assignment(column: "b", value: "2"),
            ])
        XCTAssertTrue(sql.contains("WHERE \"a\" = '1' AND \"b\" = '2'"))
    }

    func testEveryStatementReturnsARowToCount() {
        let sql = SQLBuilder.update(
            schema: "s", table: "t",
            set: [SQLBuilder.Assignment(column: "v", value: "x")],
            key: [SQLBuilder.Assignment(column: "id", value: "1")])
        XCTAssertTrue(sql.hasSuffix("RETURNING 1"), "the count says whether one row was hit")
    }

    func testThePrimaryKeyQueryAsksForOneTable() {
        let sql = CatalogQueries.primaryKey(schema: "public", table: "component")
        XCTAssertTrue(sql.contains("'\"public\".\"component\"'::regclass"))
        XCTAssertTrue(sql.contains("i.indisprimary"))
        XCTAssertTrue(sql.contains("array_position"), "the key keeps its column order")
    }
}

@MainActor
final class TabEditTests: XCTestCase {

    private func tab(withKey key: [String] = ["id"]) -> QueryTab {
        let tab = QueryTab(
            connectionID: UUID(),
            connectionName: "testing",
            kind: .table(schema: "public", name: "component"),
            rowLimit: 50)
        tab.primaryKey = key

        var result = ResultSet()
        result.columns = [
            ResultColumn(id: 0, name: "id", typeName: "integer"),
            ResultColumn(id: 1, name: "slug", typeName: "text"),
        ]
        result.rows = [
            ResultRow(id: 0, values: [DisplayValue.make(text: "1"), DisplayValue.make(text: "a")]),
            ResultRow(id: 1, values: [DisplayValue.make(text: "2"), .null]),
        ]
        tab.result = result
        return tab
    }

    private func address(_ row: Int, _ column: Int) -> CellAddress {
        CellAddress(rowID: row, columnID: column)
    }

    func testATableWithAKeyIsEditable() {
        XCTAssertTrue(tab().isEditable)
    }

    func testATableWithoutAKeyIsNotEditable() {
        XCTAssertFalse(tab(withKey: []).isEditable)
    }

    func testAQueryTabIsNeverEditable() {
        let query = QueryTab(
            connectionID: UUID(), connectionName: "t", kind: .sql, rowLimit: 50)
        query.primaryKey = ["id"]
        XCTAssertFalse(query.isEditable)
    }

    func testAnEditIsRemembered() {
        let tab = tab()
        tab.setEdit("b", at: address(0, 1))
        XCTAssertTrue(tab.hasEdits)
        XCTAssertTrue(tab.isEdited(address(0, 1)))
        XCTAssertEqual(tab.pendingText(at: address(0, 1)), "b")
    }

    /// Typing the value back means nothing changed, so no statement should mention it.
    func testAnEditBackToTheOriginalDisappears() {
        let tab = tab()
        tab.setEdit("b", at: address(0, 1))
        tab.setEdit("a", at: address(0, 1))
        XCTAssertFalse(tab.hasEdits)
    }

    func testAnEditToNullIsKept() {
        let tab = tab()
        tab.setEdit(nil, at: address(0, 1))
        XCTAssertTrue(tab.isEdited(address(0, 1)))
        XCTAssertNil(tab.pendingText(at: address(0, 1)))
    }

    /// A cell that already holds NULL and stays NULL is not a change.
    func testNullToNullIsNoEdit() {
        let tab = tab()
        tab.setEdit(nil, at: address(1, 1))
        XCTAssertFalse(tab.hasEdits)
    }

    func testDiscardClearsEverything() {
        let tab = tab()
        tab.setEdit("b", at: address(0, 1))
        tab.setEdit("c", at: address(1, 1))
        XCTAssertEqual(tab.edits.count, 2)
        tab.discardEdits()
        XCTAssertFalse(tab.hasEdits)
    }
}
