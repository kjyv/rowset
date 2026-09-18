import AppKit
import SwiftUI
import XCTest
@testable import Rowset

/// What the rows do when a column header handle moves.
///
/// One row view draws all of its cells, so a row that nothing marks keeps the column edges it
/// drew last. The grid is hosted in a real window, the test widens a column the way the handle
/// widens it, and then asks every row whether it is going to draw again.
@MainActor
final class ColumnResizeTests: XCTestCase {

    private struct Host: View {
        let result: ResultSet
        @State private var sortOrder: [ColumnComparator] = []
        @State private var selection: CellSelection?
        @State private var revealColumn: String?

        var body: some View {
            ResultTableView(
                result: result,
                sortOrder: $sortOrder,
                selection: $selection,
                revealColumn: $revealColumn)
                .frame(width: 600, height: 300)
        }
    }

    private func result() -> ResultSet {
        var result = ResultSet()
        result.columns = [
            ResultColumn(id: 0, name: "id", typeName: "integer"),
            ResultColumn(id: 1, name: "name", typeName: "text"),
        ]
        result.rows = (0..<8).map { index in
            ResultRow(id: index, values: [
                .make(text: "\(index)"),
                .make(text: "row \(index)"),
            ])
        }
        return result
    }

    private func tableView(in view: NSView) -> NSTableView? {
        if let found = view as? NSTableView { return found }
        for child in view.subviews {
            if let found = tableView(in: child) { return found }
        }
        return nil
    }

    /// Runs the run loop until the layout settles and everything on screen is drawn.
    private func settle(_ window: NSWindow) {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Whether the row is going to draw again.
    ///
    /// The row draws into a layer of its own, and it is the layer that carries the request. The
    /// `needsDisplay` of the view stays false.
    private func waitsForARedraw(_ row: NSTableRowView) throws -> Bool {
        try XCTUnwrap(row.layer, "the row has no layer").needsDisplay()
    }

    /// Widening a column must mark every row, not only the row you click next.
    func testWideningAColumnRedrawsTheRowsBelow() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(result: result()))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        settle(window)

        let table = try XCTUnwrap(tableView(in: try XCTUnwrap(window.contentView)))
        XCTAssertEqual(table.numberOfRows, 8)

        let rows = try (0..<table.numberOfRows).map { row in
            try XCTUnwrap(table.rowView(atRow: row, makeIfNecessary: true))
        }
        settle(window)
        for (index, row) in rows.enumerated() {
            XCTAssertFalse(try waitsForARedraw(row), "row \(index) had not drawn yet")
        }

        // The handle. The table is wider than its columns, so no row changes its size here, and
        // nothing but the notification can tell a row that its columns moved.
        table.tableColumns[0].width += 120

        for (index, row) in rows.enumerated() {
            XCTAssertTrue(try waitsForARedraw(row), "row \(index) keeps the old column width")
        }
    }
}
