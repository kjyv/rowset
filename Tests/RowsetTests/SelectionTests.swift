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

final class ClipboardTableTests: XCTestCase {

    private let block = [
        ["created_at", "notes"],
        ["2022-09-02", "one, two"],
        ["2022-09-03", "says \"hi\"\nsecond line"],
    ]

    func testHTMLMarksTheHeaderRow() {
        let html = ClipboardFormatter.html(block, hasHeader: true)
        XCTAssertTrue(html.hasPrefix("<table><tr><th>created_at</th><th>notes</th></tr>"))
        XCTAssertTrue(html.contains("<td>2022-09-02</td>"))
        XCTAssertTrue(html.hasSuffix("</table>"))
    }

    func testHTMLWithoutAHeaderUsesDataCellsOnly() {
        let html = ClipboardFormatter.html(block, hasHeader: false)
        XCTAssertFalse(html.contains("<th>"))
    }

    func testHTMLEscapesWhatWouldBreakTheMarkup() {
        let html = ClipboardFormatter.html([["a & b", "<tag>"]], hasHeader: false)
        XCTAssertTrue(html.contains("a &amp; b"))
        XCTAssertTrue(html.contains("&lt;tag&gt;"))
        XCTAssertFalse(html.contains("<tag>"))
    }

    func testHTMLKeepsALineBreakInsideACell() {
        let html = ClipboardFormatter.html([["one\ntwo"]], hasHeader: false)
        XCTAssertTrue(html.contains("one<br>two"))
    }

    /// A table reader looks for a type, not for a separator. Plain text alone put the whole block
    /// into one cell of Numbers.
    @MainActor
    func testThePasteboardCarriesEveryTableType() {
        Clipboard.writeTable(block, hasHeader: true)
        let pasteboard = NSPasteboard.general

        XCTAssertNotNil(pasteboard.string(forType: .html), "html")
        XCTAssertNotNil(pasteboard.string(forType: .tabularText), "tabular text")
        XCTAssertNotNil(pasteboard.string(forType: Clipboard.csvType), "csv")
        XCTAssertNotNil(pasteboard.string(forType: .string), "plain text")

        let plain = pasteboard.string(forType: .string) ?? ""
        XCTAssertTrue(plain.contains("\t"), "the plain form stays tab separated")
        XCTAssertEqual(pasteboard.string(forType: .tabularText), plain)

        let csv = pasteboard.string(forType: Clipboard.csvType) ?? ""
        XCTAssertTrue(csv.contains("\"one, two\""), "the csv form quotes a comma")
    }

    @MainActor
    func testAnEmptyBlockWritesNothing() {
        Clipboard.write("marker")
        Clipboard.writeTable([], hasHeader: false)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "marker")
    }
}
