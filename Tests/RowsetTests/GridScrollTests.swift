import AppKit
import SQLite3
import SwiftUI
import XCTest
@testable import Rowset

/// Where the grid stands after a sort.
///
/// A sort runs the statement again and hands the grid another result. The grid goes back to the
/// first row then, and it has to stay on the column you were reading.
@MainActor
final class GridScrollTests: XCTestCase {

    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rowset-grid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("wide.sqlite")

        let columns = (0..<12).map { "c\($0) TEXT" }.joined(separator: ", ")
        var sql = "CREATE TABLE wide (id INTEGER PRIMARY KEY, \(columns));\n"
        for row in 0..<200 {
            let values = (0..<12).map { "'r\(row)c\($0)'" }.joined(separator: ", ")
            sql += "INSERT INTO wide VALUES (\(row), \(values));\n"
        }

        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Host: View {
        @Bindable var tab: QueryTab

        var body: some View {
            ResultTableView(
                result: tab.result ?? ResultSet(),
                sortOrder: $tab.sortOrder,
                selection: $tab.selection,
                revealColumn: $tab.revealColumn,
                editing: tab)
                .frame(width: 600, height: 300)
        }
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

    /// Clicking a header must not take the grid back to the first column.
    func testSortingKeepsTheSidewaysScroll() async throws {
        var bookmark = Bookmark()
        bookmark.name = "wide"
        bookmark.driver = .sqlite
        bookmark.filePath = file.path

        let model = AppModel(
            store: BookmarkStore(fileURL: directory.appendingPathComponent("b.json")),
            sessionStore: SessionStore(fileURL: directory.appendingPathComponent("s.json")),
            bufferStore: BufferStore(fileURL: directory.appendingPathComponent("c.json")))
        let connection = ConnectionModel(bookmark: bookmark)
        model.connections[connection.id] = connection
        await connection.connect()
        addTeardownBlock { @MainActor in await connection.disconnect() }

        let tab = model.openTable(schema: "main", name: "wide", connection: connection)
        await model.runTableQuery(tab)
        XCTAssertEqual(tab.result?.columns.count, 13)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(tab: tab))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        settle(window)

        let table = try XCTUnwrap(tableView(in: try XCTUnwrap(window.contentView)))
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        let clip = scrollView.contentView

        // Widen the columns the way the handles do, then read one far to the right.
        for column in table.tableColumns { column.width = 300 }
        settle(window)
        let widths = table.tableColumns.map(\.width)

        clip.scroll(to: NSPoint(x: 900, y: 400))
        scrollView.reflectScrolledClipView(clip)
        settle(window)
        let reading = clip.bounds.origin.x
        XCTAssertGreaterThan(reading, 0, "the grid never scrolled sideways")

        // The header click itself: the table view writes its own sort descriptors, which is what
        // calls the delegate and writes the sort back into the tab.
        table.sortDescriptors = [NSSortDescriptor(key: "c3", ascending: true)]
        settle(window)
        XCTAssertEqual(tab.sortOrder.first?.columnName, "c3", "the click never reached the tab")

        await model.resortTable(tab)
        settle(window)

        XCTAssertEqual(
            table.tableColumns.map(\.width), widths, "the sort reset the column widths")
        XCTAssertEqual(
            clip.bounds.origin.x, reading, accuracy: 1,
            "the sort scrolled back to the first column")
    }
}
