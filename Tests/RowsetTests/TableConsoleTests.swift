import XCTest
@testable import Rowset

@MainActor
final class TableConsoleTests: XCTestCase {

    private func model() -> AppModel {
        let folder = FileManager.default.temporaryDirectory
        let suffix = UUID().uuidString
        return AppModel(
            store: BookmarkStore(fileURL: folder.appending(path: "b-\(suffix).json")),
            sessionStore: SessionStore(fileURL: folder.appending(path: "s-\(suffix).json")),
            bufferStore: BufferStore(fileURL: folder.appending(path: "c-\(suffix).json")))
    }

    private func tableTab() -> QueryTab {
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "testing",
            kind: .table(schema: "public", name: "batch"), rowLimit: 50)
        tab.primaryKey = ["id"]
        return tab
    }

    // MARK: - The query the console starts with

    func testTheConsoleTakesThePlainTableQuery() {
        let model = model()
        let tab = tableTab()
        XCTAssertEqual(model.generatedSQL(for: tab), """
            SELECT * FROM "public"."batch"
            LIMIT 50;
            """)
    }

    func testTheConsoleTakesTheFilterTheSortAndTheLimit() {
        let model = model()
        let tab = tableTab()
        tab.filterText = "slug = 'x'"
        tab.orderByText = "created_at DESC"
        tab.rowLimit = 200

        XCTAssertEqual(model.generatedSQL(for: tab), """
            SELECT * FROM "public"."batch"
            WHERE slug = 'x'
            ORDER BY created_at DESC
            LIMIT 200;
            """)
    }

    /// What the console starts with must be a statement the splitter can run.
    func testTheGeneratedQueryIsOneStatement() {
        let model = model()
        let tab = tableTab()
        tab.filterText = "slug = 'a;b'"

        let statements = SQLStatementSplitter.statements(in: model.generatedSQL(for: tab))
        XCTAssertEqual(statements.count, 1, "a semicolon inside the filter is no separator")
    }

    // MARK: - The tab becomes a console

    func testTheTabTurnsIntoAConsole() {
        let model = model()
        let tab = tableTab()
        XCTAssertEqual(tab.title, "batch")

        model.openConsole(on: tab)
        XCTAssertEqual(tab.kind, .sql, "it is a console tab now, and runs the same code as one")
        XCTAssertEqual(tab.title, "Console")
    }

    func testTheConsoleHoldsTheQueryOfTheFields() {
        let model = model()
        let tab = tableTab()
        tab.filterText = "slug = 'x'"
        tab.orderByText = "created_at DESC"

        model.openConsole(on: tab)
        XCTAssertTrue(tab.sqlText.contains("WHERE slug = 'x'"))
        XCTAssertTrue(tab.sqlText.contains("ORDER BY created_at DESC"))
        XCTAssertTrue(tab.sqlText.hasPrefix("-- batch"), "a title line names it in the list")
    }

    /// The query joins the saved consoles of the connection, so it outlives the tab.
    func testTheQueryIsSavedAsAConsoleOfTheConnection() {
        let model = model()
        let tab = tableTab()
        XCTAssertTrue(model.buffers(for: tab).isEmpty)

        model.openConsole(on: tab)
        let saved = model.buffers(for: tab)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.id, tab.bufferID)
        XCTAssertEqual(saved.first?.title, "batch", "the title line gives it a name")
    }

    func testTheCommentLineIsNotPartOfTheStatement() {
        let model = model()
        let tab = tableTab()
        model.openConsole(on: tab)

        let statements = SQLStatementSplitter.statements(in: tab.sqlText)
        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].text.hasPrefix("SELECT *"))
    }

    /// A console statement may join two tables or rename a column, and an UPDATE built from such
    /// a result would hit the wrong rows.
    func testAConsoleIsNotEditable() {
        let model = model()
        let tab = tableTab()
        XCTAssertTrue(tab.isEditable)

        model.openConsole(on: tab)
        XCTAssertFalse(tab.isEditable)
        XCTAssertTrue(tab.primaryKey.isEmpty, "the key of the old table is gone with it")
    }

    func testEditsAreDroppedOnTheWay() {
        let model = model()
        let tab = tableTab()

        var result = ResultSet()
        result.columns = [ResultColumn(id: 0, name: "id", typeName: "integer")]
        result.rows = [ResultRow(id: 0, values: [DisplayValue.make(text: "1")])]
        tab.result = result
        tab.setEdit("2", at: CellAddress(rowID: 0, columnID: 0))
        XCTAssertTrue(tab.hasEdits)

        model.openConsole(on: tab)
        XCTAssertFalse(tab.hasEdits, "a change that can no longer be sent must not linger")
    }

    func testAConsoleTabIsNotConvertedAgain() {
        let model = model()
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "t", kind: .sql, rowLimit: 50)
        tab.sqlText = "SELECT 1"

        model.openConsole(on: tab)
        XCTAssertEqual(tab.sqlText, "SELECT 1", "nothing to convert, nothing changed")
        XCTAssertTrue(model.buffers(for: tab).isEmpty)
    }

    // MARK: - The session

    func testAConvertedTabIsWrittenDownAsAConsole() {
        let model = model()
        let tab = tableTab()
        model.openConsole(on: tab)

        let state = tab.state
        XCTAssertTrue(state.isSQLTab)
        XCTAssertEqual(state.bufferID, tab.bufferID)
    }
}
