import AppKit
import XCTest
@testable import Rowset

/// The keys that move the picked cell of the grid.
@MainActor
final class CellMovementTests: XCTestCase {

    private func result(rows: Int, columns: Int) -> ResultSet {
        var result = ResultSet()
        result.columns = (0..<columns).map {
            ResultColumn(id: $0, name: "c\($0)", typeName: "text")
        }
        result.rows = (0..<rows).map { row in
            ResultRow(id: row, values: (0..<columns).map { DisplayValue.make(text: "\(row)-\($0)") })
        }
        return result
    }

    private func cell(_ row: Int, _ column: Int) -> CellAddress {
        CellAddress(rowID: row, columnID: column)
    }

    func testAStepGoesToTheNeighbour() {
        let result = result(rows: 3, columns: 3)
        XCTAssertEqual(result.neighbour(of: cell(1, 1), rows: 1, columns: 0), cell(2, 1))
        XCTAssertEqual(result.neighbour(of: cell(1, 1), rows: -1, columns: 0), cell(0, 1))
        XCTAssertEqual(result.neighbour(of: cell(1, 1), rows: 0, columns: 1), cell(1, 2))
        XCTAssertEqual(result.neighbour(of: cell(1, 1), rows: 0, columns: -1), cell(1, 0))
    }

    /// A key at the edge keeps the cell it has, rather than wrapping to the other side.
    func testAStepStopsAtTheEdge() {
        let result = result(rows: 2, columns: 2)
        XCTAssertEqual(result.neighbour(of: cell(0, 0), rows: -1, columns: 0), cell(0, 0))
        XCTAssertEqual(result.neighbour(of: cell(0, 0), rows: 0, columns: -1), cell(0, 0))
        XCTAssertEqual(result.neighbour(of: cell(1, 1), rows: 1, columns: 0), cell(1, 1))
        XCTAssertEqual(result.neighbour(of: cell(1, 1), rows: 0, columns: 1), cell(1, 1))
    }

    func testACellOutsideTheResultHasNoNeighbour() {
        let result = result(rows: 2, columns: 2)
        XCTAssertNil(result.neighbour(of: cell(9, 0), rows: 1, columns: 0))
        XCTAssertNil(result.neighbour(of: cell(0, 9), rows: 1, columns: 0))
        XCTAssertNil(ResultSet().neighbour(of: cell(0, 0), rows: 1, columns: 0))
    }

    /// A sorted or hidden column list holds other ids, and a step follows the list.
    func testAStepFollowsTheOrderOfTheColumns() {
        var result = ResultSet()
        result.columns = [
            ResultColumn(id: 7, name: "a", typeName: "text"),
            ResultColumn(id: 2, name: "b", typeName: "text"),
        ]
        result.rows = [ResultRow(id: 0, values: [.make(text: "x"), .make(text: "y")])]
        XCTAssertEqual(
            result.neighbour(of: CellAddress(rowID: 0, columnID: 7), rows: 0, columns: 1),
            CellAddress(rowID: 0, columnID: 2))
    }

    // MARK: - The keys

    private func event(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags)
        -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    private func step(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = [])
        -> (rows: Int, columns: Int)? {
        OverdrawTableView.step(for: event(
            keyCode: keyCode, characters: characters, modifiers: modifiers))
    }

    func testTheArrowKeysMoveTheCell() {
        XCTAssertEqual(step(126, "\u{F700}")?.rows, -1)
        XCTAssertEqual(step(125, "\u{F701}")?.rows, 1)
        XCTAssertEqual(step(123, "\u{F702}")?.columns, -1)
        XCTAssertEqual(step(124, "\u{F703}")?.columns, 1)
    }

    func testTheLettersOfViMoveTheCell() {
        XCTAssertEqual(step(4, "h")?.columns, -1)
        XCTAssertEqual(step(37, "l")?.columns, 1)
        XCTAssertEqual(step(38, "j")?.rows, 1)
        XCTAssertEqual(step(40, "k")?.rows, -1)
    }

    /// Shift grows the block, so it still moves the cell.
    func testShiftKeepsTheStep() {
        XCTAssertEqual(step(38, "j", .shift)?.rows, 1)
        XCTAssertEqual(step(125, "\u{F701}", .shift)?.rows, 1)
    }

    /// A letter with Command belongs to whatever else wants it.
    func testALetterWithAModifierIsNoStep() {
        XCTAssertNil(step(37, "l", .command))
        XCTAssertNil(step(38, "j", .option))
        XCTAssertNil(step(4, "h", [.command, .shift]))
    }

    /// An arrow with Command or Option belongs to whatever else wants it, the same as a letter.
    func testAnArrowWithAModifierIsNoStep() {
        XCTAssertNil(step(123, "\u{F702}", .command))
        XCTAssertNil(step(124, "\u{F703}", .option))
        XCTAssertNil(step(125, "\u{F701}", .control))
    }

    func testAnotherLetterIsNoStep() {
        XCTAssertNil(step(0, "a"))
        XCTAssertNil(step(1, "s"))
    }
}
