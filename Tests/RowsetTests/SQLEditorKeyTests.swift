import AppKit
import SwiftUI
import XCTest
@testable import Rowset

/// The Tab and Shift-Tab keys of the console editor.
///
/// The editor is hosted in a real window, and the keys go in the way AppKit sends them: the key
/// binding turns Tab into `insertTab:`, and `doCommand(by:)` is where the text view asks its
/// delegate. The test then reads the text view and the text the editor wrote back.
@MainActor
final class SQLEditorKeyTests: XCTestCase {

    /// Holds the text of the editor, so the test sees what the editor writes back.
    @Observable final class Box {
        var text = ""
        var caret = 0
    }

    private struct Host: View {
        let box: Box
        var body: some View {
            SQLEditorView(
                text: Binding(get: { box.text }, set: { box.text = $0 }),
                caret: Binding(get: { box.caret }, set: { box.caret = $0 }))
                .frame(width: 400, height: 200)
        }
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let found = view as? NSTextView { return found }
        for child in view.subviews {
            if let found = textView(in: child) { return found }
        }
        return nil
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// An editor with `sql` in it, and the window that holds it.
    private func editor(_ sql: String) throws -> (NSTextView, Box, NSWindow) {
        let box = Box()
        box.text = sql
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(box: box))
        window.orderBack(nil)
        settle(window)

        let text = try XCTUnwrap(textView(in: XCTUnwrap(window.contentView)))
        return (text, box, window)
    }

    func testTabIndentsTheSelectedLines() throws {
        let (text, box, window) = try editor("SELECT a\nFROM t")
        defer { window.orderOut(nil) }

        text.setSelectedRange(NSRange(location: 0, length: 15))
        text.doCommand(by: #selector(NSResponder.insertTab(_:)))
        settle(window)

        XCTAssertEqual(text.string, "  SELECT a\n  FROM t")
        XCTAssertEqual(box.text, text.string, "the tab must keep the text of the console")
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 19))

        // The whole block is selected, so a second Tab moves the same lines again.
        text.doCommand(by: #selector(NSResponder.insertTab(_:)))
        settle(window)
        XCTAssertEqual(text.string, "    SELECT a\n    FROM t")
    }

    func testShiftTabDedentsTheSelectedLines() throws {
        let (text, box, window) = try editor("    SELECT a\n    FROM t")
        defer { window.orderOut(nil) }

        text.setSelectedRange(NSRange(location: 0, length: 23))
        text.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        settle(window)

        XCTAssertEqual(text.string, "  SELECT a\n  FROM t")
        XCTAssertEqual(box.text, text.string)
    }

    /// Shift-Tab reaches the view in two forms, and both must dedent.
    func testTheShiftFlagOfTheKeyDecides() {
        func key(shift: Bool) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "\t",
                charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
        }
        let tab = #selector(NSResponder.insertTab(_:))
        let backtab = #selector(NSResponder.insertBacktab(_:))

        XCTAssertEqual(
            SQLEditorView.Coordinator.move(for: tab, event: key(shift: false)), .deeper)
        XCTAssertEqual(
            SQLEditorView.Coordinator.move(for: tab, event: key(shift: true)), .shallower)
        XCTAssertEqual(
            SQLEditorView.Coordinator.move(for: backtab, event: key(shift: true)), .shallower)
        // A key binding can send the selector with no key of its own.
        XCTAssertEqual(SQLEditorView.Coordinator.move(for: tab, event: nil), .deeper)
        XCTAssertEqual(SQLEditorView.Coordinator.move(for: backtab, event: nil), .shallower)
        XCTAssertNil(
            SQLEditorView.Coordinator.move(
                for: #selector(NSResponder.insertNewline(_:)), event: nil))
    }

    /// Shift-Tab without an indent must not move the keyboard to another view.
    func testBothKeysCountAsHandled() throws {
        let (text, _, window) = try editor("SELECT a")
        defer { window.orderOut(nil) }

        let coordinator = try XCTUnwrap(text.delegate as? SQLEditorView.Coordinator)
        text.setSelectedRange(NSRange(location: 0, length: 8))
        XCTAssertTrue(coordinator.textView(text, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertTrue(
            coordinator.textView(text, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        XCTAssertFalse(
            coordinator.textView(text, doCommandBy: #selector(NSResponder.insertNewline(_:))),
            "a key the editor does not handle belongs to the text view")
    }
}
