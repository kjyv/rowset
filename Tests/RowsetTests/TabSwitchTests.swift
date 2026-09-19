import AppKit
import SQLite3
import SwiftUI
import XCTest
@testable import Rowset

/// What a tab switch does to the grid.
///
/// The grid is an NSView behind SwiftUI. Building it again throws away everything AppKit holds:
/// the column widths, the scroll position and the row views. A switch between two tabs must not
/// cost that.
@MainActor
final class TabSwitchTests: XCTestCase {

    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rowset-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("tabs.sqlite")

        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, """
                CREATE TABLE note (id INTEGER PRIMARY KEY, slug TEXT);
                INSERT INTO note VALUES (1, 'first'), (2, 'second');
                CREATE TABLE memo (id INTEGER PRIMARY KEY, slug TEXT);
                INSERT INTO memo VALUES (1, 'x'), (2, 'y');
                """, nil, nil, nil),
            SQLITE_OK)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func tableView(in view: NSView) -> NSTableView? {
        if let found = view as? NSTableView { return found }
        for child in view.subviews {
            if let found = tableView(in: child) { return found }
        }
        return nil
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func makeModel() -> AppModel {
        AppModel(
            store: BookmarkStore(fileURL: directory.appendingPathComponent("b.json")),
            sessionStore: SessionStore(fileURL: directory.appendingPathComponent("s.json")),
            bufferStore: BufferStore(fileURL: directory.appendingPathComponent("c.json")))
    }

    private func makeConnection() -> ConnectionModel {
        var bookmark = Bookmark()
        bookmark.name = "notes"
        bookmark.driver = .sqlite
        bookmark.filePath = file.path
        return ConnectionModel(bookmark: bookmark)
    }

    /// A tab keeps the widths you gave it, whatever stood in the tab area meanwhile.
    ///
    /// The grid is one NSView. Two table tabs share it, and a console takes it away and gives
    /// back another. The tab has to hold the widths, because the view holds nothing across
    /// either of those.
    private func widthsSurvive(_ visitOther: (AppModel, QueryTab) -> Void) async throws {
        let model = makeModel()
        let connection = makeConnection()
        model.connections[connection.id] = connection
        await connection.connect()
        addTeardownBlock { @MainActor in await connection.disconnect() }

        let table = model.openTable(schema: "main", name: "note", connection: connection)
        await model.runTableQuery(table)
        let other = model.openTable(schema: "main", name: "memo", connection: connection)
        await model.runTableQuery(other)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DetailView(model: model))
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        model.selectedTabID = table.id
        settle(window)
        let grid = try XCTUnwrap(tableView(in: try XCTUnwrap(window.contentView)))
        grid.tableColumns.forEach { $0.width = 321 }
        settle(window)

        visitOther(model, other)
        settle(window)

        model.selectedTabID = table.id
        settle(window)
        let back = try XCTUnwrap(tableView(in: try XCTUnwrap(window.contentView)))
        XCTAssertEqual(
            back.tableColumns.map(\.width), [321, 321], "the tab lost the widths you gave it")
    }

    func testATableTabKeepsItsWidthsPastAnotherTableTab() async throws {
        try await widthsSurvive { model, other in model.selectedTabID = other.id }
    }

    func testATableTabKeepsItsWidthsPastAConsole() async throws {
        try await widthsSurvive { model, _ in
            let console = model.openSQLTab(connection: model.connections.values.first!)
            model.selectedTabID = console.id
        }
    }

    /// Going back and forth, changing a width each time, must not drift.
    func testWidthsHoldOverManyRounds() async throws {
        let model = makeModel()
        let connection = makeConnection()
        model.connections[connection.id] = connection
        await connection.connect()
        addTeardownBlock { @MainActor in await connection.disconnect() }

        let note = model.openTable(schema: "main", name: "note", connection: connection)
        await model.runTableQuery(note)
        let memo = model.openTable(schema: "main", name: "memo", connection: connection)
        await model.runTableQuery(memo)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DetailView(model: model))
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        var expected: [UUID: CGFloat] = [:]
        for round in 0..<4 {
            for tab in [note, memo] {
                model.selectedTabID = tab.id
                settle(window)
                let grid = try XCTUnwrap(tableView(in: try XCTUnwrap(window.contentView)))

                if let want = expected[tab.id] {
                    XCTAssertEqual(
                        grid.tableColumns.map(\.width), [want, want],
                        "round \(round): the tab came back with other widths")
                }

                let width = CGFloat(200 + round * 30 + (tab.id == note.id ? 0 : 7))
                grid.tableColumns.forEach { $0.width = width }
                settle(window)
                expected[tab.id] = width
            }
        }
    }

    /// The widths of one tab must not follow you into another.
    func testAnotherTabDoesNotInheritTheWidths() async throws {
        let model = makeModel()
        let connection = makeConnection()
        model.connections[connection.id] = connection
        await connection.connect()
        addTeardownBlock { @MainActor in await connection.disconnect() }

        let first = model.openTable(schema: "main", name: "note", connection: connection)
        await model.runTableQuery(first)
        let second = model.openTable(schema: "main", name: "memo", connection: connection)
        await model.runTableQuery(second)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DetailView(model: model))
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        model.selectedTabID = first.id
        settle(window)
        let grid = try XCTUnwrap(tableView(in: try XCTUnwrap(window.contentView)))
        grid.tableColumns.forEach { $0.width = 321 }
        settle(window)

        model.selectedTabID = second.id
        settle(window)
        let onSecond = try XCTUnwrap(tableView(in: try XCTUnwrap(window.contentView)))
        XCTAssertEqual(
            onSecond.tableColumns.map(\.width),
            [ResultTableView.defaultColumnWidth, ResultTableView.defaultColumnWidth],
            "the second tab took the widths of the first")
    }
}
