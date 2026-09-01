import Foundation

/// What a piece of text is, in SQL or in JSON.
///
/// One list serves both languages, so one colour table paints both. A kind that only one of them
/// can produce still lives here, because a reader of the table wants the whole set in one place.
enum SyntaxKind: Sendable, Hashable {
    /// A SQL keyword, or `true`, `false` and `null` in JSON.
    case keyword
    case identifier
    /// A name in double quotes, in SQL.
    case quotedIdentifier
    /// The name of a field of a JSON object.
    case key
    /// A literal in single quotes or a dollar quoted body in SQL, and any string in JSON.
    case string
    case number
    /// A placeholder such as `$1`, in SQL.
    case parameter
    case comment
    case punctuation
}

/// One piece of text and what it is.
struct SyntaxToken: Sendable, Hashable {
    var range: NSRange
    var kind: SyntaxKind
    var text: String
}
