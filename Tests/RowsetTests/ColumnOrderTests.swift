import XCTest
@testable import Rowset

@MainActor
final class ColumnOrderTests: XCTestCase {

    private func columns(_ names: [String]) -> [TreeNode] {
        names.map {
            TreeNode(kind: .column(
                schema: "public", table: "batch", name: $0, type: "text", nullable: true))
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

    func testTheOrderIsRememberedOnTheTable() {
        let table = TreeNode(kind: .table(schema: "public", name: "batch"))
        XCTAssertFalse(table.sortsColumnsByName, "the position is the default")

        table.sortsColumnsByName = true
        XCTAssertTrue(table.sortsColumnsByName)
    }
}
