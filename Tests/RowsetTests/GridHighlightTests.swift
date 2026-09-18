import AppKit
import SwiftUI
import XCTest
@testable import Rowset

/// Carries the selection into the view, so the test can select a cell after the grid is drawn.
@MainActor
@Observable
fileprivate final class SelectionBox {
    var selection: CellSelection?
}

/// The band over a row that holds a selection.
///
/// A selected cell goes off the side as soon as you scroll, so the row it belongs to has to stay
/// marked over its whole width. The test draws one row twice, before and after the selection, and
/// reads a pixel far to the right of the selected cell. The same row and the same text on both
/// sides leave the band as the only thing that can differ.
@MainActor
final class GridHighlightTests: XCTestCase {

    private struct Host: View {
        let result: ResultSet
        let box: SelectionBox
        @State private var sortOrder: [ColumnComparator] = []
        @State private var revealColumn: String?

        var body: some View {
            ResultTableView(
                result: result,
                sortOrder: $sortOrder,
                selection: Binding(get: { box.selection }, set: { box.selection = $0 }),
                revealColumn: $revealColumn)
                .frame(width: 600, height: 300)
        }
    }

    private func result() -> ResultSet {
        var result = ResultSet()
        result.columns = (0..<12).map { ResultColumn(id: $0, name: "c\($0)", typeName: "text") }
        result.rows = (0..<6).map { row in
            ResultRow(id: row, values: (0..<12).map { .make(text: "r\(row)c\($0)") })
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

    private func settle(_ window: NSWindow) {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// The colour of one row, to the right of the cell the selection covers.
    private func colorFarRight(of row: NSTableRowView) throws -> NSColor {
        let rep = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
        row.cacheDisplay(in: row.bounds, to: rep)
        // The right edge of a cell, where the text has ended.
        let x = min(Int(row.bounds.width) - 3, Int(row.bounds.width * 0.55))
        let color = try XCTUnwrap(rep.colorAt(x: x, y: Int(row.bounds.height / 2)))
        return try XCTUnwrap(color.usingColorSpace(.deviceRGB))
    }

    private func distance(_ first: NSColor, _ second: NSColor) -> CGFloat {
        abs(first.redComponent - second.redComponent)
            + abs(first.greenComponent - second.greenComponent)
            + abs(first.blueComponent - second.blueComponent)
    }

    func testTheRowOfTheSelectedCellIsMarkedOverItsWholeWidth() throws {
        let box = SelectionBox()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(result: result(), box: box))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        settle(window)

        let table = try XCTUnwrap(tableView(in: try XCTUnwrap(window.contentView)))
        let row = try XCTUnwrap(table.rowView(atRow: 2, makeIfNecessary: true))
        let other = try XCTUnwrap(table.rowView(atRow: 3, makeIfNecessary: true))
        settle(window)

        let plain = try colorFarRight(of: row)
        let plainOther = try colorFarRight(of: other)

        // One cell in the first column, far from where the pixels are read.
        box.selection = CellSelection(single: CellAddress(rowID: 2, columnID: 0))
        settle(window)

        XCTAssertGreaterThan(
            distance(try colorFarRight(of: row), plain), 0.01,
            "the row of the selected cell is not marked away from that cell")
        XCTAssertLessThan(
            distance(try colorFarRight(of: other), plainOther), 0.01,
            "a row without a selection changed as well")
    }
}
