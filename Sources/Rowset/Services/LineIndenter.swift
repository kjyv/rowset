import Foundation

/// One edit that Tab or Shift-Tab makes in the editor.
struct IndentEdit: Equatable {
    /// The part of the old text that changes, in UTF-16 units.
    var range: NSRange
    /// The text that takes its place.
    var replacement: String
    /// What the editor selects after the change.
    var selection: NSRange
}

/// Moves the lines of the selection one step to the right or to the left.
///
/// The editor sends Tab and Shift-Tab here. The edit covers only the lines the selection
/// touches, so one Tab is one undo step and the rest of the text keeps its position.
///
/// A step is a fixed count of spaces, never a tab character. A tab character would show at the
/// width of the default tab stop of the view, which is much wider than a step, and the editor
/// has no setting for it.
enum LineIndenter {

    /// The spaces one step adds. This is the indent of `JSONPrettyPrinter`, so the app has one
    /// indent width.
    static let step = "  "

    /// Puts one step in front of every line the selection touches.
    ///
    /// A caret gets a step at the caret, which is what a Tab in a text does. Only a selection of
    /// characters moves whole lines.
    static func indent(_ text: String, selection: NSRange) -> IndentEdit? {
        let source = text as NSString
        guard fits(selection, in: source) else { return nil }

        guard selection.length > 0 else {
            return IndentEdit(
                range: NSRange(location: selection.location, length: 0),
                replacement: step,
                selection: NSRange(location: selection.location + step.utf16.count, length: 0))
        }

        return edit(in: source, selection: selection) { line in
            // An empty line gets nothing. Spaces on a line with no text are only trailing space.
            line.isEmpty ? line : step + line
        }
    }

    /// Takes one step away from every line the selection touches.
    ///
    /// A line with no indent stays as it is. A caret dedents the line it sits on, so the key
    /// works without a selection.
    static func dedent(_ text: String, selection: NSRange) -> IndentEdit? {
        let source = text as NSString
        guard fits(selection, in: source) else { return nil }

        return edit(in: source, selection: selection, transform: stripStep)
    }

    /// True when the range sits inside the text. A range from outside changes nothing.
    private static func fits(_ selection: NSRange, in source: NSString) -> Bool {
        selection.location >= 0 && selection.length >= 0
            && selection.location <= source.length
            && source.length - selection.location >= selection.length
    }

    /// Removes one step from the front of a line.
    ///
    /// A leading tab character counts as a whole step. Such a line comes from a paste, and half
    /// a tab character does not exist.
    private static func stripStep(_ line: String) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }

        var spaces = 0
        for character in line {
            guard character == " ", spaces < step.count else { break }
            spaces += 1
        }
        return String(line.dropFirst(spaces))
    }

    /// Applies `transform` to every line the selection touches.
    ///
    /// The result is `nil` when no line changes, so Shift-Tab on text with no indent leaves the
    /// undo stack alone.
    private static func edit(
        in source: NSString, selection: NSRange, transform: (String) -> String
    ) -> IndentEdit? {
        // The block is every line the selection touches. A selection that ends at the start of
        // a line ends on the line break in front of it, so `lineRange` keeps that line out.
        let block = source.lineRange(for: selection)

        let original = source.substring(with: block)
        let endsWithBreak = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")
        // The text after the last line break is the empty piece that the split leaves behind.
        if endsWithBreak { lines.removeLast() }

        let moved = lines.map(transform)
        var replacement = moved.joined(separator: "\n")
        if endsWithBreak { replacement += "\n" }
        guard replacement != original else { return nil }

        return IndentEdit(
            range: block, replacement: replacement,
            selection: newSelection(selection, block: block, lines: lines, moved: moved))
    }

    /// Where the editor puts the selection after the change.
    ///
    /// A selection of characters grows to the whole block, so a second Tab moves the same lines
    /// again. A caret keeps its place in its line and follows the text that moved in front of it.
    private static func newSelection(
        _ selection: NSRange, block: NSRange, lines: [String], moved: [String]
    ) -> NSRange {
        guard selection.length == 0 else {
            let length = moved.reduce(moved.count - 1) { $0 + $1.utf16.count }
            return NSRange(location: block.location, length: max(0, length))
        }

        let shift = moved[0].utf16.count - lines[0].utf16.count
        let column = selection.location - block.location
        return NSRange(location: block.location + max(0, column + shift), length: 0)
    }
}
