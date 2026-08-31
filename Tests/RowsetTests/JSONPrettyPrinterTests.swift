import XCTest
@testable import Rowset

final class JSONPrettyPrinterTests: XCTestCase {

    func testFormatsAnObject() {
        let formatted = JSONPrettyPrinter.format(#"{"a":1,"b":"x"}"#)
        XCTAssertEqual(formatted, """
            {
              "a": 1,
              "b": "x"
            }
            """)
    }

    func testKeepsTheKeyOrderOfTheServer() {
        // JSONSerialization would sort or reorder these. The scanner must not.
        let formatted = JSONPrettyPrinter.format(#"{"z":1,"a":2,"m":3}"#) ?? ""
        let keys = ["\"z\"", "\"a\"", "\"m\""].map { formatted.range(of: $0)?.lowerBound }
        XCTAssertNotNil(keys[0])
        XCTAssertNotNil(keys[1])
        XCTAssertNotNil(keys[2])
        XCTAssertTrue(keys[0]! < keys[1]!)
        XCTAssertTrue(keys[1]! < keys[2]!)
    }

    func testNestsArrays() {
        let formatted = JSONPrettyPrinter.format(#"{"v":[1,2]}"#)
        XCTAssertEqual(formatted, """
            {
              "v": [
                1,
                2
              ]
            }
            """)
    }

    func testKeepsAnEmptyObjectOnOneLine() {
        XCTAssertEqual(JSONPrettyPrinter.format(#"{"a":{},"b":[]}"#), """
            {
              "a": {},
              "b": []
            }
            """)
    }

    func testDoesNotTouchTextInsideAString() {
        let formatted = JSONPrettyPrinter.format(#"{"a":"{x, y}: [1]"}"#)
        XCTAssertEqual(formatted, """
            {
              "a": "{x, y}: [1]"
            }
            """)
    }

    func testHandlesAnEscapedQuote() {
        let formatted = JSONPrettyPrinter.format(#"{"a":"say \"hi\"","b":1}"#)
        XCTAssertEqual(formatted, """
            {
              "a": "say \\"hi\\"",
              "b": 1
            }
            """)
    }

    func testRejectsTextThatIsNotJSON() {
        XCTAssertNil(JSONPrettyPrinter.format("hello"))
        XCTAssertNil(JSONPrettyPrinter.format(""))
        XCTAssertFalse(JSONPrettyPrinter.looksLikeJSON("42"))
        XCTAssertTrue(JSONPrettyPrinter.looksLikeJSON("  \n {\"a\":1}"))
    }

    func testRejectsAValueThatIsTooLarge() {
        let big = "{\"a\":\"" + String(repeating: "x", count: JSONPrettyPrinter.characterLimit) + "\"}"
        XCTAssertNil(JSONPrettyPrinter.format(big))
    }
}

final class DisplayValueTests: XCTestCase {

    func testPreviewCollapsesWhiteSpace() {
        let value = DisplayValue.make(text: "a\n\n  b\tc")
        XCTAssertEqual(value.preview, "a b c")
        XCTAssertEqual(value.text, "a\n\n  b\tc", "the whole value stays for the inspector")
    }

    func testPreviewStopsAtTheLimit() {
        let value = DisplayValue.make(text: String(repeating: "x", count: 5_000))
        XCTAssertEqual(value.preview.count, DisplayValue.previewLimit + 1, "one ellipsis is added")
        XCTAssertTrue(value.preview.hasSuffix("…"))
        XCTAssertFalse(value.isTruncated, "5000 characters fit inside the cell limit")
    }

    func testAVeryLargeValueIsCut() {
        let value = DisplayValue.make(text: String(repeating: "y", count: DisplayValue.characterLimit + 10))
        XCTAssertTrue(value.isTruncated)
        XCTAssertEqual(value.text.count, DisplayValue.characterLimit)
    }

    func testShortValueKeepsNoEllipsis() {
        let value = DisplayValue.make(text: "hello")
        XCTAssertEqual(value.preview, "hello")
        XCTAssertFalse(value.isTruncated)
    }
}
