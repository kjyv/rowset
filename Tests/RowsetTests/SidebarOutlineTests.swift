import AppKit
import SQLite3
import SwiftUI
import XCTest
@testable import Rowset

/// The sidebar outline: the tree it opens again at launch, and what a click, a key or the model
/// does to it.
@MainActor
final class SidebarOutlineTests: XCTestCase {

    private var directory: URL!
    private var file: URL!
    private var sidebars: [Sidebar] = []

    /// One schema and three tables. `t30` sits far below the rows a short window shows.
    private static let restoredNodes = [
        NodePath(schema: "main", table: nil),
        NodePath(schema: "main", table: "t01"),
        NodePath(schema: "main", table: "t02"),
        NodePath(schema: "main", table: "t30"),
    ]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rowset-sidebar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("tree.sqlite")

        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        let columns = (0..<12).map { "c\($0) TEXT" }.joined(separator: ", ")
        let sql = (0..<40)
            .map { String(format: "CREATE TABLE t%02d (id INTEGER PRIMARY KEY, %@);", $0, columns) }
            .joined(separator: "\n")
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    /// The connections close before their file goes, so SQLite never reads a deleted file.
    override func tearDown() async throws {
        for sidebar in sidebars {
            sidebar.window.orderOut(nil)
            for connection in sidebar.model.connections.values {
                await connection.disconnect()
            }
        }
        sidebars = []
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    @MainActor
    private struct Sidebar {
        let model: AppModel
        let id: UUID
        let window: NSWindow
        let outline: NSOutlineView

        var connection: ConnectionModel { model.connection(id: id)! }

        func node(_ title: String) -> TreeNode? {
            let schema = connection.schemas.first
            if schema?.kind.title == title { return schema }
            return schema?.children?.first { $0.kind.title == title }
        }

        /// The first row with this title.
        func row(_ title: String) -> Int? {
            (0..<outline.numberOfRows).first {
                (outline.item(atRow: $0) as? SidebarItem)?.look.title == title
            }
        }

        func item(_ title: String) -> SidebarItem? {
            row(title).flatMap { outline.item(atRow: $0) as? SidebarItem }
        }

        func isExpanded(_ title: String) -> Bool {
            item(title).map { outline.isItemExpanded($0) } ?? false
        }
    }

    private func outlineView(in view: NSView) -> NSOutlineView? {
        if let found = view as? NSOutlineView { return found }
        for child in view.subviews {
            if let found = outlineView(in: child) { return found }
        }
        return nil
    }

    private func settle(_ window: NSWindow, rounds: Int = 5) {
        for _ in 0..<rounds {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    @discardableResult
    private func wait(
        _ window: NSWindow, timeout: TimeInterval = 5, until condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                settle(window)
                return true
            }
            settle(window, rounds: 1)
        }
        return condition()
    }

    /// A sidebar with two connections. `tree` comes back open with `nodes` when `isOpen`.
    private func makeSidebar(isOpen: Bool = true, nodes: [NodePath] = restoredNodes) throws
        -> Sidebar
    {
        var bookmark = Bookmark()
        bookmark.name = "tree"
        bookmark.driver = .sqlite
        bookmark.filePath = file.path

        let store = BookmarkStore(fileURL: directory.appendingPathComponent("b.json"))
        var other = Bookmark()
        other.name = "other"
        other.driver = .sqlite
        other.filePath = file.path
        store.upsert(other)
        store.upsert(bookmark)

        let sessionStore = SessionStore(fileURL: directory.appendingPathComponent("s.json"))
        sessionStore.saveNow(SessionState(
            expandedBookmarks: isOpen ? [bookmark.id] : [],
            expandedNodes: isOpen ? [bookmark.id.uuidString: nodes] : [:]))

        let model = AppModel(
            store: store,
            sessionStore: sessionStore,
            bufferStore: BufferStore(fileURL: directory.appendingPathComponent("c.json")))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SidebarView(model: model))
        window.makeKeyAndOrderFront(nil)
        settle(window)

        let outline = try XCTUnwrap(outlineView(in: window.contentView!))
        let sidebar = Sidebar(model: model, id: bookmark.id, window: window, outline: outline)
        sidebars.append(sidebar)
        let lastTable = nodes.compactMap(\.table).last
        XCTAssertTrue(wait(window) {
            guard sidebar.row("tree") != nil else { return false }
            guard isOpen, let lastTable else { return true }
            return sidebar.node(lastTable)?.children != nil
        })
        return sidebar
    }

    // MARK: - Restore

    func testRestoreOpensTheSavedRows() throws {
        let sidebar = try makeSidebar()

        for title in ["tree", "main", "t01", "t02", "t30"] {
            XCTAssertTrue(sidebar.isExpanded(title), title)
        }
        XCTAssertFalse(sidebar.isExpanded("t00"))
        XCTAssertFalse(sidebar.isExpanded("other"))
        // Command-F tells the sidebar from the result grid by the missing header.
        XCTAssertNil(sidebar.outline.headerView)
        // The section, two connections, the schema, forty tables, and thirteen columns under
        // each of the three open tables.
        XCTAssertEqual(sidebar.outline.numberOfRows, 1 + 2 + 1 + 40 + 3 * 13)
    }

    // MARK: - Closing over rows AppKit never drew

    /// The model closes the connection row, as a double click does.
    func testClosingARestoredConnectionFromTheModel() throws {
        let sidebar = try makeSidebar()
        sidebar.model.setExpanded(false, bookmarkID: sidebar.id)
        settle(sidebar.window)

        XCTAssertFalse(sidebar.isExpanded("tree"))
        XCTAssertEqual(sidebar.outline.numberOfRows, 3)
    }

    /// The outline closes the connection row, as the chevron does.
    func testClosingARestoredConnectionFromTheOutline() throws {
        let sidebar = try makeSidebar()
        sidebar.outline.collapseItem(try XCTUnwrap(sidebar.item("tree")))
        settle(sidebar.window)

        XCTAssertFalse(sidebar.connection.isExpanded)
        XCTAssertEqual(sidebar.outline.numberOfRows, 3)
        // AppKit reports the rows below as closed too. The model keeps them open.
        XCTAssertTrue(try XCTUnwrap(sidebar.node("main")).isExpanded)
        XCTAssertTrue(try XCTUnwrap(sidebar.node("t30")).isExpanded)

        sidebar.outline.expandItem(try XCTUnwrap(sidebar.item("tree")))
        settle(sidebar.window)
        XCTAssertTrue(sidebar.isExpanded("t30"))
        XCTAssertEqual(sidebar.outline.numberOfRows, 1 + 2 + 1 + 40 + 3 * 13)
    }

    func testClosingARestoredSchema() throws {
        let sidebar = try makeSidebar()
        sidebar.outline.collapseItem(try XCTUnwrap(sidebar.item("main")))
        settle(sidebar.window)

        XCTAssertFalse(try XCTUnwrap(sidebar.node("main")).isExpanded)
        // The tables keep their state, and come back open with the schema.
        XCTAssertTrue(try XCTUnwrap(sidebar.node("t30")).isExpanded)

        sidebar.outline.expandItem(try XCTUnwrap(sidebar.item("main")))
        settle(sidebar.window)
        XCTAssertTrue(sidebar.isExpanded("t30"))
        XCTAssertEqual(sidebar.outline.numberOfRows, 1 + 2 + 1 + 40 + 3 * 13)
    }

    /// The columns of a table change while a closed row hides it. AppKit must not answer from
    /// what it held before.
    func testChangeUnderAClosedRow() throws {
        let sidebar = try makeSidebar()
        sidebar.model.setExpanded(false, bookmarkID: sidebar.id)
        settle(sidebar.window)

        sidebar.connection.updateColumns(schema: "main", table: "t30", from: [
            ColumnInfo(name: "id", typeName: "INTEGER", isNullable: false, maximumLength: nil),
            ColumnInfo(name: "only", typeName: "TEXT", isNullable: true, maximumLength: nil),
        ])
        settle(sidebar.window)

        sidebar.model.setExpanded(true, bookmarkID: sidebar.id)
        settle(sidebar.window)
        let t30 = try XCTUnwrap(sidebar.row("t30"))
        XCTAssertEqual(sidebar.outline.numberOfChildren(ofItem: sidebar.outline.item(atRow: t30)), 2)
        XCTAssertEqual(sidebar.outline.numberOfRows, 1 + 2 + 1 + 40 + 2 * 13 + 2)

        sidebar.model.setExpanded(false, bookmarkID: sidebar.id)
        settle(sidebar.window)
        XCTAssertEqual(sidebar.outline.numberOfRows, 3)
    }

    // MARK: - Chevrons

    func testChevronOpensAndConnects() throws {
        let sidebar = try makeSidebar(isOpen: false)
        XCTAssertEqual(sidebar.connection.state, .disconnected)

        sidebar.outline.expandItem(try XCTUnwrap(sidebar.item("tree")))
        XCTAssertTrue(sidebar.connection.isExpanded)
        XCTAssertTrue(wait(sidebar.window) { sidebar.row("main") != nil })
        XCTAssertEqual(sidebar.connection.state, .connected)

        sidebar.outline.expandItem(try XCTUnwrap(sidebar.item("main")))
        XCTAssertTrue(wait(sidebar.window) { sidebar.row("t00") != nil })
        sidebar.outline.expandItem(try XCTUnwrap(sidebar.item("t00")))
        XCTAssertTrue(wait(sidebar.window) { sidebar.row("c11") != nil })
        XCTAssertTrue(try XCTUnwrap(sidebar.node("t00")).isExpanded)
    }

    func testChevronClosesATable() throws {
        let sidebar = try makeSidebar()
        sidebar.outline.collapseItem(try XCTUnwrap(sidebar.item("t30")))
        settle(sidebar.window)

        XCTAssertFalse(try XCTUnwrap(sidebar.node("t30")).isExpanded)
    }

    // MARK: - Selection and keys

    func testSelectionFollowsBothWays() throws {
        let sidebar = try makeSidebar()
        let t02 = try XCTUnwrap(sidebar.node("t02"))

        sidebar.outline.selectRowIndexes([try XCTUnwrap(sidebar.row("t02"))], byExtendingSelection: false)
        XCTAssertEqual(sidebar.model.sidebarSelection, .node(id: t02.id, bookmarkID: sidebar.id))

        sidebar.model.sidebarSelection = .bookmark(sidebar.id)
        settle(sidebar.window)
        XCTAssertEqual(sidebar.outline.selectedRow, sidebar.row("tree"))
    }

    func testReturnOpensTheSelectedTable() throws {
        let sidebar = try makeSidebar()
        sidebar.outline.selectRowIndexes([try XCTUnwrap(sidebar.row("t05"))], byExtendingSelection: false)

        // With Caps Lock on, as it often is by accident.
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.capsLock], timestamp: 0,
            windowNumber: sidebar.window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        sidebar.outline.keyDown(with: returnKey)

        XCTAssertEqual(sidebar.model.selectedTab?.kind, .table(schema: "main", name: "t05"))
    }

    // MARK: - Filter

    func testFilterShowsTheMatchesAndTheTreeComesBack() throws {
        let sidebar = try makeSidebar()

        sidebar.model.sidebarFilter = "t3"
        XCTAssertTrue(wait(sidebar.window) { sidebar.row("t39") != nil })
        // The connection as a title, and its ten matching tables.
        XCTAssertEqual(sidebar.outline.numberOfRows, 1 + 10)
        XCTAssertNil(sidebar.row("other"))

        sidebar.model.sidebarFilter = ""
        settle(sidebar.window)
        XCTAssertTrue(sidebar.isExpanded("t30"))
        XCTAssertEqual(sidebar.outline.numberOfRows, 1 + 2 + 1 + 40 + 3 * 13)
    }

    // MARK: - State changes

    func testDisconnectLeavesTheConnectButton() throws {
        let sidebar = try makeSidebar()
        let model = sidebar.model
        let id = sidebar.id
        Task { await model.disconnect(bookmarkID: id) }
        XCTAssertTrue(wait(sidebar.window) { sidebar.connection.state == .disconnected })

        XCTAssertTrue(sidebar.isExpanded("tree"))
        XCTAssertNotNil(sidebar.row("Connect"))
        XCTAssertNil(sidebar.row("main"))
    }

    /// A long message takes the lines it needs, and the row under the connection shrinks back
    /// when the message goes.
    func testErrorRowTakesItsHeightAndGivesItBack() throws {
        let sidebar = try makeSidebar()
        let normal = sidebar.outline.rowHeight
        let message = String(repeating: "password authentication failed ", count: 8)

        sidebar.connection.state = .failed(message)
        settle(sidebar.window)
        let error = try XCTUnwrap(sidebar.row(message))
        XCTAssertGreaterThan(sidebar.outline.rect(ofRow: error).height, normal * 2)

        sidebar.connection.state = .disconnected
        settle(sidebar.window)
        let connect = try XCTUnwrap(sidebar.row("Connect"))
        XCTAssertEqual(sidebar.outline.rect(ofRow: connect).height, normal)
    }
}
