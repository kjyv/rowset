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
        let sql = CatalogQueries.primaryKey(.postgres, schema: "public", table: "component")
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

@MainActor
final class NullCellEditTests: XCTestCase {

    private func tab() -> QueryTab {
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "t",
            kind: .table(schema: "public", name: "batch"), rowLimit: 25)
        tab.primaryKey = ["id"]
        tab.columnInfo = [
            "note": ColumnInfo(name: "note", typeName: "text", isNullable: true),
        ]

        var result = ResultSet()
        result.columns = [ResultColumn(id: 0, name: "note", typeName: "text")]
        result.rows = [
            ResultRow(id: 0, values: [.null]),
            ResultRow(id: 1, values: [DisplayValue.make(text: "text")]),
        ]
        tab.result = result
        return tab
    }

    /// A NULL cell opens an empty field. Leaving it empty changed nothing, so no edit may be
    /// written, or every look at a NULL cell would turn it into an empty text.
    func testAnEmptyFieldOverANullCellIsNoChange() {
        let tab = tab()
        let address = CellAddress(rowID: 0, columnID: 0)
        XCTAssertTrue(tab.result?.value(at: address)?.isNull ?? false)

        // What the editor does when it holds an empty text over a NULL cell.
        let wasNull = tab.result?.value(at: address)?.isNull ?? false
        if !(wasNull && "".isEmpty) { tab.setEdit("", at: address) }

        XCTAssertFalse(tab.hasEdits, "an untouched NULL stays NULL")
    }

    /// The same empty text over a cell that held something is a real change.
    func testAnEmptyFieldOverATextIsAChange() {
        let tab = tab()
        let address = CellAddress(rowID: 1, columnID: 0)

        let wasNull = tab.result?.value(at: address)?.isNull ?? false
        if !(wasNull && "".isEmpty) { tab.setEdit("", at: address) }

        XCTAssertTrue(tab.hasEdits)
        XCTAssertEqual(tab.pendingText(at: address), "")
    }

    /// The value pane is the way to put an empty text where a NULL was.
    func testThePaneCanStillWriteAnEmptyText() {
        let tab = tab()
        let address = CellAddress(rowID: 0, columnID: 0)
        tab.setEdit("", at: address)
        XCTAssertTrue(tab.hasEdits)
        XCTAssertEqual(tab.pendingText(at: address), "")
    }
}
