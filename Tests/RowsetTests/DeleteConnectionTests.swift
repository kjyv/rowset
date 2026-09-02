import XCTest
@testable import Rowset

/// What goes when a connection goes.
@MainActor
final class DeleteConnectionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rowset-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func app() -> (AppModel, ConnectionModel) {
        let model = AppModel(
            store: BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json")),
            sessionStore: SessionStore(fileURL: directory.appendingPathComponent("session.json")),
            bufferStore: BufferStore(fileURL: directory.appendingPathComponent("consoles.json")))

        var bookmark = Bookmark()
        bookmark.name = "one"
        bookmark.driver = .sqlite
        bookmark.filePath = directory.appendingPathComponent("one.sqlite").path
        model.store.upsert(bookmark)

        let connection = ConnectionModel(bookmark: bookmark)
        model.connections[connection.id] = connection
        return (model, connection)
    }

    func testDeletingAConnectionClosesItsTabs() async {
        let (model, connection) = app()
        model.openTable(schema: "main", name: "note", connection: connection)
        model.openTable(schema: "main", name: "plant", connection: connection)
        model.openSQLTab(connection: connection)
        XCTAssertEqual(model.tabs.count, 3)

        await model.deleteConnection(bookmarkID: connection.id)

        XCTAssertTrue(model.tabs.isEmpty, "a tab of a connection that is gone can fetch nothing")
        XCTAssertNil(model.selectedTabID)
        XCTAssertNil(model.connections[connection.id])
    }

    func testDeletingAConnectionDeletesItsSavedConsoles() async {
        let (model, connection) = app()
        model.openSQLTab(connection: connection)
        _ = model.bufferStore.create(for: connection.id, text: "-- second\n\nSELECT 2")
        XCTAssertEqual(model.bufferStore.buffers(for: connection.id).count, 2)

        await model.deleteConnection(bookmarkID: connection.id)

        XCTAssertTrue(model.bufferStore.buffers(for: connection.id).isEmpty)
    }

    /// The tabs of another connection stay open, and so do its consoles.
    func testDeletingOneConnectionLeavesTheOthersAlone() async {
        let (model, connection) = app()

        var other = Bookmark()
        other.name = "two"
        other.driver = .sqlite
        other.filePath = directory.appendingPathComponent("two.sqlite").path
        model.store.upsert(other)
        let second = ConnectionModel(bookmark: other)
        model.connections[second.id] = second

        model.openTable(schema: "main", name: "note", connection: connection)
        let kept = model.openTable(schema: "main", name: "note", connection: second)
        model.openSQLTab(connection: second)

        await model.deleteConnection(bookmarkID: connection.id)

        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertTrue(model.tabs.allSatisfy { $0.connectionID == second.id })
        XCTAssertEqual(model.bufferStore.buffers(for: second.id).count, 1)
        XCTAssertEqual(model.selectedTabID, model.tabs.last?.id)
        XCTAssertTrue(model.tabs.contains { $0.id == kept.id })
    }

    /// The sidebar removed the bookmark before the task ran, and `syncConnections` dropped the
    /// connection with it. The tabs must go even when nothing is left to disconnect.
    func testTheTabsCloseEvenWhenTheConnectionIsAlreadyGone() async {
        let (model, connection) = app()
        model.openTable(schema: "main", name: "note", connection: connection)
        model.openSQLTab(connection: connection)
        XCTAssertEqual(model.tabs.count, 2)

        model.connections[connection.id] = nil
        await model.deleteConnection(bookmarkID: connection.id)

        XCTAssertTrue(model.tabs.isEmpty)
    }

    /// The file must lose them as well, or the next launch opens them again.
    func testTheSessionAndTheConsoleFileForgetThemToo() async throws {
        let (model, connection) = app()
        model.openTable(schema: "main", name: "note", connection: connection)
        model.openSQLTab(connection: connection)

        await model.deleteConnection(bookmarkID: connection.id)
        model.saveSessionNow()

        let session = SessionStore(fileURL: directory.appendingPathComponent("session.json")).load()
        XCTAssertTrue(session.tabs.isEmpty)

        let consoles = BufferStore(fileURL: directory.appendingPathComponent("consoles.json"))
        XCTAssertTrue(consoles.buffers(for: connection.id).isEmpty)
    }
}
