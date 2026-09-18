import XCTest
@testable import Rowset

final class LineIndenterTests: XCTestCase {

    /// The text after the edit, so a test reads like the editor looks.
    private func indented(_ text: String, _ selection: NSRange) -> String? {
        applied(LineIndenter.indent(text, selection: selection), to: text)
    }

    private func dedented(_ text: String, _ selection: NSRange) -> String? {
        applied(LineIndenter.dedent(text, selection: selection), to: text)
    }

    private func applied(_ edit: IndentEdit?, to text: String) -> String? {
        guard let edit else { return nil }
        let result = NSMutableString(string: text)
        result.replaceCharacters(in: edit.range, with: edit.replacement)
        return result as String
    }

    // MARK: - Tab

    func testTabAtACaretInsertsOneStep() {
        XCTAssertEqual(indented("SELECT 1", NSRange(location: 0, length: 0)), "  SELECT 1")
        XCTAssertEqual(indented("SELECT 1", NSRange(location: 6, length: 0)), "SELECT   1")
    }

    func testTabMovesEveryLineOfTheSelection() {
        let sql = "SELECT 1\nFROM t\nWHERE a\nORDER BY a"
        XCTAssertEqual(
            indented(sql, NSRange(location: 0, length: 16)),
            "  SELECT 1\n  FROM t\nWHERE a\nORDER BY a")
    }

    /// The selection normally starts inside a line and not at its first character.
    func testTabMovesTheWholeLineOfAPartialSelection() {
        XCTAssertEqual(
            indented("SELECT 1\nFROM t", NSRange(location: 3, length: 2)), "  SELECT 1\nFROM t")
    }

    /// A selection that ends at the start of a line reaches no character of that line.
    func testTabLeavesTheLineAfterTheLastBreakAlone() {
        XCTAssertEqual(
            indented("SELECT 1\nFROM t", NSRange(location: 0, length: 9)), "  SELECT 1\nFROM t")
    }

    func testTabAddsNoSpaceToAnEmptyLine() {
        XCTAssertEqual(
            indented("SELECT 1\n\nFROM t", NSRange(location: 0, length: 16)),
            "  SELECT 1\n\n  FROM t")
    }

    func testTabKeepsIndentThatIsAlreadyThere() {
        XCTAssertEqual(
            indented("  FROM t", NSRange(location: 0, length: 8)), "    FROM t")
    }

    // MARK: - Shift-Tab

    func testShiftTabTakesOneStepFromEveryLineOfTheSelection() {
        let sql = "  SELECT 1\n    FROM t\nWHERE a"
        XCTAssertEqual(
            dedented(sql, NSRange(location: 0, length: 21)), "SELECT 1\n  FROM t\nWHERE a")
    }

    func testShiftTabAtACaretDedentsItsLine() {
        XCTAssertEqual(dedented("  SELECT 1", NSRange(location: 5, length: 0)), "SELECT 1")
    }

    /// A pasted line can carry a tab character, which counts as one whole step.
    func testShiftTabTakesAWholeTabCharacter() {
        XCTAssertEqual(dedented("\tFROM t", NSRange(location: 0, length: 7)), "FROM t")
    }

    func testShiftTabTakesWhatIsThereWhenItIsLessThanAStep() {
        XCTAssertEqual(dedented(" FROM t", NSRange(location: 0, length: 7)), "FROM t")
    }

    func testShiftTabChangesNothingWithoutIndent() {
        XCTAssertNil(LineIndenter.dedent("SELECT 1", selection: NSRange(location: 0, length: 8)))
    }

    // MARK: - What the editor selects afterwards

    /// A second Tab must move the same lines, so the selection covers the whole block.
    func testTheSelectionGrowsToTheMovedLines() {
        let edit = LineIndenter.indent(
            "SELECT 1\nFROM t", selection: NSRange(location: 3, length: 8))
        XCTAssertEqual(edit?.selection, NSRange(location: 0, length: 19))
    }

    func testACaretFollowsTheTextThatMoved() {
        let indent = LineIndenter.indent("SELECT 1", selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(indent?.selection, NSRange(location: 6, length: 0))

        let dedent = LineIndenter.dedent("  SELECT 1", selection: NSRange(location: 6, length: 0))
        XCTAssertEqual(dedent?.selection, NSRange(location: 4, length: 0))
    }

    /// The caret sits inside the indent that goes away, so it stops at the first character.
    func testACaretInsideTheIndentStaysOnItsLine() {
        let edit = LineIndenter.dedent("  SELECT 1", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(edit?.selection, NSRange(location: 0, length: 0))
    }

    /// The ranges are UTF-16 units, which `NSTextView` counts, and an emoji takes two of them.
    func testARangeAfterAWideCharacter() {
        let sql = "SELECT '🙂'\nFROM t"
        XCTAssertEqual(
            indented(sql, NSRange(location: 0, length: 13)), "  SELECT '🙂'\n  FROM t")
    }
}
