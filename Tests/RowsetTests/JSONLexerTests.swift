import XCTest
@testable import Rowset

final class JSONLexerTests: XCTestCase {

    private func kinds(_ text: String) -> [SyntaxKind] {
        JSONLexer.tokens(in: text).map(\.kind)
    }

    private func text(ofKind kind: SyntaxKind, in json: String) -> [String] {
        JSONLexer.tokens(in: json).filter { $0.kind == kind }.map(\.text)
    }

    func testAFieldNameIsAKeyAndItsValueIsAString() {
        let json = #"{"name": "value"}"#
        XCTAssertEqual(text(ofKind: .key, in: json), [#""name""#])
        XCTAssertEqual(text(ofKind: .string, in: json), [#""value""#])
    }

    func testAStringInAnArrayIsNeverAKey() {
        let json = #"["a", "b"]"#
        XCTAssertTrue(text(ofKind: .key, in: json).isEmpty)
        XCTAssertEqual(text(ofKind: .string, in: json), [#""a""#, #""b""#])
    }

    func testAKeyAfterACommaIsStillAKey() {
        let json = #"{"a": 1, "b": 2}"#
        XCTAssertEqual(text(ofKind: .key, in: json), [#""a""#, #""b""#])
    }

    /// A comma inside an array of an object must not turn the next string into a name.
    func testACommaInsideAnArrayKeepsItsStrings() {
        let json = #"{"list": ["a", "b"], "next": "c"}"#
        XCTAssertEqual(text(ofKind: .key, in: json), [#""list""#, #""next""#])
        XCTAssertEqual(text(ofKind: .string, in: json), [#""a""#, #""b""#, #""c""#])
    }

    func testANestedObjectKeepsItsOwnKeys() {
        let json = #"{"outer": {"inner": 1}, "after": 2}"#
        XCTAssertEqual(text(ofKind: .key, in: json), [#""outer""#, #""inner""#, #""after""#])
    }

    func testTheThreeWordsAreKeywords() {
        XCTAssertEqual(text(ofKind: .keyword, in: "[true, false, null]"), ["true", "false", "null"])
    }

    func testANumberIsOneToken() {
        XCTAssertEqual(text(ofKind: .number, in: "[-1.5e-3]"), ["-1.5e-3"])
    }

    func testAnEscapedQuoteDoesNotEndTheString() {
        let json = #"{"a": "one \" two"}"#
        XCTAssertEqual(text(ofKind: .string, in: json), [#""one \" two""#])
    }

    /// The pane shows what the server sent, so a value that does not parse still gives tokens.
    func testBrokenTextStillGivesTokens() {
        XCTAssertFalse(kinds(#"{"a": }}]"#).isEmpty)
        XCTAssertFalse(kinds(#"{"never closed"#).isEmpty)
    }

    func testTheRangesCoverTheRightText() {
        let json = #"{"a": 12}"#
        let source = json as NSString
        for token in JSONLexer.tokens(in: json) {
            XCTAssertEqual(source.substring(with: token.range), token.text)
        }
    }

    /// A value the grid shows unformatted is one line. It must colour the same way.
    func testOneLineAndManyLinesGiveTheSameKinds() {
        let flat = #"{"a": 1, "b": [true]}"#
        let formatted = """
            {
              "a": 1,
              "b": [
                true
              ]
            }
            """
        XCTAssertEqual(kinds(flat), kinds(formatted))
    }
}
