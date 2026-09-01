import XCTest
@testable import Rowset

@MainActor
final class ColumnOrderTests: XCTestCase {

    private func columns(_ names: [String]) -> [TreeNode] {
        names.enumerated().map { position, name in
            TreeNode(kind: .column(
                schema: "public", table: "batch", name: name, type: "text", nullable: true,
                position: position))
        }
    }

    private func titles(_ nodes: [TreeNode]) -> [String] {
        nodes.map(\.kind.title)
    }

    /// The database gives the columns in the order they were declared, and that order is right
    /// for reading a table.
    func testTheDefaultKeepsThePositionOfEachColumn() {
        let nodes = columns(["id", "created_at", "batch_index", "amount"])
        XCTAssertEqual(
            titles(ConnectionModel.ordered(nodes, byName: false)),
            ["id", "created_at", "batch_index", "amount"])
    }

    func testSortingByNameOrdersThem() {
        let nodes = columns(["id", "created_at", "batch_index", "amount"])
        XCTAssertEqual(
            titles(ConnectionModel.ordered(nodes, byName: true)),
            ["amount", "batch_index", "created_at", "id"])
    }

    /// A name with a number in it must read the way a person would.
    func testNumbersInANameCountAsNumbers() {
        let nodes = columns(["value_10", "value_2", "value_1"])
        XCTAssertEqual(
            titles(ConnectionModel.ordered(nodes, byName: true)),
            ["value_1", "value_2", "value_10"])
    }

    func testTheCaseOfANameDoesNotSplitTheOrder() {
        let nodes = columns(["Beta", "alpha", "Gamma"])
        XCTAssertEqual(
            titles(ConnectionModel.ordered(nodes, byName: true)), ["alpha", "Beta", "Gamma"])
    }

    func testAnEmptyListStaysEmpty() {
        XCTAssertTrue(ConnectionModel.ordered([], byName: true).isEmpty)
    }

    /// Sorting by name used to replace the list, which threw the catalog order away. Going back
    /// then changed nothing at all.
    func testTheOrderGoesBackToThePosition() {
        let nodes = columns(["id", "created_at", "batch_index", "amount"])
        let byName = ConnectionModel.ordered(nodes, byName: true)
        XCTAssertEqual(titles(byName), ["amount", "batch_index", "created_at", "id"])

        let back = ConnectionModel.ordered(byName, byName: false)
        XCTAssertEqual(titles(back), ["id", "created_at", "batch_index", "amount"])
    }

    // MARK: - The grid follows the same order

    private func tab(columns names: [String]) -> QueryTab {
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "t",
            kind: .table(schema: "public", name: "batch"), rowLimit: 25)
        tab.knownColumns = names.enumerated().map {
            ResultColumn(id: $0.offset, name: $0.element, typeName: "text")
        }
        return tab
    }

    func testThePlainQueryAsksForEveryColumn() {
        let tab = tab(columns: ["id", "created_at", "amount"])
        XCTAssertTrue(tab.selectedColumnNames.isEmpty)
        XCTAssertEqual(SQLBuilder.columnList(tab.selectedColumnNames), "*")
    }

    /// The grid follows a SELECT, so the query has to name the columns in the order it wants.
    func testSortingByNameNamesTheColumnsInOrder() {
        let tab = tab(columns: ["id", "created_at", "amount"])
        tab.sortsColumnsByName = true

        XCTAssertEqual(tab.selectedColumnNames, ["amount", "created_at", "id"])
        XCTAssertEqual(
            SQLBuilder.columnList(tab.selectedColumnNames),
            "\"amount\", \"created_at\", \"id\"")
    }

    func testTheQueryCarriesTheColumnList() {
        let sql = SQLBuilder.selectRows(
            schema: "public", table: "batch", filter: "", orderBy: "", limit: 26,
            columns: ["amount", "id"])
        XCTAssertTrue(sql.hasPrefix("SELECT \"amount\", \"id\" FROM \"public\".\"batch\""))
    }

    func testAnOddColumnNameIsQuotedInTheList() {
        XCTAssertEqual(SQLBuilder.columnList(["odd name"]), "\"odd name\"")
    }

    func testTheOrderIsRememberedOnTheTable() {
        let table = TreeNode(kind: .table(schema: "public", name: "batch"))
        XCTAssertFalse(table.sortsColumnsByName, "the position is the default")

        table.sortsColumnsByName = true
        XCTAssertTrue(table.sortsColumnsByName)
    }
}

@MainActor
final class LargeValueTests: XCTestCase {

    private func tab(_ types: [(String, String)], key: [String] = ["id"]) -> QueryTab {
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "t",
            kind: .table(schema: "public", name: "truck_data"), rowLimit: 25)
        tab.primaryKey = key
        tab.knownColumns = types.enumerated().map {
            ResultColumn(id: $0.offset, name: $0.element.0, typeName: $0.element.1)
        }
        tab.columnInfo = Dictionary(
            uniqueKeysWithValues: types.map {
                ($0.0, ColumnInfo(name: $0.0, typeName: $0.1, isNullable: true))
            })
        return tab
    }

    func testWhichTypesCountAsLarge() {
        func large(_ type: String) -> Bool {
            ColumnInfo(name: "c", typeName: type, isNullable: true).isLarge
        }
        XCTAssertTrue(large("jsonb"))
        XCTAssertTrue(large("json"))
        XCTAssertTrue(large("ARRAY"))
        XCTAssertTrue(large("text"))
        XCTAssertTrue(large("bytea"))
        XCTAssertFalse(large("integer"))
        XCTAssertFalse(large("timestamp with time zone"))
        XCTAssertFalse(large("character varying"))
        XCTAssertFalse(large("uuid"))
    }

    func testALargeColumnAsksForItsStartOnly() {
        let tab = tab([("id", "integer"), ("payload", "jsonb")])
        XCTAssertTrue(tab.cutsLargeValues)
        XCTAssertEqual(tab.selectExpressions, [
            "\"id\"",
            "left(\"payload\"::text, 301) AS \"payload\"",
        ])
    }

    /// Without a key there is no way to ask for the rest of a row, so nothing may be left behind.
    func testATableWithoutAKeyAsksForEverything() {
        let tab = tab([("id", "integer"), ("payload", "jsonb")], key: [])
        XCTAssertFalse(tab.cutsLargeValues)
        XCTAssertTrue(tab.selectExpressions.isEmpty, "an empty list means SELECT *")
    }

    func testATableWithoutALargeColumnAsksForEverything() {
        let tab = tab([("id", "integer"), ("slug", "character varying")])
        XCTAssertFalse(tab.cutsLargeValues)
        XCTAssertTrue(tab.selectExpressions.isEmpty)
    }

    func testAValueAtTheCutLengthIsMarked() {
        let tab = tab([("id", "integer"), ("payload", "jsonb")])
        var result = ResultSet()
        result.columns = [
            ResultColumn(id: 0, name: "id", typeName: "integer"),
            ResultColumn(id: 1, name: "payload", typeName: "jsonb"),
        ]
        result.rows = [
            ResultRow(id: 0, values: [
                DisplayValue.make(text: "1"),
                DisplayValue.make(text: String(repeating: "x", count: 301)),
            ]),
            ResultRow(id: 1, values: [
                DisplayValue.make(text: "2"),
                DisplayValue.make(text: "short"),
            ]),
            ResultRow(id: 2, values: [DisplayValue.make(text: "3"), .null]),
        ]

        tab.markCutValues(in: &result)
        XCTAssertTrue(result.rows[0].values[1].isCut, "a value at the cut length has more behind")
        XCTAssertFalse(result.rows[1].values[1].isCut, "a short value is whole")
        XCTAssertFalse(result.rows[2].values[1].isCut, "a NULL is whole")
        XCTAssertFalse(result.rows[0].values[0].isCut, "a small column is never cut")
    }
}
