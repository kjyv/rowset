import Foundation

/// One statement inside the text of the editor.
struct SQLStatement: Hashable, Sendable {
    /// Where it sits in the whole text, in UTF-16 units, so `NSTextView` can mark it.
    var range: NSRange
    /// The statement to send, without the semicolon that closed it.
    var text: String
}

/// Cuts the text of the editor into statements.
///
/// Two things end a statement: a semicolon, and an empty line.
///
/// A split on every semicolon is wrong, because a semicolon also appears inside a string, inside
/// a quoted name, inside a comment and inside a dollar quoted body. `SQLLexer` has already read
/// past all of those, so every semicolon it reports as punctuation is a real one.
///
/// An empty line ends a statement as well, so a semicolon is never needed. A single line break
/// does not, and must not: a statement is normally written over several lines, and every SELECT
/// with its FROM on the next line would fall apart.
///
/// An empty line inside a string, a comment or a dollar quoted body splits nothing, because the
/// lexer reports each of those as one token and this only looks between tokens.
enum SQLStatementSplitter {

    static func statements(in text: String) -> [SQLStatement] {
        let source = text as NSString
        let tokens = SQLLexer.tokens(in: text)

        var statements: [SQLStatement] = []
        var start: Int?
        var end = 0
        var hasCode = false

        func finish(includingSemicolon: Bool) {
            guard let first = start, hasCode, end > first else { return }
            let range = NSRange(location: first, length: end - first)
            var body = source.substring(with: range)
            if includingSemicolon, body.hasSuffix(";") { body.removeLast() }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            statements.append(SQLStatement(range: range, text: trimmed))
        }

        for token in tokens {
            if token.kind == .punctuation, token.text == ";" {
                end = token.range.upperBound
                finish(includingSemicolon: true)
                start = nil
                hasCode = false
                continue
            }

            // An empty line before this token closes whatever came before it.
            if start != nil, isBlankLine(in: source, from: end, to: token.range.location) {
                finish(includingSemicolon: false)
                start = nil
                hasCode = false
            }

            if start == nil { start = token.range.location }
            end = token.range.upperBound
            // A statement of comments alone is nothing to run.
            if token.kind != .comment { hasCode = true }
        }

        // The last statement needs no semicolon.
        finish(includingSemicolon: false)
        return statements
    }

    /// True when the text between two tokens holds an empty line.
    ///
    /// Two line breaks make one empty line between them. Spaces and tabs on that line change
    /// nothing, because a line of white space still reads as empty.
    private static func isBlankLine(in source: NSString, from start: Int, to end: Int) -> Bool {
        guard end > start, start >= 0, end <= source.length else { return false }
        let gap = source.substring(with: NSRange(location: start, length: end - start))
        return gap.filter(\.isNewline).count >= 2
    }

    /// True when a statement gives back rows that another SELECT may page over.
    ///
    /// Only a statement that reads can be wrapped. An INSERT, a CREATE or an EXPLAIN would not
    /// survive it, so those run as they are and show no page widget.
    static func isPageable(_ statement: String) -> Bool {
        let first = SQLLexer.tokens(in: statement).first { $0.kind != .comment }
        guard let first, first.kind == .keyword else { return false }
        return ["select", "with", "table", "values"].contains(first.text.lowercased())
    }

    /// The statement the caret sits in.
    ///
    /// A caret in the white space between two statements belongs to the one before it, which is
    /// the statement you just finished typing.
    static func statement(at location: Int, in statements: [SQLStatement]) -> SQLStatement? {
        guard !statements.isEmpty else { return nil }

        for statement in statements
        where location >= statement.range.location && location <= statement.range.upperBound {
            return statement
        }

        return statements.last { $0.range.upperBound < location } ?? statements.first
    }
}
