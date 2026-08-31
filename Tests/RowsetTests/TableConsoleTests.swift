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

    // MARK: - Opening and closing

    func testOpeningTheConsoleFillsItOnce() {
        let model = model()
        let tab = tableTab()

        model.toggleConsole(tab)
        XCTAssertTrue(tab.showsConsole)
        XCTAssertTrue(tab.sqlText.contains("SELECT * FROM \"public\".\"batch\""))
    }

    func testClosingAndOpeningKeepsWhatYouWrote() {
        let model = model()
        let tab = tableTab()

        model.toggleConsole(tab)
        tab.sqlText = "SELECT count(*) FROM batch"
        model.toggleConsole(tab)
        XCTAssertFalse(tab.showsConsole)

        model.toggleConsole(tab)
        XCTAssertEqual(tab.sqlText, "SELECT count(*) FROM batch", "your text survives")
    }

    func testFromTableWritesTheQueryAgain() {
        let model = model()
        let tab = tableTab()

        model.toggleConsole(tab)
        tab.sqlText = "SELECT 1"
        tab.filterText = "id = 7"
        model.resetConsoleFromFilter(tab)

        XCTAssertTrue(tab.sqlText.contains("WHERE id = 7"))
        XCTAssertEqual(tab.sqlCaret, 0)
    }

    // MARK: - Editing

    /// A console statement may join two tables, and an UPDATE built from that result would hit
    /// the wrong rows.
    func testTheConsoleTurnsEditingOff() {
        let model = model()
        let tab = tableTab()
        XCTAssertTrue(tab.isEditable)

        model.toggleConsole(tab)
        XCTAssertFalse(tab.isEditable)

        model.toggleConsole(tab)
        XCTAssertTrue(tab.isEditable, "closing it gives editing back")
    }

    func testAConsoleTabNeedsNoGeneratedQuery() {
        let model = model()
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "t", kind: .sql, rowLimit: 50)
        tab.sqlText = "SELECT 1"
        XCTAssertEqual(model.generatedSQL(for: tab), "SELECT 1", "it keeps its own text")
    }

    // MARK: - The session

    func testTheStateOfTheConsoleIsWrittenDown() {
        let tab = tableTab()
        tab.showsConsole = true
        tab.sqlText = "SELECT 1"

        let state = tab.state
        XCTAssertTrue(state.showsConsole)
        XCTAssertEqual(state.sqlText, "SELECT 1")
    }
}
