import XCTest
@testable import Rowset

final class SessionStateTests: XCTestCase {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "rowset-session-\(UUID().uuidString).json")
    }

    @MainActor
    func testAnEmptyFileGivesADefaultSession() {
        let store = SessionStore(fileURL: temporaryURL())
        let state = store.load()
        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertTrue(state.expandedBookmarks.isEmpty)
        XCTAssertEqual(state.inspectorHeight, 190)
    }

    @MainActor
    func testWritesAndReadsTheSameSession() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let bookmarkID = UUID()
        var state = SessionState()
        state.expandedBookmarks = [bookmarkID]
        state.expandedNodes[bookmarkID.uuidString] = [
            NodePath(schema: "public", table: nil),
            NodePath(schema: "public", table: "component"),
        ]
        state.tabs = [
            TabState(
                bookmarkID: bookmarkID, schema: "public", table: "component",
                filterText: "slug = 'x'", orderByText: "created_at DESC",
                showsValuePane: false, rowLimit: 25),
            TabState(bookmarkID: bookmarkID, sqlText: "SELECT 1", rowLimit: 50),
        ]
        state.selectedTabIndex = 1
        state.inspectorHeight = 260

        let store = SessionStore(fileURL: url)
        store.saveNow(state)

        let read = SessionStore(fileURL: url).load()
        XCTAssertEqual(read.expandedBookmarks, [bookmarkID])
        XCTAssertEqual(read.nodes(for: bookmarkID).count, 2)
        XCTAssertEqual(read.tabs.count, 2)
        XCTAssertEqual(read.tabs[0].filterText, "slug = 'x'")
        XCTAssertEqual(read.tabs[0].orderByText, "created_at DESC")
        XCTAssertEqual(read.tabs[0].rowLimit, 25)
        XCTAssertEqual(read.selectedTabIndex, 1)
        XCTAssertEqual(read.tabs[0].showsValuePane, false)
        XCTAssertEqual(read.inspectorHeight, 260)
    }

    /// A field added later must not throw away every tab of a saved session.
    func testAFileWithMissingKeysStillReads() throws {
        let json = """
            {
              "tabs": [
                {"bookmarkID": "\(UUID().uuidString)", "schema": "public", "table": "component"}
              ]
            }
            """
        let state = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertEqual(state.tabs[0].table, "component")
        XCTAssertEqual(state.tabs[0].rowLimit, 50)
        XCTAssertEqual(state.tabs[0].filterText, "")
        XCTAssertNil(state.tabs[0].showsValuePane)
        XCTAssertEqual(state.inspectorHeight, 190)
        XCTAssertTrue(state.sidebarVisible)
    }

    /// A tab without its bookmark belongs to no connection, so that one key is required.
    func testATabWithoutABookmarkIsAnError() {
        let json = #"{"tabs": [{"table": "component"}]}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionState.self, from: Data(json.utf8)))
    }

    /// The pane takes room the rows want, so a tab opens without it whatever it shows.
    @MainActor
    func testANewTabOpensWithoutTheValuePane() {
        func tab(_ kind: QueryTab.Kind) -> QueryTab {
            QueryTab(connectionID: UUID(), connectionName: "t", kind: kind, rowLimit: 25)
        }
        XCTAssertFalse(tab(.table(schema: "public", name: "component")).showsValuePane)
        XCTAssertFalse(tab(.sql).showsValuePane)
    }

    /// The pane belongs to the tab, so the session file keeps one answer for each.
    @MainActor
    func testATabCarriesItsPaneIntoTheSession() {
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "t",
            kind: .table(schema: "public", name: "component"), rowLimit: 25)
        XCTAssertEqual(tab.state.showsValuePane, false)
        tab.showsValuePane = true
        XCTAssertEqual(tab.state.showsValuePane, true)
    }

    func testATabStateKnowsItsKind() {
        let table = TabState(bookmarkID: UUID(), schema: "public", table: "component")
        XCTAssertFalse(table.isSQLTab)

        let query = TabState(bookmarkID: UUID(), sqlText: "SELECT 1")
        XCTAssertTrue(query.isSQLTab)
    }

    func testNodesForAnUnknownBookmarkAreEmpty() {
        XCTAssertTrue(SessionState().nodes(for: UUID()).isEmpty)
    }

    @MainActor
    func testABrokenFileGivesADefaultSession() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "this is not json".write(to: url, atomically: true, encoding: .utf8)

        let state = SessionStore(fileURL: url).load()
        XCTAssertTrue(state.tabs.isEmpty, "a broken file must not stop the app")
    }
}
