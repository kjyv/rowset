import AppKit
import SwiftUI
import XCTest
@testable import Rowset

/// What the value pane draws, from the first value on.
///
/// The pane is hosted in a real window and driven the way a click drives it: no value, then one.
/// The test then reads the text view the pane built and asks what is in it.
@MainActor
final class ValuePaneTests: XCTestCase {

    /// Holds the value the pane shows, so a change redraws the pane.
    @Observable final class Box {
        var value: DisplayValue?
    }

    private struct Host: View {
        let box: Box
        var body: some View {
            ValueInspectorView(
                column: ResultColumn(id: 0, name: "payload", typeName: "jsonb"),
                value: box.value,
                onClose: {})
                .frame(width: 500, height: 300)
        }
    }

    /// The pane the way a table tab builds it: the value and the cell to write to both come from
    /// the tab, and both appear the moment you pick a cell.
    private struct TabHost: View {
        let tab: QueryTab
        var body: some View {
            ValueInspectorView(
                column: tab.selectedColumn,
                value: tab.selectedValue,
                onClose: {},
                editing: tab.selectedCell.map { (tab: tab, address: $0) })
                .frame(width: 500, height: 300)
        }
    }

    /// A table tab of one editable jsonb column.
    private func tab() -> QueryTab {
        let tab = QueryTab(
            connectionID: UUID(), connectionName: "t",
            kind: .table(schema: "public", name: "t"), rowLimit: 25)
        tab.primaryKey = ["id"]
        var result = ResultSet()
        result.columns = [
            ResultColumn(id: 0, name: "id", typeName: "integer"),
            ResultColumn(id: 1, name: "payload", typeName: "jsonb"),
        ]
        result.rows = [
            ResultRow(id: 0, values: [
                .make(text: "1"),
                .make(text: #"{"a": 1, "b": [2]}"#, isJSON: true),
            ]),
            ResultRow(id: 1, values: [
                .make(text: "2"),
                .make(text: #"{"c": 3}"#, isJSON: true),
            ]),
        ]
        tab.result = result
        return tab
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let found = view as? NSTextView { return found }
        for child in view.subviews {
            if let found = textView(in: child) { return found }
        }
        return nil
    }

    /// Runs the run loop until the layout settles, the way a click leaves time for a redraw.
    private func settle(_ window: NSWindow) {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testTheFirstValueIsFormattedAndColoured() throws {
        let box = Box()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(box: box))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        settle(window)

        // The click.
        box.value = DisplayValue.make(text: #"{"a": 1, "b": [2]}"#, isJSON: true)
        settle(window)

        let text = try XCTUnwrap(textView(in: XCTUnwrap(window.contentView)))
        let storage = try XCTUnwrap(text.textStorage)
        XCTAssertTrue(
            text.string.contains("\n"), "the first value must be formatted: \(text.string)")
        XCTAssertTrue(hasColour(storage), "the first value must be coloured")

        // A second click must not be what makes it work.
        box.value = DisplayValue.make(text: #"{"c": 3}"#, isJSON: true)
        settle(window)
        XCTAssertTrue(text.string.contains("\n"))
        XCTAssertTrue(hasColour(storage))
    }

    /// The first cell you pick gives the pane a cell to write to. That must not start an edit:
    /// the editor shows the plain text, neither formatted nor coloured.
    func testTheFirstPickedCellDoesNotStartAnEdit() throws {
        let tab = tab()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TabHost(tab: tab))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        settle(window)

        // The click.
        tab.selection = CellSelection(single: CellAddress(rowID: 0, columnID: 1))
        settle(window)

        let text = try XCTUnwrap(textView(in: XCTUnwrap(window.contentView)))
        XCTAssertFalse(text.isEditable, "the first click must not open the editor")
        XCTAssertTrue(text.string.contains("\n"), "the value must be formatted: \(text.string)")
        XCTAssertTrue(hasColour(try XCTUnwrap(text.textStorage)), "the value must be coloured")
    }

    /// The Return key of the grid still opens the editor, which is what the counter is for.
    func testARequestStartsAnEdit() throws {
        let tab = tab()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TabHost(tab: tab))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        settle(window)

        tab.selection = CellSelection(single: CellAddress(rowID: 0, columnID: 1))
        settle(window)
        tab.paneEditRequests += 1
        settle(window)

        let text = try XCTUnwrap(textView(in: XCTUnwrap(window.contentView)))
        XCTAssertTrue(text.isEditable, "Return must open the editor")
    }

    /// The row view shows the same value as the pane, so it formats and colours it the same way.
    func testTheRowViewFormatsAndColoursJSON() throws {
        let tab = tab()
        let result = try XCTUnwrap(tab.result)
        var rowID: Int? = 0
        let binding = Binding(get: { rowID }, set: { rowID = $0 })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: RowInspectorSheet(result: result, rowID: binding, onClose: {}))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        settle(window)

        let text = try XCTUnwrap(textView(in: XCTUnwrap(window.contentView)))
        XCTAssertTrue(text.string.contains("\n"), "the value must be formatted: \(text.string)")
        XCTAssertTrue(hasColour(try XCTUnwrap(text.textStorage)), "the value must be coloured")
        XCTAssertFalse(text.isEditable, "the row view reads and does not write")
    }

    /// True when any part of the text carries a colour of its own.
    private func hasColour(_ storage: NSTextStorage) -> Bool {
        var found = false
        storage.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: storage.length)
        ) { value, _, stop in
            if let colour = value as? NSColor, colour != .labelColor {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
