import XCTest
@testable import Rowset

final class CellSelectionTests: XCTestCase {

    private func address(_ row: Int, _ column: Int) -> CellAddress {
        CellAddress(rowID: row, columnID: column)
    }

    func testOneCell() {
        let selection = CellSelection(single: address(3, 2))
        XCTAssertEqual(selection.rows, 3...3)
        XCTAssertEqual(selection.columns, 2...2)
        XCTAssertEqual(selection.cellCount, 1)
        XCTAssertTrue(selection.isSingleCell)
    }

    func testABlockCountsItsCells() {
        let selection = CellSelection(anchor: address(1, 1), focus: address(3, 4))
        XCTAssertEqual(selection.rows, 1...3)
        XCTAssertEqual(selection.columns, 1...4)
        XCTAssertEqual(selection.cellCount, 12)
        XCTAssertFalse(selection.isSingleCell)
    }

    func testADragUpwardsCountsTheSame() {
        let downward = CellSelection(anchor: address(1, 1), focus: address(3, 4))
        let upward = CellSelection(anchor: address(3, 4), focus: address(1, 1))
        XCTAssertEqual(downward.rows, upward.rows)
        XCTAssertEqual(downward.columns, upward.columns)
    }

    func testContains() {
        let selection = CellSelection(anchor: address(1, 1), focus: address(3, 4))
        XCTAssertTrue(selection.contains(row: 2, column: 2))
        XCTAssertTrue(selection.contains(row: 1, column: 4))
        XCTAssertFalse(selection.contains(row: 0, column: 2))
        XCTAssertFalse(selection.contains(row: 2, column: 5))
    }
}

final class ClipboardFormatterTests: XCTestCase {

    private let rows = [
        ["created_at", "slug", "notes"],
        ["2022-09-02", "herkules", "one, two"],
        ["2022-09-03", "demo", "says \"hi\""],
    ]

    func testTabSeparated() {
        XCTAssertEqual(ClipboardFormatter.tsv([["a", "b"], ["c", "d"]]), "a\tb\nc\td")
    }

    func testTabSeparatedFlattensALineBreak() {
        let text = ClipboardFormatter.tsv([["one\ntwo", "three\tfour"]])
        XCTAssertEqual(text, "one two\tthree four")
        XCTAssertFalse(text.contains("\n"), "a line break would look like a new row")
    }

    func testCommaSeparatedQuotesWhenItMust() {
        XCTAssertEqual(ClipboardFormatter.csv([["plain", "one, two"]]), "plain,\"one, two\"")
    }

    func testCommaSeparatedDoublesAQuote() {
        XCTAssertEqual(ClipboardFormatter.csv([["says \"hi\""]]), "\"says \"\"hi\"\"\"")
    }

    func testCommaSeparatedKeepsALineBreakInsideQuotes() {
        XCTAssertEqual(ClipboardFormatter.csv([["one\ntwo"]]), "\"one\ntwo\"")
    }

    func testBothFormatsKeepEveryRow() {
        XCTAssertEqual(ClipboardFormatter.tsv(rows).split(separator: "\n").count, 3)
        XCTAssertEqual(ClipboardFormatter.text(rows, format: .csv).split(separator: "\n").count, 3)
    }

    func testAnEmptyBlockGivesEmptyText() {
        XCTAssertEqual(ClipboardFormatter.tsv([]), "")
        XCTAssertEqual(ClipboardFormatter.csv([]), "")
    }
}

final class ResultBlockTests: XCTestCase {

    private func result() -> ResultSet {
        var set = ResultSet()
        set.columns = [
            ResultColumn(id: 0, name: "id", typeName: "integer"),
            ResultColumn(id: 1, name: "slug", typeName: "text"),
            ResultColumn(id: 2, name: "notes", typeName: "text"),
        ]
        set.rows = (0..<3).map { index in
            ResultRow(id: index, values: [
                DisplayValue.make(text: "\(index)"),
                DisplayValue.make(text: "slug\(index)"),
                index == 1 ? .null : DisplayValue.make(text: "note\(index)"),
            ])
        }
        return set
    }

    func testABlockTakesOnlyItsRowsAndColumns() {
        let selection = CellSelection(
            anchor: CellAddress(rowID: 0, columnID: 1),
            focus: CellAddress(rowID: 1, columnID: 2))
        let block = result().block(selection, includeHeader: false)
        XCTAssertEqual(block, [["slug0", "note0"], ["slug1", ""]])
    }

    func testAHeaderNamesTheSameColumns() {
        let selection = CellSelection(
            anchor: CellAddress(rowID: 0, columnID: 1),
            focus: CellAddress(rowID: 0, columnID: 2))
        let block = result().block(selection, includeHeader: true)
        XCTAssertEqual(block.first, ["slug", "notes"])
        XCTAssertEqual(block.count, 2)
    }

    func testANullBecomesAnEmptyField() {
        let selection = CellSelection(single: CellAddress(rowID: 1, columnID: 2))
        XCTAssertEqual(result().block(selection, includeHeader: false), [[""]])
    }

    func testAnEmptyResultGivesNoBlock() {
        let selection = CellSelection(single: CellAddress(rowID: 0, columnID: 0))
        XCTAssertTrue(ResultSet().block(selection, includeHeader: false).isEmpty)
    }
}
