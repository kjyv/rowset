import XCTest
@testable import Rowset

final class ColumnKindTests: XCTestCase {

    func testReadsTheKindOfEachTypeName() {
        XCTAssertEqual(ColumnKind.of("boolean"), .boolean)
        XCTAssertEqual(ColumnKind.of("integer"), .integer)
        XCTAssertEqual(ColumnKind.of("bigint"), .integer)
        XCTAssertEqual(ColumnKind.of("smallint"), .integer)
        XCTAssertEqual(ColumnKind.of("numeric"), .number)
        XCTAssertEqual(ColumnKind.of("double precision"), .number)
        XCTAssertEqual(ColumnKind.of("uuid"), .uuid)
        XCTAssertEqual(ColumnKind.of("jsonb"), .json)
        XCTAssertEqual(ColumnKind.of("timestamp with time zone"), .temporal)
        XCTAssertEqual(ColumnKind.of("character varying"), .text)
        XCTAssertEqual(ColumnKind.of("text"), .text)
    }

    func testAnUnknownTypeIsTreatedAsText() {
        XCTAssertEqual(ColumnKind.of("ltree"), .text)
        XCTAssertEqual(ColumnKind.of("USER-DEFINED"), .text)
    }
}

final class ValueValidatorTests: XCTestCase {

    func testABooleanTakesOnlyTheWordsPostgresTakes() {
        for word in ["true", "false", "t", "F", "yes", "no", "on", "off", "1", "0"] {
            XCTAssertTrue(ValueValidator.isValid(word, for: .boolean), word)
        }
        for word in ["maybe", "", "2", "tru"] {
            XCTAssertFalse(ValueValidator.isValid(word, for: .boolean), word)
        }
    }

    func testAWholeNumber() {
        XCTAssertTrue(ValueValidator.isValid("42", for: .integer))
        XCTAssertTrue(ValueValidator.isValid("-7", for: .integer))
        XCTAssertTrue(ValueValidator.isValid("+7", for: .integer))
        XCTAssertFalse(ValueValidator.isValid("4.2", for: .integer))
        XCTAssertFalse(ValueValidator.isValid("", for: .integer))
        XCTAssertFalse(ValueValidator.isValid("seven", for: .integer))
        XCTAssertFalse(ValueValidator.isValid("-", for: .integer))
        XCTAssertFalse(ValueValidator.isValid("42abc", for: .integer))
    }

    func testANumber() {
        XCTAssertTrue(ValueValidator.isValid("4.2", for: .number))
        XCTAssertTrue(ValueValidator.isValid("-0.5", for: .number))
        XCTAssertTrue(ValueValidator.isValid("1e3", for: .number))
        XCTAssertTrue(ValueValidator.isValid("42", for: .number))
        XCTAssertFalse(ValueValidator.isValid("", for: .number))
        XCTAssertFalse(ValueValidator.isValid("4,2", for: .number))
        XCTAssertFalse(ValueValidator.isValid("4.2.1", for: .number))
        XCTAssertFalse(ValueValidator.isValid("42abc", for: .number))
        XCTAssertFalse(ValueValidator.isValid("1e", for: .number))
        XCTAssertFalse(ValueValidator.isValid(".", for: .number))
        XCTAssertTrue(ValueValidator.isValid(".5", for: .number))
        XCTAssertTrue(ValueValidator.isValid("NaN", for: .number), "Postgres takes NaN")
    }

    /// Both Double and Decimal stop at the first character they cannot use, so a prefix looked
    /// like a whole number. This records why the check walks the text itself.
    func testAPrefixIsNotANumber() {
        XCTAssertNotNil(Decimal(string: "4,2"), "Decimal reads the prefix and stops")
        XCTAssertFalse(ValueValidator.isValid("4,2", for: .number), "the app does not")
    }

    func testAUUID() {
        XCTAssertTrue(ValueValidator.isValid("0F2C4B0E-5E8B-4E4E-9C2B-2A5F1D3C7A10", for: .uuid))
        XCTAssertFalse(ValueValidator.isValid("not-a-uuid", for: .uuid))
        XCTAssertFalse(ValueValidator.isValid("", for: .uuid))
    }

    func testJSON() {
        XCTAssertTrue(ValueValidator.isValid("{\"a\": 1}", for: .json))
        XCTAssertTrue(ValueValidator.isValid("[1, 2]", for: .json))
        XCTAssertTrue(ValueValidator.isValid("42", for: .json))
        XCTAssertFalse(ValueValidator.isValid("{a: 1}", for: .json))
        XCTAssertFalse(ValueValidator.isValid("", for: .json))
    }

    /// The server reads far more forms of a date than any rule here would, so these pass through.
    func testATimeIsLeftToTheServer() {
        XCTAssertTrue(ValueValidator.isValid("2024-01-01", for: .temporal))
        XCTAssertTrue(ValueValidator.isValid("yesterday", for: .temporal))
    }

    /// An empty text is an empty string, which is a value. NULL comes from the delete key.
    func testAnEmptyTextIsValid() {
        XCTAssertTrue(ValueValidator.isValid("", for: .text))
    }

    func testEveryCheckedKindCarriesAMessage() {
        for kind in [ColumnKind.boolean, .integer, .number, .uuid, .json] {
            XCTAssertFalse(ValueValidator.message(for: kind).isEmpty, "\(kind)")
        }
    }
}

@MainActor
final class NullEditTests: XCTestCase {

    private func tab() -> QueryTab {
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "t",
            kind: .table(schema: "public", name: "component"), rowLimit: 50)
        tab.primaryKey = ["id"]
        tab.columnInfo = [
            "id": ColumnInfo(name: "id", typeName: "integer", isNullable: false),
            "note": ColumnInfo(name: "note", typeName: "text", isNullable: true),
        ]

        var result = ResultSet()
        result.columns = [
            ResultColumn(id: 0, name: "id", typeName: "integer"),
            ResultColumn(id: 1, name: "note", typeName: "text"),
        ]
        result.rows = [
            ResultRow(id: 0, values: [DisplayValue.make(text: "1"), DisplayValue.make(text: "a")]),
        ]
        tab.result = result
        return tab
    }

    func testANullableColumnTakesNull() {
        XCTAssertTrue(tab().acceptsNull(at: CellAddress(rowID: 0, columnID: 1)))
    }

    func testAColumnThatIsNotNullableRefusesNull() {
        XCTAssertFalse(tab().acceptsNull(at: CellAddress(rowID: 0, columnID: 0)))
    }

    func testTheKindOfACellComesFromTheCatalog() {
        let tab = tab()
        XCTAssertEqual(tab.info(at: CellAddress(rowID: 0, columnID: 0))?.kind, .integer)
        XCTAssertEqual(tab.info(at: CellAddress(rowID: 0, columnID: 1))?.kind, .text)
    }

    /// Deleting every character gives an empty string, and that is a change worth sending.
    func testAnEmptyStringIsNotNull() {
        let tab = tab()
        let address = CellAddress(rowID: 0, columnID: 1)
        tab.setEdit("", at: address)
        XCTAssertTrue(tab.isEdited(address))
        XCTAssertEqual(tab.pendingText(at: address), "")

        let sql = SQLBuilder.update(
            schema: "public", table: "component",
            set: [SQLBuilder.Assignment(column: "note", value: tab.pendingText(at: address))],
            key: [SQLBuilder.Assignment(column: "id", value: "1")])
        XCTAssertTrue(sql.contains("SET \"note\" = ''"), "an empty string, not NULL")
    }
}
