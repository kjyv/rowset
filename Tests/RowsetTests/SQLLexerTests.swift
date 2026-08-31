import XCTest
@testable import Rowset

final class SQLLexerTests: XCTestCase {

    private func kinds(_ sql: String) -> [SQLTokenKind] {
        SQLLexer.tokens(in: sql).map(\.kind)
    }

    private func token(_ sql: String, at index: Int) -> SQLToken {
        SQLLexer.tokens(in: sql)[index]
    }

    func testAKeywordAndAName() {
        XCTAssertEqual(kinds("SELECT slug"), [.keyword, .identifier])
    }

    func testAKeywordInAnyCase() {
        XCTAssertEqual(kinds("select"), [.keyword])
        XCTAssertEqual(kinds("SeLeCt"), [.keyword])
    }

    func testANameThatOnlyLooksLikeAKeyword() {
        XCTAssertEqual(kinds("selected"), [.identifier])
    }

    func testAString() {
        XCTAssertEqual(kinds("'abc'"), [.string])
        XCTAssertEqual(token("'it''s'", at: 0).text, "'it''s'")
    }

    func testAQuotedName() {
        XCTAssertEqual(kinds("\"odd name\""), [.quotedIdentifier])
    }

    func testANumber() {
        XCTAssertEqual(kinds("42"), [.number])
        XCTAssertEqual(kinds("4.2"), [.number])
    }

    func testAParameter() {
        XCTAssertEqual(kinds("$1"), [.parameter])
        XCTAssertEqual(token("$12", at: 0).text, "$12")
    }

    func testALineComment() {
        XCTAssertEqual(kinds("-- note\nSELECT"), [.comment, .keyword])
    }

    func testABlockComment() {
        XCTAssertEqual(kinds("/* a */ SELECT"), [.comment, .keyword])
    }

    func testADollarQuotedBodyIsOneString() {
        let tokens = SQLLexer.tokens(in: "$$ SELECT 1; $$")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .string)
    }

    func testPunctuation() {
        XCTAssertEqual(kinds("a, b"), [.identifier, .punctuation, .identifier])
    }

    func testARangePointsAtItsOwnText() {
        let sql = "SELECT 'x' FROM t"
        for token in SQLLexer.tokens(in: sql) {
            XCTAssertEqual((sql as NSString).substring(with: token.range), token.text)
        }
    }

    func testWhiteSpaceCarriesNoToken() {
        XCTAssertEqual(kinds("   \n\t  "), [])
        XCTAssertEqual(kinds(""), [])
    }

    /// The colouring and the statement split read the same tokens, so the tokens must cover the
    /// text with nothing but white space left over, and never overlap.
    func testTokensCoverTheTextWithoutOverlap() {
        let sql = "SELECT 'a b'; -- done\n/* x */ SELECT $tag$ y $tag$"
        let source = sql as NSString
        let tokens = SQLLexer.tokens(in: sql)

        var position = 0
        for token in tokens {
            XCTAssertGreaterThanOrEqual(token.range.location, position, "tokens must not overlap")
            let gap = source.substring(
                with: NSRange(location: position, length: token.range.location - position))
            XCTAssertTrue(
                gap.allSatisfy(\.isWhitespace), "only white space may sit between tokens: \(gap)")
            position = token.range.upperBound
        }

        let tail = source.substring(from: position)
        XCTAssertTrue(tail.allSatisfy(\.isWhitespace), "the end must be covered too")
    }
}
