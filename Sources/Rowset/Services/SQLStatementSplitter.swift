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
/// A split on every semicolon is wrong, because a semicolon also appears inside a string, inside
/// a quoted name, inside a comment and inside a dollar quoted body. `SQLLexer` has already read
/// past all of those, so every semicolon it reports as punctuation is a real one.
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

            if start == nil { start = token.range.location }
            end = token.range.upperBound
            // A statement of comments alone is nothing to run.
            if token.kind != .comment { hasCode = true }
        }

        // The last statement needs no semicolon.
        finish(includingSemicolon: false)
        return statements
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
