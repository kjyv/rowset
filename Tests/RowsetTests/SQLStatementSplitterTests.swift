import XCTest
@testable import Rowset

final class SQLStatementSplitterTests: XCTestCase {

    private func texts(_ sql: String) -> [String] {
        SQLStatementSplitter.statements(in: sql).map(\.text)
    }

    func testOneStatementWithoutASemicolon() {
        XCTAssertEqual(texts("SELECT 1"), ["SELECT 1"])
    }

    func testOneStatementWithASemicolon() {
        XCTAssertEqual(texts("SELECT 1;"), ["SELECT 1"])
    }

    func testTwoStatements() {
        XCTAssertEqual(texts("SELECT 1;\nSELECT 2;"), ["SELECT 1", "SELECT 2"])
    }

    /// The last one needs no semicolon, which is how a query usually gets typed.
    func testALastStatementWithoutASemicolon() {
        XCTAssertEqual(texts("SELECT 1;\nSELECT 2"), ["SELECT 1", "SELECT 2"])
    }

    func testEmptyTextGivesNoStatement() {
        XCTAssertTrue(texts("").isEmpty)
        XCTAssertTrue(texts("   \n\n  ").isEmpty)
        XCTAssertTrue(texts(";;;").isEmpty)
    }

    // MARK: - An empty line ends a statement

    func testAnEmptyLineSplitsWithoutASemicolon() {
        XCTAssertEqual(texts("SELECT 1\n\nSELECT 2"), ["SELECT 1", "SELECT 2"])
    }

    /// A statement is normally written over several lines. One line break must not split it, or
    /// every SELECT with its FROM on the next line would fall apart.
    func testOneLineBreakDoesNotSplit() {
        XCTAssertEqual(
            texts("SELECT *\nFROM component\nWHERE id = 1"),
            ["SELECT *\nFROM component\nWHERE id = 1"])
    }

    func testAnEmptyLineOfSpacesStillSplits() {
        XCTAssertEqual(texts("SELECT 1\n   \t \nSELECT 2"), ["SELECT 1", "SELECT 2"])
    }

    func testManyEmptyLinesSplitOnce() {
        XCTAssertEqual(texts("SELECT 1\n\n\n\nSELECT 2"), ["SELECT 1", "SELECT 2"])
    }

    func testASemicolonAndAnEmptyLineTogether() {
        XCTAssertEqual(texts("SELECT 1;\n\nSELECT 2"), ["SELECT 1", "SELECT 2"])
    }

    func testAMultiLineStatementBetweenEmptyLines() {
        let sql = """
            SELECT pg_terminate_backend(pid)
              FROM pg_stat_activity
             WHERE application_name = 'cube_norman'

            SELECT 1
            """
        let statements = texts(sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].hasPrefix("SELECT pg_terminate_backend"))
        XCTAssertTrue(statements[0].contains("cube_norman'"), "the whole statement stays whole")
        XCTAssertEqual(statements[1], "SELECT 1")
    }

    /// An empty line inside a literal is part of that literal, not a break between statements.
    func testAnEmptyLineInsideAStringDoesNotSplit() {
        XCTAssertEqual(texts("SELECT 'a\n\nb'"), ["SELECT 'a\n\nb'"])
    }

    func testAnEmptyLineInsideADollarQuoteDoesNotSplit() {
        let sql = "CREATE FUNCTION f() RETURNS int AS $$\nBEGIN\n\nRETURN 1;\n\nEND\n$$ LANGUAGE plpgsql"
        XCTAssertEqual(SQLStatementSplitter.statements(in: sql).count, 1)
    }

    func testAnEmptyLineInsideABlockCommentDoesNotSplit() {
        XCTAssertEqual(texts("SELECT /* a\n\nb */ 1"), ["SELECT /* a\n\nb */ 1"])
    }

    // MARK: - Where a naive split on the semicolon goes wrong

    func testASemicolonInsideAStringDoesNotSplit() {
        XCTAssertEqual(
            texts("SELECT 'a;b'; SELECT 2"),
            ["SELECT 'a;b'", "SELECT 2"])
    }

    func testTwoQuotesInsideAStringAreOneQuote() {
        XCTAssertEqual(texts("SELECT 'it''s; here'"), ["SELECT 'it''s; here'"])
    }

    func testASemicolonInsideAQuotedNameDoesNotSplit() {
        XCTAssertEqual(texts("SELECT \"odd;name\" FROM t"), ["SELECT \"odd;name\" FROM t"])
    }

    func testASemicolonInsideALineCommentDoesNotSplit() {
        XCTAssertEqual(
            texts("SELECT 1 -- a; comment\n, 2"),
            ["SELECT 1 -- a; comment\n, 2"])
    }

    func testASemicolonInsideABlockCommentDoesNotSplit() {
        XCTAssertEqual(texts("SELECT /* a; b */ 1"), ["SELECT /* a; b */ 1"])
    }

    /// Postgres allows a block comment inside a block comment.
    func testANestedBlockComment() {
        XCTAssertEqual(texts("SELECT /* a /* b; */ c; */ 1"), ["SELECT /* a /* b; */ c; */ 1"])
    }

    func testASemicolonInsideADollarQuotedBodyDoesNotSplit() {
        let sql = "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql;"
        XCTAssertEqual(SQLStatementSplitter.statements(in: sql).count, 1)
    }

    func testATaggedDollarQuote() {
        let sql = "SELECT $tag$ a; b $tag$; SELECT 2"
        XCTAssertEqual(texts(sql), ["SELECT $tag$ a; b $tag$", "SELECT 2"])
    }

    func testADollarThatStartsNoQuote() {
        XCTAssertEqual(texts("SELECT $1; SELECT 2"), ["SELECT $1", "SELECT 2"])
    }

    // MARK: - Ranges

    func testARangeCoversItsOwnStatement() {
        let sql = "SELECT 1;\nSELECT 2;"
        let statements = SQLStatementSplitter.statements(in: sql)
        XCTAssertEqual(statements.count, 2)

        let first = (sql as NSString).substring(with: statements[0].range)
        XCTAssertEqual(first, "SELECT 1;")

        let second = (sql as NSString).substring(with: statements[1].range)
        XCTAssertEqual(second, "SELECT 2;")
    }

    func testARangeSkipsTheSpaceBeforeAStatement() {
        let sql = "\n\n   SELECT 1;"
        let statements = SQLStatementSplitter.statements(in: sql)
        XCTAssertEqual((sql as NSString).substring(with: statements[0].range), "SELECT 1;")
    }

    // MARK: - The statement the caret is in

    private let twoStatements = "SELECT 1;\nSELECT 2;"

    func testTheCaretInsideTheFirstStatement() {
        let statements = SQLStatementSplitter.statements(in: twoStatements)
        XCTAssertEqual(SQLStatementSplitter.statement(at: 3, in: statements)?.text, "SELECT 1")
    }

    func testTheCaretInsideTheSecondStatement() {
        let statements = SQLStatementSplitter.statements(in: twoStatements)
        XCTAssertEqual(SQLStatementSplitter.statement(at: 14, in: statements)?.text, "SELECT 2")
    }

    func testTheCaretAtTheEndOfAStatementBelongsToIt() {
        let statements = SQLStatementSplitter.statements(in: twoStatements)
        XCTAssertEqual(SQLStatementSplitter.statement(at: 9, in: statements)?.text, "SELECT 1")
    }

    /// A caret in the space between two statements belongs to the one you just finished.
    func testTheCaretBetweenTwoStatements() {
        // "SELECT 1;" ends at 9, and "SELECT 2" starts at 10. Position 9 is the newline.
        let statements = SQLStatementSplitter.statements(in: twoStatements)
        XCTAssertEqual(SQLStatementSplitter.statement(at: 9, in: statements)?.text, "SELECT 1")

        let spaced = "SELECT 1;\n\n\nSELECT 2;"
        let far = SQLStatementSplitter.statements(in: spaced)
        XCTAssertEqual(SQLStatementSplitter.statement(at: 11, in: far)?.text, "SELECT 1")
    }

    func testACommentAloneIsNoStatement() {
        XCTAssertTrue(texts("-- just a note").isEmpty)
        XCTAssertTrue(texts("/* nothing here */").isEmpty)
    }

    func testACommentBeforeAStatementStaysWithIt() {
        XCTAssertEqual(texts("-- note\nSELECT 1"), ["-- note\nSELECT 1"])
    }

    func testNoStatementGivesNothing() {
        XCTAssertNil(SQLStatementSplitter.statement(at: 0, in: []))
    }
}
