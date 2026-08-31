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
